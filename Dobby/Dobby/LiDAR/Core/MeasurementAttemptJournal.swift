import Foundation

nonisolated enum MeasurementAttemptPurpose: String, Codable, Sendable, CaseIterable {
    case manualSensor, automaticModel, fixture
}

nonisolated enum MeasurementAttemptPhase: String, Codable, Sendable, CaseIterable {
    case capture, landmarks, measurement

    fileprivate var order: Int {
        switch self { case .capture: 0; case .landmarks: 1; case .measurement: 2 }
    }
}

nonisolated enum MeasurementAttemptOutcome: String, Codable, Sendable, CaseIterable {
    /// Computational outcomes, never claims about physical measurement accuracy.
    case success, partial, unavailable
    case captureFailed, landmarkFailed, cancelled, timedOut, interrupted

}

nonisolated struct MeasurementAttemptTimings: Codable, Sendable, Equatable {
    var captureSeconds: Double? = nil
    var landmarksSeconds: Double? = nil
    var measurementSeconds: Double? = nil
    var totalSeconds: Double? = nil

    fileprivate var sanitized: Self {
        func valid(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        return Self(captureSeconds: valid(captureSeconds), landmarksSeconds: valid(landmarksSeconds),
                    measurementSeconds: valid(measurementSeconds), totalSeconds: valid(totalSeconds))
    }

    fileprivate func merging(_ newer: Self) -> Self {
        let newer = newer.sanitized
        return Self(captureSeconds: newer.captureSeconds ?? captureSeconds,
                    landmarksSeconds: newer.landmarksSeconds ?? landmarksSeconds,
                    measurementSeconds: newer.measurementSeconds ?? measurementSeconds,
                    totalSeconds: newer.totalSeconds ?? totalSeconds)
    }

    fileprivate func seconds(for phase: MeasurementAttemptPhase) -> Double? {
        switch phase {
        case .capture: captureSeconds
        case .landmarks: landmarksSeconds
        case .measurement: measurementSeconds
        }
    }
}

/// One record exists before capture begins, even when no snapshot is produced.
/// No image, depth map, garment description, or external log is stored here.
nonisolated struct MeasurementAttemptRecord: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date? = nil
    var purpose: MeasurementAttemptPurpose
    var isSynthetic: Bool
    var phase: MeasurementAttemptPhase = .capture
    var outcome: MeasurementAttemptOutcome? = nil
    var sessionID: UUID? = nil
    var frameID: UUID? = nil
    var deviceContext: String? = nil
    var timings: MeasurementAttemptTimings = .init()
    var message: String? = nil
    var schemaVersion = 1

    var isFinished: Bool { outcome != nil }
    var isPhysicalAttempt: Bool { !isSynthetic && purpose != .fixture }

    func hasCompleted(_ requestedPhase: MeasurementAttemptPhase) -> Bool {
        requestedPhase.order < phase.order
            || (requestedPhase == phase && (outcome == .success
                || (phase == .measurement && (outcome == .partial || outcome == .unavailable))))
    }

    /// An elapsed failure-stage duration is diagnostic only; it is not a
    /// completed-stage latency sample. Earlier completed phases remain usable.
    func completedSeconds(for requestedPhase: MeasurementAttemptPhase) -> Double? {
        guard hasCompleted(requestedPhase) else { return nil }
        return timings.sanitized.seconds(for: requestedPhase)
    }
}

nonisolated struct MeasurementAttemptLatency: Codable, Sendable, Equatable {
    var sampleCount: Int
    var medianSeconds: Double?
    /// Nearest-rank P95: the ceil(0.95 * N)-th ordered completed sample.
    var p95Seconds: Double?

    fileprivate init(_ samples: [Double]) {
        let values = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        sampleCount = values.count
        guard !values.isEmpty else { medianSeconds = nil; p95Seconds = nil; return }
        let middle = values.count / 2
        medianSeconds = values.count.isMultiple(of: 2)
            ? values[middle - 1] / 2 + values[middle] / 2 : values[middle]
        p95Seconds = values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }
}

