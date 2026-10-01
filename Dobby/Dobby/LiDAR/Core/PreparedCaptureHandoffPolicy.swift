import Foundation

/// Identity of one accepted live result, not a hint that may be attached to a
/// newer photo. Frame IDs refer to the owned RGB, depth and landmarks together.
nonisolated struct PreparedCaptureHandoffIdentity: Equatable, Sendable {
    var sessionID: UUID
    var frameID: UUID
    var analysisEpoch: UUID
    var timestamp: TimeInterval
    var orientation: ImageOrientation
    var garmentKind: AutomaticGarmentKind
    var modelVersion: String
}

nonisolated struct PreparedCaptureHandoffObservation: Sendable {
    var sessionID: UUID?
    var readiness: LiveCaptureReadiness
    var orientation: ImageOrientation
    var currentFrameTimestamp: TimeInterval
    var cameraObservationTimestamp: TimeInterval
    var trackingStable: Bool
    var hasDepth: Bool
    var freshnessExpired: Bool
    var translationSpeedMetersPerSecond: Double?
    var angularSpeedRadiansPerSecond: Double?
}

/// Reuses the existing live freshness and motion limits. A consumed or
/// invalidated ticket cannot be revived by a delayed callback for that frame.
nonisolated struct PreparedCaptureHandoffPolicy: Sendable {
    private var accepted: PreparedCaptureHandoffIdentity?
    private var retired: PreparedCaptureHandoffIdentity?
    private var latestOffered: PreparedCaptureHandoffIdentity?

    @discardableResult
    mutating func offer(_ identity: PreparedCaptureHandoffIdentity, readiness: LiveCaptureReadiness) -> Bool {
        if let accepted { retired = accepted }
        accepted = nil
        guard retired != identity, identity.timestamp.isFinite, identity.timestamp >= 0,
              identity.modelVersion == identity.garmentKind.modelVersion,
              Self.matches(identity, readiness: readiness) else { return false }
        // Keep only a high-water mark, not a growing set of owned images or IDs.
        // The adapter validates the current session/epoch before offering; within
        // that epoch, an older callback can never revive a consumed source frame.
        if let latestOffered, latestOffered.sessionID == identity.sessionID,
           latestOffered.analysisEpoch == identity.analysisEpoch,
           identity.timestamp <= latestOffered.timestamp { return false }
        latestOffered = identity
        accepted = identity
        return true
    }

    mutating func invalidate() {
        if let accepted { retired = accepted }
        accepted = nil
    }

    @discardableResult
    mutating func consume(_ identity: PreparedCaptureHandoffIdentity,
                          observation: PreparedCaptureHandoffObservation) -> Bool {
        let eligible = accepted == identity
        if let accepted { retired = accepted }
        accepted = nil
        guard eligible,
              observation.sessionID == identity.sessionID,
              observation.orientation == identity.orientation,
              Self.matches(identity, readiness: observation.readiness),
              observation.currentFrameTimestamp.isFinite,
              observation.cameraObservationTimestamp.isFinite,
              !observation.freshnessExpired, observation.trackingStable, observation.hasDepth,
              let translation = observation.translationSpeedMetersPerSecond,
              let rotation = observation.angularSpeedRadiansPerSecond,
              translation.isFinite, rotation.isFinite, translation >= 0, rotation >= 0,
              translation < CaptureFrameQuality.maximumTranslationSpeed,
              rotation < CaptureFrameQuality.maximumAngularSpeed else { return false }
        let sourceAge = observation.currentFrameTimestamp - identity.timestamp
        let cameraAge = observation.currentFrameTimestamp - observation.cameraObservationTimestamp
        // Same limits as LiveReadinessFreshnessGate: two seconds of source age
        // and one second without usable camera evidence, never renewed at tap.
        guard sourceAge >= 0, sourceAge <= 2, cameraAge >= 0, cameraAge <= 1 else { return false }
        retired = identity
        return true
    }

    private static func matches(_ identity: PreparedCaptureHandoffIdentity,
                                readiness: LiveCaptureReadiness) -> Bool {
        readiness.isReady && readiness.garmentRecognized
            && readiness.timestamp == identity.timestamp
            && readiness.analysisEpoch == identity.analysisEpoch
            && readiness.imageOrientation == identity.orientation
            && readiness.garmentKind == identity.garmentKind
            && readiness.recognitionModelVersion == identity.modelVersion
    }
}
