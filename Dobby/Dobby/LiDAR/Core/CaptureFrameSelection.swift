import Foundation

/// AVFoundation has synchronized, calibrated LiDAR but no AR world tracking.
/// Keep that evidence explicit rather than claiming an AR tracking state.
nonisolated enum CaptureFrameEvidence: String, Codable, Sendable {
    case synchronizedCalibratedLiDAR
}

/// Full-field depth quality used to compare nearby shutter candidates. This is
/// neither a garment mask score nor a centimetre-accuracy estimate.
nonisolated struct CaptureFrameQuality: Codable, Sendable, Equatable {
    var timestamp: TimeInterval
    var validDepthCoverage: Double
    var highConfidenceCoverage: Double?
    var validDepthSampleCount: Int
    var trackingNormal: Bool
    var translationSpeedMetersPerSecond: Double?
    var angularSpeedRadiansPerSecond: Double?
    /// Nil preserves decoding/selection of previously saved ARKit captures.
    var captureEvidence: CaptureFrameEvidence? = nil

    static let maximumTranslationSpeed = 0.10
    static let maximumAngularSpeed = 12 * Double.pi / 180

    var motionKnown: Bool {
        guard let translationSpeedMetersPerSecond, let angularSpeedRadiansPerSecond else { return false }
        return translationSpeedMetersPerSecond.isFinite && translationSpeedMetersPerSecond >= 0
            && angularSpeedRadiansPerSecond.isFinite && angularSpeedRadiansPerSecond >= 0
    }

    var isEligible: Bool {
        guard timestamp.isFinite, timestamp >= 0,
              trackingNormal || captureEvidence == .synchronizedCalibratedLiDAR,
              validDepthCoverage.isFinite, (0...1).contains(validDepthCoverage),
              validDepthSampleCount >= 30, validDepthCoverage > 0 else { return false }
        if let highConfidenceCoverage {
            guard highConfidenceCoverage.isFinite,
                  (0...validDepthCoverage).contains(highConfidenceCoverage) else { return false }
        }
        if let speed = translationSpeedMetersPerSecond {
            guard speed.isFinite, speed >= 0, speed < Self.maximumTranslationSpeed else { return false }
        }
        if let speed = angularSpeedRadiansPerSecond {
            guard speed.isFinite, speed >= 0, speed < Self.maximumAngularSpeed else { return false }
        }
        return true
    }

    /// Empirical capture preference, kept explicit for later device validation.
    /// Depth coverage describes the full image, so a small increase must not
    /// completely mask camera motion. Discount the depth contribution by at most
    /// 25% as motion approaches the existing limits. Unknown motion receives no
    /// stability bonus, but remains eligible so it cannot delay the shutter.
    /// This is a ranking score, not an uncertainty or centimetre-accuracy bound.
    var score: Double {
        guard isEligible else { return 0 }
        let stability: Double
        if let translationSpeedMetersPerSecond, let angularSpeedRadiansPerSecond {
            stability = 1 - max(translationSpeedMetersPerSecond / Self.maximumTranslationSpeed,
                                angularSpeedRadiansPerSecond / Self.maximumAngularSpeed)
        } else { stability = 0 }
        let depthQuality = 0.55 * validDepthCoverage + 0.35 * (highConfidenceCoverage ?? 0)
        let motionDepthWeight = 0.75 + 0.25 * stability
        return depthQuality * motionDepthWeight + 0.10 * stability
    }

    static func evaluate(
        depth: DepthMap?, timestamp: TimeInterval, trackingNormal: Bool,
        translationSpeedMetersPerSecond: Double?, angularSpeedRadiansPerSecond: Double?
    ) -> Self {
        var result = Self(timestamp: timestamp, validDepthCoverage: 0, highConfidenceCoverage: nil,
                          validDepthSampleCount: 0, trackingNormal: trackingNormal,
                          translationSpeedMetersPerSecond: translationSpeedMetersPerSecond,
                          angularSpeedRadiansPerSecond: angularSpeedRadiansPerSecond)
        guard let depth, depth.size.isValid, depth.values.count <= 1_048_576,
              depth.values.count == depth.size.width * depth.size.height else { return result }
        let confidence = depth.confidence.flatMap { values in
            values.count == depth.values.count && values.allSatisfy { $0 <= 2 } ? values : nil
        }
        let options = MeasurementOptions()
        var highCount = 0
        for index in depth.values.indices {
            let value = Double(depth.values[index])
            if value.isFinite, value >= options.minimumDepthMeters, value <= options.maximumDepthMeters {
                result.validDepthSampleCount += 1
                if confidence?[index] == 2 { highCount += 1 }
            }
        }
        result.validDepthCoverage = Double(result.validDepthSampleCount) / Double(depth.values.count)
        if confidence != nil { result.highConfidenceCoverage = Double(highCount) / Double(depth.values.count) }
        return result
    }
}