nonisolated struct MeasurementAttemptStatistics: Codable, Sendable, Equatable {
    var totalAttempts: Int
    var finishedAttempts: Int
    var unfinishedAttempts: Int
    var successfulAttempts: Int
    var partialAttempts: Int
    var unavailableAttempts: Int
    var captureFailures: Int
    var landmarkFailures: Int
    var cancellations: Int
    var timeouts: Int
    var interruptions: Int
    var automaticFinishedAttempts: Int
    var automaticCancelledAttempts: Int
    var automaticMeasurementSuccesses: Int
    var captureLatency: MeasurementAttemptLatency
    var landmarksLatency: MeasurementAttemptLatency
    var measurementLatency: MeasurementAttemptLatency
    var totalLatency: MeasurementAttemptLatency

    var failureCount: Int { unavailableAttempts + captureFailures + landmarkFailures + timeouts + interruptions }
    /// Automatic-model purpose only. Denominator: terminal attempts except user
    /// cancellations, including capture/ML failures. A successful manual capture
    /// is not an automatically measured garment. Partial results remain in the
    /// denominator and unfinished attempts are reported separately.
    /// This evaluates the pipeline's result availability, not real-world accuracy.
    var geometrySuccessRateExcludingCancellations: Double? {
        let denominator = automaticFinishedAttempts - automaticCancelledAttempts
        return denominator > 0 ? Double(automaticMeasurementSuccesses) / Double(denominator) : nil
    }

    fileprivate init(_ records: [MeasurementAttemptRecord]) {
        func count(_ outcome: MeasurementAttemptOutcome) -> Int { records.filter { $0.outcome == outcome }.count }
        totalAttempts = records.count
        finishedAttempts = records.filter(\.isFinished).count
        unfinishedAttempts = totalAttempts - finishedAttempts
        successfulAttempts = count(.success)
        partialAttempts = count(.partial)
        unavailableAttempts = count(.unavailable)
        captureFailures = count(.captureFailed)
        landmarkFailures = count(.landmarkFailed)
        cancellations = count(.cancelled)
        timeouts = count(.timedOut)
        interruptions = count(.interrupted)
        let automatic = records.filter { $0.purpose == .automaticModel }
        automaticFinishedAttempts = automatic.filter(\.isFinished).count
        automaticCancelledAttempts = automatic.filter { $0.outcome == .cancelled }.count
        automaticMeasurementSuccesses = automatic.filter { $0.outcome == .success && $0.phase == .measurement }.count
        captureLatency = .init(records.compactMap { $0.completedSeconds(for: .capture) })
        landmarksLatency = .init(records.compactMap { $0.completedSeconds(for: .landmarks) })
        measurementLatency = .init(records.compactMap { $0.completedSeconds(for: .measurement) })
        totalLatency = .init(records.filter(\.isFinished).compactMap { $0.timings.sanitized.totalSeconds })
    }
}

