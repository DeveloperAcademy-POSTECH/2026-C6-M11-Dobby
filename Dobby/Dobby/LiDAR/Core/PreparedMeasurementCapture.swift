import Foundation

/// Runtime-only evidence from one frozen camera frame. The snapshot retains
/// the existing persistence format; prepared points never become snapshot metadata.
nonisolated struct PreparedMeasurementCapture: Sendable {
    var snapshot: CaptureSnapshot
    var landmarks: GarmentLandmarkSet? = nil
}

/// A camera may return landmarks prepared from the exact captured RGB frame.
/// The workflow still verifies identity, provenance and the provider's schema.
@MainActor
protocol PreparedCaptureSnapshotProviding: CaptureSnapshotProviding {
    func capturePrepared(orientation: ImageOrientation) async throws -> PreparedMeasurementCapture
}
