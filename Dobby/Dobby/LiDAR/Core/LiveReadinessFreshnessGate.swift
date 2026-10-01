import Foundation

/// Keeps asynchronous analysis honest even when camera delivery or Vision stalls.
/// AR timestamps are compared only with AR timestamps; arrival times use monotonic uptime.
nonisolated struct LiveReadinessFreshnessGate: Sendable {
    private let maximumSourceAge: TimeInterval = 2
    private let maximumCameraSilence: TimeInterval = 1
    private var cameraTimestamp: TimeInterval?
    private var cameraArrival: TimeInterval?
    private var cameraIsUsable = false
    private var cameraExpired = false
    private var lastAnalysisTimestamp: TimeInterval?
    private var analysisDeadline: TimeInterval?
    private var invalidatedThrough: TimeInterval = -.infinity

    mutating func reset() { self = Self() }

    /// Returns false for duplicate or reordered callbacks, which must not refresh liveness.
    mutating func recordCamera(
        timestamp: TimeInterval, receivedAt: TimeInterval, trackingStable: Bool, hasDepth: Bool
    ) -> Bool {
        guard timestamp.isFinite, timestamp >= 0, receivedAt.isFinite, receivedAt >= 0,
              cameraTimestamp.map({ timestamp > $0 }) ?? true,
              cameraArrival.map({ receivedAt >= $0 }) ?? true else { return false }
        cameraTimestamp = timestamp
        cameraArrival = receivedAt
        cameraExpired = false
        cameraIsUsable = trackingStable && hasDepth
        if !cameraIsUsable { invalidate(through: timestamp) }
        return true
    }

    /// A late completion cannot revive an expired indication, even if the latest
    /// ARFrame is frozen and therefore still has the same source timestamp.
    mutating func acceptAnalysis(
        timestamp: TimeInterval, currentFrameTimestamp: TimeInterval,
        trackingStable: Bool, hasDepth: Bool, now: TimeInterval
    ) -> Bool {
        guard timestamp.isFinite, timestamp >= 0, currentFrameTimestamp.isFinite,
              now.isFinite, let cameraArrival, now >= cameraArrival,
              now - cameraArrival <= maximumCameraSilence,
              cameraIsUsable, !cameraExpired, trackingStable, hasDepth,
              timestamp > invalidatedThrough,
              lastAnalysisTimestamp.map({ timestamp > $0 }) ?? true else { return false }
        let sourceAge = currentFrameTimestamp - timestamp
        guard sourceAge >= 0, sourceAge <= maximumSourceAge else { return false }
        lastAnalysisTimestamp = timestamp
        // Processing time already spent must not be granted again after arrival.
        analysisDeadline = now + maximumSourceAge - sourceAge
        return true
    }

    /// Returns true only when an indication needs invalidating, not on every
    /// timer tick. The barrier also rejects completions already en route to the UI.
    mutating func expireIfNeeded(now: TimeInterval, currentFrameTimestamp: TimeInterval?) -> Bool {
        guard now.isFinite else { return false }
        let cameraSilent = cameraArrival.map { now - $0 > maximumCameraSilence } ?? false
        let sourceStale: Bool
        if let lastAnalysisTimestamp, analysisDeadline != nil {
            sourceStale = currentFrameTimestamp.map {
                !$0.isFinite || $0 < lastAnalysisTimestamp || $0 - lastAnalysisTimestamp > maximumSourceAge
            } ?? true
        } else { sourceStale = false }
        let analysisExpired = analysisDeadline.map { now >= $0 } ?? false
        guard (cameraSilent && !cameraExpired) || sourceStale || analysisExpired else { return false }
        if cameraSilent { cameraExpired = true; cameraIsUsable = false }
        let barrier = [cameraTimestamp, lastAnalysisTimestamp, currentFrameTimestamp]
            .compactMap { $0 }.filter(\.isFinite).max() ?? 0
        invalidate(through: barrier)
        return true
    }

    private mutating func invalidate(through timestamp: TimeInterval) {
        invalidatedThrough = max(invalidatedThrough, timestamp)
        analysisDeadline = nil
    }
}