nonisolated struct MeasurementAttemptReport: Sendable {
    var records: [MeasurementAttemptRecord]
    var physical: MeasurementAttemptStatistics
    var synthetic: MeasurementAttemptStatistics
    var manualSensor: MeasurementAttemptStatistics
    var automaticModel: MeasurementAttemptStatistics
    var unreadableRecordCount: Int
    /// A true value means counts describe the bounded scan, not the whole folder.
    var scanLimitReached: Bool

    fileprivate init(records: [MeasurementAttemptRecord], unreadableRecordCount: Int, scanLimitReached: Bool) {
        self.records = records
        let physicalRecords = records.filter(\.isPhysicalAttempt)
        physical = .init(physicalRecords)
        synthetic = .init(records.filter { !$0.isPhysicalAttempt })
        manualSensor = .init(physicalRecords.filter { $0.purpose == .manualSensor })
        automaticModel = .init(physicalRecords.filter { $0.purpose == .automaticModel })
        self.unreadableRecordCount = unreadableRecordCount
        self.scanLimitReached = scanLimitReached
    }

    var csv: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "" }
            return String(value)
        }
        func cell(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "attempt_id,started_at,finished_at,purpose,is_synthetic,phase,outcome,session_id,frame_id,device_context,capture_seconds,capture_completed,landmarks_seconds,landmarks_completed,measurement_seconds,measurement_completed,total_seconds,message"
        let rows = records.map { record in
            [record.id.uuidString, formatter.string(from: record.startedAt),
             record.finishedAt.map { formatter.string(from: $0) } ?? "", record.purpose.rawValue,
             String(record.isSynthetic), record.phase.rawValue, record.outcome?.rawValue ?? "unfinished",
             record.sessionID?.uuidString ?? "", record.frameID?.uuidString ?? "", record.deviceContext ?? "",
             number(record.timings.captureSeconds), String(record.hasCompleted(.capture)),
             number(record.timings.landmarksSeconds), String(record.hasCompleted(.landmarks)),
             number(record.timings.measurementSeconds), String(record.hasCompleted(.measurement)),
             number(record.timings.totalSeconds), record.message ?? ""].map(cell).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

nonisolated enum MeasurementAttemptJournalError: LocalizedError, Equatable {
    case notFound, invalidRecord, conflictingAttempt, invalidTransition

    var errorDescription: String? {
        switch self {
        case .notFound: "시작 기록을 찾을 수 없습니다. 측정 시도를 먼저 등록해 주세요."
        case .invalidRecord: "시도 기록의 시각이나 형식이 올바르지 않습니다."
        case .conflictingAttempt: "같은 시도 ID에 다른 테스트 유형이 등록되어 있습니다."
        case .invalidTransition: "이미 진행한 단계보다 이전 단계로 시도 기록을 변경할 수 없습니다."
        }
    }
}

/// Local-only attempt journal, independent from saved image/depth archives.
/// Writes are atomic and the first terminal result is immutable. Restored pending
/// records stay explicitly unfinished; a restart is not evidence of failure.
actor MeasurementAttemptJournal {
    private let folder: URL
    private let maximumScannedEntries: Int
    private let maximumFileBytes = 65_536

    init(folder: URL? = nil, maximumScannedEntries: Int = 10_000) {
        self.folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiDARAttempts", isDirectory: true)
        self.maximumScannedEntries = min(100_000, max(1, maximumScannedEntries))
    }

    @discardableResult
    func begin(id: UUID = UUID(), purpose: MeasurementAttemptPurpose, isSynthetic: Bool,
               deviceContext: String? = nil, startedAt: Date = Date()) throws -> MeasurementAttemptRecord {
        if FileManager.default.fileExists(atPath: url(for: id).path) {
            let existing = try load(id)
            guard existing.purpose == purpose, existing.isSynthetic == isSynthetic else {
                throw MeasurementAttemptJournalError.conflictingAttempt
            }
            return existing
        }
        let record = MeasurementAttemptRecord(id: id, startedAt: startedAt, purpose: purpose,
                                               isSynthetic: isSynthetic, deviceContext: Self.limited(deviceContext, length: 256))
        try persist(record)
        return record
    }

    @discardableResult
    func update(id: UUID, phase: MeasurementAttemptPhase, sessionID: UUID? = nil, frameID: UUID? = nil,
                timings: MeasurementAttemptTimings? = nil) throws -> MeasurementAttemptRecord {
        var record = try load(id)
        guard !record.isFinished else { return record }
        guard phase.order >= record.phase.order else { throw MeasurementAttemptJournalError.invalidTransition }
        record.phase = phase
        record.sessionID = sessionID ?? record.sessionID
        record.frameID = frameID ?? record.frameID
        if let timings { record.timings = record.timings.merging(timings) }
        try persist(record)
        return record
    }

    @discardableResult
    func finish(id: UUID, outcome: MeasurementAttemptOutcome, phase: MeasurementAttemptPhase,
                sessionID: UUID? = nil, frameID: UUID? = nil, timings: MeasurementAttemptTimings = .init(),
                message: String? = nil, finishedAt: Date = Date()) throws -> MeasurementAttemptRecord {
        var record = try load(id)
        guard !record.isFinished else { return record }
        guard phase.order >= record.phase.order else { throw MeasurementAttemptJournalError.invalidTransition }
        record.outcome = outcome
        record.phase = phase
        record.finishedAt = finishedAt
        record.sessionID = sessionID ?? record.sessionID
        record.frameID = frameID ?? record.frameID
        record.timings = record.timings.merging(timings)
        // A progress update's partial elapsed time must not become the final total.
        record.timings.totalSeconds = timings.sanitized.totalSeconds ?? finishedAt.timeIntervalSince(record.startedAt)
        record.message = Self.limited(message, length: 2_048)
        try persist(record)
        return record
    }

    func records() throws -> [MeasurementAttemptRecord] { try report().records }

    func report() throws -> MeasurementAttemptReport {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .init(records: [], unreadableRecordCount: 0, scanLimitReached: false)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else {
            throw MeasurementAttemptJournalError.invalidRecord
        }
        var records = [UUID: MeasurementAttemptRecord]()
        var scanned = 0, unreadable = 0
        var limited = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard scanned < maximumScannedEntries else { limited = true; break }
            scanned += 1
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do { records[id] = try decode(url, expectedID: id) }
            catch { unreadable += 1 }
        }
        return .init(records: records.values.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }, unreadableRecordCount: unreadable, scanLimitReached: limited)
    }

    func exportCSV() throws -> URL {
        let report = try report()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DobbyAttemptExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lidar-attempts-\(UUID().uuidString).csv")
        try report.csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func url(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    private func load(_ id: UUID) throws -> MeasurementAttemptRecord {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MeasurementAttemptJournalError.notFound }
        return try decode(file, expectedID: id)
    }

    private func decode(_ url: URL, expectedID: UUID) throws -> MeasurementAttemptRecord {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize, size > 0, size <= maximumFileBytes else {
            throw MeasurementAttemptJournalError.invalidRecord
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileBytes else { throw MeasurementAttemptJournalError.invalidRecord }
        let record = try JSONDecoder().decode(MeasurementAttemptRecord.self, from: data)
        guard record.id == expectedID else { throw MeasurementAttemptJournalError.invalidRecord }
        try Self.validate(record)
        return record
    }

    private func persist(_ record: MeasurementAttemptRecord) throws {
        try Self.validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= maximumFileBytes else { throw MeasurementAttemptJournalError.invalidRecord }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url(for: record.id), options: .atomic)
    }

    private static func limited(_ value: String?, length: Int) -> String? { value.map { String($0.prefix(length)) } }

    private static func validate(_ record: MeasurementAttemptRecord) throws {
        guard record.schemaVersion == 1, record.startedAt.timeIntervalSinceReferenceDate.isFinite,
              record.purpose != .fixture || record.isSynthetic,
              (record.deviceContext?.count ?? 0) <= 256, (record.message?.count ?? 0) <= 2_048,
              record.timings == record.timings.sanitized else { throw MeasurementAttemptJournalError.invalidRecord }
        if let finishedAt = record.finishedAt {
            guard record.outcome != nil, finishedAt.timeIntervalSinceReferenceDate.isFinite,
                  finishedAt >= record.startedAt else { throw MeasurementAttemptJournalError.invalidRecord }
        } else if record.outcome != nil { throw MeasurementAttemptJournalError.invalidRecord }
        if record.outcome == .captureFailed, record.phase != .capture { throw MeasurementAttemptJournalError.invalidRecord }
        if record.outcome == .landmarkFailed, record.phase != .landmarks { throw MeasurementAttemptJournalError.invalidRecord }
    }
}