nonisolated struct CaptureSelectionSummary: Codable, Sendable, Equatable {
    var observedFrameCount: Int
    var eligibleCandidateCount: Int
    var waitingDurationSeconds: TimeInterval
    var selectionWindowSeconds: TimeInterval
    var selectedFrameTimestamp: TimeInterval
    var selectedQuality: CaptureFrameQuality
    var policyVersion: String = "depth-confidence-motion-v2"
}

/// One bounded shutter selection. The owner stores at most the winning RGB/depth
/// copy; this type stores only small quality values. Request IDs make delayed
/// timers and cancelled requests unable to complete another shutter operation.
nonisolated struct CaptureFrameSelector: Sendable {
    static let windowDuration: TimeInterval = 0.35
    let requestID: UUID
    let startedAt: TimeInterval
    /// AR source-clock boundary sampled when the shutter is requested. Kept
    /// separate from startedAt, which belongs to the monotonic arrival clock.
    let minimumFrameTimestamp: TimeInterval?
    private(set) var windowEndsAt: TimeInterval?
    private(set) var bestQuality: CaptureFrameQuality?
    private(set) var observedFrameCount = 0
    private(set) var eligibleCandidateCount = 0
    private var lastFrameTimestamp: TimeInterval?
    private var lastArrival: TimeInterval?
    private var finished = false

    init(requestID: UUID, startedAt: TimeInterval, minimumFrameTimestamp: TimeInterval? = nil) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.minimumFrameTimestamp = minimumFrameTimestamp
        finished = !startedAt.isFinite || startedAt < 0
            || (minimumFrameTimestamp.map({ !$0.isFinite || $0 < 0 }) ?? false)
    }

    /// Returns true only when the caller should replace its owned image/depth copy.
    mutating func consider(_ quality: CaptureFrameQuality, requestID: UUID, now: TimeInterval) -> Bool {
        guard requestID == self.requestID, !finished, now.isFinite, now >= startedAt,
              lastArrival.map({ now >= $0 }) ?? true,
              windowEndsAt.map({ now < $0 }) ?? true else { return false }
        lastArrival = now
        observedFrameCount += 1
        guard quality.timestamp.isFinite, quality.timestamp >= 0,
              minimumFrameTimestamp.map({ quality.timestamp > $0 }) ?? true,
              lastFrameTimestamp.map({ quality.timestamp > $0 }) ?? true else { return false }
        lastFrameTimestamp = quality.timestamp
        guard quality.isEligible else { return false }
        eligibleCandidateCount += 1
        if windowEndsAt == nil { windowEndsAt = now + Self.windowDuration }
        guard bestQuality.map({ quality.score > $0.score }) ?? true else { return false }
        bestQuality = quality
        return true
    }

    /// Called by a monotonic timer, so capture also finishes when frame delivery
    /// stops after a valid candidate. No new ARFrame is needed to close the window.
    mutating func finish(requestID: UUID, now: TimeInterval) -> CaptureSelectionSummary? {
        guard requestID == self.requestID, !finished, now.isFinite,
              let windowEndsAt, now >= windowEndsAt, let bestQuality else { return nil }
        finished = true
        return CaptureSelectionSummary(
            observedFrameCount: observedFrameCount, eligibleCandidateCount: eligibleCandidateCount,
            waitingDurationSeconds: now - startedAt, selectionWindowSeconds: Self.windowDuration,
            selectedFrameTimestamp: bestQuality.timestamp, selectedQuality: bestQuality)
    }

    mutating func cancel(requestID: UUID) {
        guard requestID == self.requestID else { return }
        finished = true
        bestQuality = nil
    }
}
