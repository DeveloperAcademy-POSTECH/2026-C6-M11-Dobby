import Foundation

/// Gives camera interaction priority over advisory preview analysis. All times
/// use monotonic host uptime, never ARFrame timestamps. Capture suspension is
/// checked separately and cannot be released by a gesture ending or expiring.
nonisolated struct LivePreviewInteractionGate: Sendable {
    private var sessionID: UUID?
    private var exposureAdjustmentActive = false
    private var priorityDeadline: TimeInterval = -.infinity
    private var lastInteractionTime: TimeInterval?
    private let exposureTail: TimeInterval = 0.20

    mutating func reset(sessionID: UUID?) {
        self.sessionID = sessionID
        exposureAdjustmentActive = false
        priorityDeadline = -.infinity
        lastInteractionTime = nil
    }

    /// Returns true when this request extends the existing priority window.
    @discardableResult
    mutating func prioritize(sessionID: UUID, duration: TimeInterval, now: TimeInterval) -> Bool {
        guard accepts(sessionID: sessionID, now: now), duration.isFinite, duration > 0,
              (now + duration).isFinite else { return false }
        let deadline = now + duration
        lastInteractionTime = now
        guard deadline > priorityDeadline else { return false }
        priorityDeadline = deadline
        return true
    }

    /// Repeated lifecycle notifications do not prolong the tail. A stale
    /// session cannot end a current session's drag or change its deadline.
    @discardableResult
    mutating func setExposureAdjustmentActive(_ active: Bool, sessionID: UUID,
                                             now: TimeInterval) -> Bool {
        guard accepts(sessionID: sessionID, now: now), active != exposureAdjustmentActive,
              active || (now + exposureTail).isFinite else { return false }
        exposureAdjustmentActive = active
        lastInteractionTime = now
        if !active { priorityDeadline = max(priorityDeadline, now + exposureTail) }
        return true
    }

    func allowsAnalysis(sessionID: UUID, captureSuspended: Bool, now: TimeInterval) -> Bool {
        accepts(sessionID: sessionID, now: now) && !captureSuspended
            && !exposureAdjustmentActive && now >= priorityDeadline
    }

    private func accepts(sessionID: UUID, now: TimeInterval) -> Bool {
        self.sessionID == sessionID && now.isFinite && now >= 0
            && (lastInteractionTime.map { now >= $0 } ?? true)
    }
}
