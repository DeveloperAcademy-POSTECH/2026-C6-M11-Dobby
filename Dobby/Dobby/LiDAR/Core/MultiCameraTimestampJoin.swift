import Foundation

/// Joins an already atomic wide/depth pair to a separately delivered Ultra preview.
/// All timestamps must use the capture session's synchronization clock. This never
/// creates a measurement pair from independently delivered wide and depth samples.
nonisolated struct MultiCameraTimestampJoin<Primary: Sendable, Secondary: Sendable>: Sendable {
    struct PrimaryEntry: Sendable {
        let value: Primary
        let timestamp: TimeInterval
        let endTimestamp: TimeInterval
    }

    struct SecondaryEntry: Sendable {
        let value: Secondary
        let timestamp: TimeInterval
    }

    struct Match: Sendable {
        let primary: Primary
        let secondary: Secondary
        let primaryTimestamp: TimeInterval
        let primaryEndTimestamp: TimeInterval
        let secondaryTimestamp: TimeInterval
    }

    private(set) var sessionID: UUID
    private let maxSkew: TimeInterval
    private let capacity = 3
    private var primaries: [PrimaryEntry] = []
    private var secondaries: [SecondaryEntry] = []
    private var newestPrimaryTimestamp: TimeInterval = -.infinity
    private var newestSecondaryTimestamp: TimeInterval = -.infinity
    private var publishedPrimaryTimestamp: TimeInterval = -.infinity
    private var consumedSecondaryTimestamp: TimeInterval = -.infinity

    init(sessionID: UUID, maxSkew: TimeInterval) {
        precondition(maxSkew.isFinite && maxSkew >= 0)
        self.sessionID = sessionID
        self.maxSkew = maxSkew
    }

    /// Only the owner starts a generation. Late callbacks cannot reset the join.
    mutating func begin(sessionID: UUID) {
        self = Self(sessionID: sessionID, maxSkew: maxSkew)
    }

    mutating func insertPrimary(
        value: Primary, timestamp: TimeInterval, endTimestamp: TimeInterval, sessionID: UUID
    ) -> Match? {
        insert(primary: .init(value: value, timestamp: timestamp, endTimestamp: endTimestamp),
               secondary: nil, sessionID: sessionID)
    }

    mutating func insertSecondary(
        value: Secondary, timestamp: TimeInterval, sessionID: UUID
    ) -> Match? {
        insert(primary: nil, secondary: .init(value: value, timestamp: timestamp), sessionID: sessionID)
    }

    /// Enqueue both members before choosing a match: a current Ultra sample must
    /// beat a less accurate, older sample already waiting in the small buffer.
    mutating func insert(
        primary: PrimaryEntry?, secondary: SecondaryEntry?, sessionID: UUID
    ) -> Match? {
        guard sessionID == self.sessionID else { return nil }
        if let primary, isValid(primary), primary.timestamp > newestPrimaryTimestamp {
            newestPrimaryTimestamp = primary.timestamp
            primaries.append(primary)
            if primaries.count > capacity { primaries.removeFirst(primaries.count - capacity) }
        }
        if let secondary, secondary.timestamp.isFinite, secondary.timestamp >= 0,
           secondary.timestamp > newestSecondaryTimestamp {
            newestSecondaryTimestamp = secondary.timestamp
            secondaries.append(secondary)
            if secondaries.count > capacity { secondaries.removeFirst(secondaries.count - capacity) }
        }

        // Source timestamps are monotonic within each stream. Prefer the newest
        // eligible measurement pair, then the Ultra closest to that pair's time.
        for primary in primaries.reversed() where primary.timestamp > publishedPrimaryTimestamp {
            let midpoint = primary.timestamp + (primary.endTimestamp - primary.timestamp) / 2
            let secondary = secondaries
                .filter { $0.timestamp > consumedSecondaryTimestamp && span(primary, $0) <= maxSkew }
                .min {
                    let lhs = abs($0.timestamp - midpoint), rhs = abs($1.timestamp - midpoint)
                    return lhs == rhs ? $0.timestamp > $1.timestamp : lhs < rhs
                }
            guard let secondary else { continue }
            publishedPrimaryTimestamp = primary.timestamp
            consumedSecondaryTimestamp = secondary.timestamp
            primaries.removeAll { $0.timestamp <= primary.timestamp }
            secondaries.removeAll { $0.timestamp <= secondary.timestamp }
            discardImpossibleEntries()
            return Match(primary: primary.value, secondary: secondary.value,
                         primaryTimestamp: primary.timestamp, primaryEndTimestamp: primary.endTimestamp,
                         secondaryTimestamp: secondary.timestamp)
        }
        discardImpossibleEntries()
        return nil
    }

    private func isValid(_ entry: PrimaryEntry) -> Bool {
        entry.timestamp.isFinite && entry.endTimestamp.isFinite && entry.timestamp >= 0 &&
            entry.endTimestamp >= entry.timestamp && entry.endTimestamp - entry.timestamp <= maxSkew
    }

    private func span(_ primary: PrimaryEntry, _ secondary: SecondaryEntry) -> TimeInterval {
        max(primary.endTimestamp, secondary.timestamp) - min(primary.timestamp, secondary.timestamp)
    }

    /// Once the other stream has advanced beyond an unmatched sample's window,
    /// that sample cannot match any future delivery. It must not revive later.
    private mutating func discardImpossibleEntries() {
        primaries = primaries.filter { primary in
            primary.timestamp > publishedPrimaryTimestamp &&
                (newestSecondaryTimestamp - primary.timestamp <= maxSkew ||
                 secondaries.contains { span(primary, $0) <= maxSkew })
        }
        secondaries = secondaries.filter { secondary in
            secondary.timestamp > consumedSecondaryTimestamp &&
                (newestPrimaryTimestamp - secondary.timestamp <= maxSkew ||
                 primaries.contains { span($0, secondary) <= maxSkew })
        }
    }
}
