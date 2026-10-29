import Foundation
import OSLog
import Synchronization

/// Diagnostic counters only: never retains camera samples or changes capture
/// eligibility. Release builds are disabled unless DOBBY_CAMERA_METRICS=1.
/// Callers must use one monotonic clock per stage. Input stages use capture PTS;
/// submission/completion/present-request stages use host uptime, not image PTS.
nonisolated final class CameraFramePerformanceMetrics: @unchecked Sendable {
    static let shared = CameraFramePerformanceMetrics()

    enum Stage: String, CaseIterable, Sendable {
        case wideInput, depthInput, primaryPublished
        case wideArrival, depthArrival
        case previewQueued, previewSubmitted, previewCompleted, previewPresented, previewSourcePresented
    }

    enum DropReason: String, CaseIterable, Sendable {
        case wideLate, depthLate, outOfBuffers, discontinuity
        case missingWideDepth, primaryRejected, invalidFrame
        case rendererBusy, rendererUnavailable, staleSession, staleFrame, duplicateFrame
        case invalidTimestamp
    }

    enum NoticeReason: String, CaseIterable, Sendable {
        case uncorrelatedPrimaryLatency, uncorrelatedPreviewQueueLatency
    }

    enum LatencyStage: String, CaseIterable, Sendable {
        case inputToPrimary, inputToPreviewQueue
        case previewQueueWait, previewGPUCompletion, foregroundRaster, foregroundAnalysis
    }

    let isEnabled: Bool
    private let state = Mutex(State())
    private let loggingQueue = DispatchQueue(label: "com.dobby.camera.performance-log", qos: .utility)
    private let logger = Logger(subsystem: "com.dobby.camera", category: "frame-pacing")
    private let reportingInterval: TimeInterval = 5

    init(enabled: Bool = CameraFramePerformanceMetrics.defaultEnabled) {
        isEnabled = enabled
    }

    static var defaultEnabled: Bool {
        let preference = ProcessInfo.processInfo.environment["DOBBY_CAMERA_METRICS"]
        if preference == "0" { return false }
        if preference == "1" { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    func begin(sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { value in
            // Repeated setup for the same generation must not erase its counts.
            guard value.owner != sessionID else { return }
            value = State(owner: sessionID, startedAt: now, lastReportAt: now)
        }
    }

    /// De-duplicates identical PTS and excludes backwards timestamps from rate
    /// and interval calculations. Every stage owns at most 256 recent intervals.
    func event(_ stage: Stage, timestamp: TimeInterval, sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            guard timestamp.isFinite, timestamp >= 0 else {
                value.drops[.invalidTimestamp, default: 0] += 1
                return takeReportIfDue(&value, now: now)
            }
            let previous = value.stages[stage]?.last
            let advances = previous.map { timestamp > $0 } ?? true
            value.stages[stage]?.record(timestamp)
            if advances {
                switch stage {
                case .wideInput:
                    value.stages[.wideArrival]?.record(now)
                    value.wideArrivals.record(sourcePTS: timestamp, hostTime: now)
                case .depthInput:
                    value.stages[.depthArrival]?.record(now)
                case .primaryPublished:
                    if let arrival = value.wideArrivals.hostTime(for: timestamp), now >= arrival {
                        value.latencies[.inputToPrimary]?.append(now - arrival)
                    } else {
                        value.notices[.uncorrelatedPrimaryLatency, default: 0] += 1
                    }
                default: break
                }
            }
            return takeReportIfDue(&value, now: now)
        }
        emit(report)
    }

    func drop(_ reason: DropReason, sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            value.drops[reason, default: 0] += 1
            return takeReportIfDue(&value, now: now)
        }
        emit(report)
    }

    /// Missing clock correlations are observations, not proven frame losses.
    func notice(_ reason: NoticeReason, sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            value.notices[reason, default: 0] += 1
            return takeReportIfDue(&value, now: now)
        }
        emit(report)
    }

    /// Counts every app present request, but measures central-image cadence only
    /// when its capture PTS advances. Re-presenting the same wide image is not
    /// a new central camera frame.
    /// PTS is used only for identity/order, never subtracted from host uptime.
    func presented(sourceTimestamp: TimeInterval, hostTimestamp: TimeInterval, sessionID: UUID) {
        guard isEnabled else { return }
        guard hostTimestamp.isFinite, hostTimestamp >= 0 else {
            drop(.invalidTimestamp, sessionID: sessionID)
            return
        }
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            value.stages[.previewPresented]?.record(hostTimestamp)
            guard sourceTimestamp.isFinite, sourceTimestamp >= 0 else {
                value.drops[.invalidTimestamp, default: 0] += 1
                return takeReportIfDue(&value, now: hostTimestamp)
            }
            if value.lastPresentedSourcePTS.map({ sourceTimestamp > $0 }) ?? true {
                value.lastPresentedSourcePTS = sourceTimestamp
                value.stages[.previewSourcePresented]?.record(hostTimestamp)
            }
            return takeReportIfDue(&value, now: hostTimestamp)
        }
        emit(report)
    }

    /// Re-queuing the same image is still a queue admission, but latency from
    /// wide arrival describes only the first queue of each new wide PTS.
    /// The bounded ring joins exact PTS identities; durations use host time only.
    func queued(sourceTimestamp: TimeInterval, hostTimestamp: TimeInterval, sessionID: UUID) {
        guard isEnabled else { return }
        guard hostTimestamp.isFinite, hostTimestamp >= 0 else {
            drop(.invalidTimestamp, sessionID: sessionID)
            return
        }
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            value.stages[.previewQueued]?.record(hostTimestamp)
            guard sourceTimestamp.isFinite, sourceTimestamp >= 0 else {
                value.drops[.invalidTimestamp, default: 0] += 1
                return takeReportIfDue(&value, now: hostTimestamp)
            }
            if value.lastQueuedSourcePTS.map({ sourceTimestamp > $0 }) ?? true {
                value.lastQueuedSourcePTS = sourceTimestamp
                if let arrival = value.wideArrivals.hostTime(for: sourceTimestamp), hostTimestamp >= arrival {
                    value.latencies[.inputToPreviewQueue]?.append(hostTimestamp - arrival)
                } else {
                    value.notices[.uncorrelatedPreviewQueueLatency, default: 0] += 1
                }
            }
            return takeReportIfDue(&value, now: hostTimestamp)
        }
        emit(report)
    }

    /// Host-clock durations must be measured by the caller; never subtract
    /// capture PTS from uptime without an explicit clock conversion.
    func latency(_ stage: LatencyStage, seconds: TimeInterval, sessionID: UUID) {
        guard isEnabled, seconds.isFinite, seconds >= 0 else { return }
        state.withLock { value in
            guard value.owner == sessionID else { return }
            value.latencies[stage]?.append(seconds)
        }
    }

    /// Configuration should contain formats/FPS/cost/pressure only, never
    /// device identifiers, user data, camera samples, or secrets.
    func configuration(_ summary: String, sessionID: UUID) {
        guard isEnabled, state.withLock({ $0.owner == sessionID }) else { return }
        loggingQueue.async { [logger] in
            logger.info("camera configuration: \(summary, privacy: .public)")
        }
    }

    func flush(sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            value.lastReportAt = now
            return Report(value: value, now: now)
        }
        emit(report)
    }

    func end(sessionID: UUID) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = state.withLock { value -> Report? in
            guard value.owner == sessionID else { return nil }
            let report = Report(value: value, now: now)
            value.owner = nil
            return report
        }
        emit(report)
    }

    private func takeReportIfDue(_ value: inout State, now: TimeInterval) -> Report? {
        guard now - value.lastReportAt >= reportingInterval else { return nil }
        value.lastReportAt = now
        return Report(value: value, now: now)
    }

    private func emit(_ report: Report?) {
        guard let report else { return }
        // Sorting percentiles/formatting strings never runs on the capture lock.
        loggingQueue.async { [logger] in
            logger.info("\(report.summary, privacy: .public)")
        }
    }

    private struct State: Sendable {
        var owner: UUID?
        var startedAt: TimeInterval = 0
        var lastReportAt: TimeInterval = 0
        var lastPresentedSourcePTS: TimeInterval?
        var lastQueuedSourcePTS: TimeInterval?
        var wideArrivals = SourceArrivalRing()
        var stages = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, StageCounter()) })
        var latencies = Dictionary(uniqueKeysWithValues: LatencyStage.allCases.map { ($0, Samples()) })
        var drops: [DropReason: Int] = [:]
        var notices: [NoticeReason: Int] = [:]
    }

    /// At most 16 pairs of scalar times. This does not extend any camera-buffer
    /// lifetime. Expired or mismatched identities are reported as uncorrelated,
    /// never guessed from the nearest frame or interpreted as zero latency.
    private struct SourceArrivalRing: Sendable {
        private struct Entry: Sendable {
            let sourcePTS: TimeInterval
            let hostTime: TimeInterval
        }
        private static let capacity = 16
        private var entries: [Entry?]
        private var cursor = 0

        init() {
            entries = [Entry?](repeating: nil, count: Self.capacity)
        }

        mutating func record(sourcePTS: TimeInterval, hostTime: TimeInterval) {
            entries[cursor] = Entry(sourcePTS: sourcePTS, hostTime: hostTime)
            cursor = (cursor + 1) % Self.capacity
        }

        func hostTime(for sourcePTS: TimeInterval) -> TimeInterval? {
            for entry in entries {
                if let entry, entry.sourcePTS == sourcePTS { return entry.hostTime }
            }
            return nil
        }
    }

    private struct StageCounter: Sendable {
        var count = 0
        var duplicate = 0
        var backwards = 0
        var first: TimeInterval?
        var last: TimeInterval?
        var intervals = Samples()

        mutating func record(_ timestamp: TimeInterval) {
            if let last {
                if timestamp == last { duplicate += 1; return }
                if timestamp < last { backwards += 1; return }
                intervals.append(timestamp - last)
            } else { first = timestamp }
            last = timestamp
            count += 1
        }

        var summary: String {
            let elapsed = (last ?? 0) - (first ?? 0)
            let rate = elapsed > 0 && count > 1 ? Double(count - 1) / elapsed : 0
            return "n=\(count),rate=\(Self.format(rate))/s,duplicate=\(duplicate),backwards=\(backwards),\(intervals.summary)"
        }

        private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
    }

    /// Cumulative totals and bounded exact samples are intentionally distinct.
    /// Quantiles describe only the most recent 256 values, not the whole run.
    private struct Samples: Sendable {
        private static let capacity = 256
        private var values: [TimeInterval]
        private var cursor = 0
        private var retained = 0
        private var count = 0
        private var over50ms = 0
        private var maximum: TimeInterval = 0

        init() {
            values = [TimeInterval](repeating: 0, count: Self.capacity)
        }

        mutating func append(_ seconds: TimeInterval) {
            values[cursor] = seconds
            cursor = (cursor + 1) % Self.capacity
            retained = min(Self.capacity, retained + 1)
            count += 1
            if seconds > 0.050 { over50ms += 1 }
            maximum = max(maximum, seconds)
        }

        var summary: String {
            guard retained > 0 else { return "intervals=0" }
            let sorted = values.prefix(retained).sorted()
            func quantile(_ probability: Double) -> Double {
                sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * probability)) - 1))] * 1_000
            }
            return "samples=\(count),recent=\(retained),p95_recent_ms=\(String(format: "%.2f", quantile(0.95))),p99_recent_ms=\(String(format: "%.2f", quantile(0.99))),max_all_ms=\(String(format: "%.2f", maximum * 1_000)),over50_all=\(over50ms)/\(count)"
        }
    }

    private struct Report: Sendable {
        private let value: State
        private let elapsed: TimeInterval

        init(value: State, now: TimeInterval) {
            self.value = value
            elapsed = max(0, now - value.startedAt)
        }

        var summary: String {
            let stages = Stage.allCases.compactMap { stage -> String? in
                guard let counter = value.stages[stage], counter.count > 0 else { return nil }
                return "\(stage.rawValue){\(counter.summary)}"
            }
            let latency = LatencyStage.allCases.compactMap { stage -> String? in
                guard let sample = value.latencies[stage] else { return nil }
                return "\(stage.rawValue){\(sample.summary)}"
            }
            let drops = DropReason.allCases.compactMap { reason -> String? in
                let count = value.drops[reason, default: 0]
                return count > 0 ? "\(reason.rawValue)=\(count)" : nil
            }
            let notices = NoticeReason.allCases.compactMap { reason -> String? in
                let count = value.notices[reason, default: 0]
                return count > 0 ? "\(reason.rawValue)=\(count)" : nil
            }
            return "camera pacing elapsed=\(String(format: "%.2f", elapsed))s; "
                + stages.joined(separator: "; ") + "; latency " + latency.joined(separator: "; ")
                + "; drops{" + drops.joined(separator: ",") + "}; notices{" + notices.joined(separator: ",")
                + "}; previewPresented=app present request, not display scanout"
        }
    }
}
