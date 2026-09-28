import Foundation

/// Implemented by the camera owner. The workflow never creates a camera session.
@MainActor
protocol CaptureSnapshotProviding {
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot
}

nonisolated enum AutomaticMeasurementPhase: String, Codable, Sendable {
    case idle, capturing, detectingLandmarks, measuring, completed, failed, cancelled
}

nonisolated enum AutomaticMeasurementStage: String, Codable, Sendable {
    case capture, landmarks, measurement
}

nonisolated enum AutomaticMeasurementFailureCode: String, Codable, Sendable {
    case providerFailure, frameMismatch, invalidProvenance, timedOut, interrupted, cancelled, invalidConfiguration, busy
}

/// An adapter can classify its own errors without making Core import ARKit or
/// matching localized strings. The workflow still supplies the active stage.
nonisolated protocol AutomaticMeasurementFailureClassifying: Error {
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { get }
}

nonisolated struct AutomaticMeasurementWorkflowFailure: Error, LocalizedError, Codable, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying {
    var stage: AutomaticMeasurementStage
    var code: AutomaticMeasurementFailureCode
    var message: String
    var errorDescription: String? { message }
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { code }
}

nonisolated struct AutomaticMeasurementTimings: Codable, Sendable, Equatable {
    /// Nil means the stage was never entered. For a failed/cancelled stage its
    /// duration is time spent before termination, not a completed-stage latency.
    var captureSeconds: TimeInterval?
    var landmarksSeconds: TimeInterval?
    var measurementSeconds: TimeInterval?
    var totalSeconds: TimeInterval
}

nonisolated struct AutomaticMeasurementOutput: Codable, Sendable {
    var runID: UUID
    var snapshot: CaptureSnapshot
    var landmarks: GarmentLandmarkSet
    var result: GarmentMeasurementResult
    var definitions: [MeasurementDefinition]
    var options: MeasurementOptions
    var timings: AutomaticMeasurementTimings
    var startedAt: Date
    var finishedAt: Date
}

nonisolated enum AutomaticMeasurementTerminalStatus: String, Codable, Sendable {
    case completed, failed, cancelled
}

nonisolated struct AutomaticMeasurementTerminalEvent: Sendable {
    var runID: UUID
    var status: AutomaticMeasurementTerminalStatus
    var stage: AutomaticMeasurementStage
    var failure: AutomaticMeasurementWorkflowFailure?
    var snapshot: CaptureSnapshot?
    var result: GarmentMeasurementResult?
    var timings: AutomaticMeasurementTimings
    var startedAt: Date
    var finishedAt: Date
}
