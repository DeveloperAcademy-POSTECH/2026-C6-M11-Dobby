import Foundation

/// Command receipts describe the requested camera controls, not a promise that
/// AF has settled. Exposure observations below belong to the copied ARFrame.
nonisolated struct CameraCaptureSettings: Codable, Sendable, Equatable {
    var settingsRevision: UInt64
    var focusSensorPoint: ImagePoint?
    var requestedExposureBias: Double
    var acceptedExposureBias: Double
    var requestedZoomFactor: Double
    var crop: RegisteredCameraCrop? = nil
    var frameExposureDurationSeconds: Double? = nil
    var frameExposureOffsetEV: Double? = nil
    /// Optional for compatibility with existing saved captures. The device
    /// observation is distinct from the two frame-specific values above.
    var requestedAEAFStatus: CameraAEAFStatus? = nil
    var hardwareObservation: CameraHardwareObservation? = nil
}
