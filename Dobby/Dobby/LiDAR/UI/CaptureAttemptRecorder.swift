import Foundation
import UIKit

enum LiDARAppServices {
    static let attemptJournal = MeasurementAttemptJournal()
}

@MainActor
enum CaptureAttemptRecorder {
    /// Manual lab attempts end at capture. Human point placement is deliberately
    /// excluded from automatic pipeline latency and geometry success statistics.
    static func capture(camera: any CaptureSnapshotProviding, orientation: ImageOrientation) async throws -> CaptureSnapshot {
        let journal = LiDARAppServices.attemptJournal
        let attempt = try await journal.begin(purpose: .manualSensor, isSynthetic: false, deviceContext: UIDevice.current.model)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let snapshot = try await camera.capture(orientation: orientation)
            try Task.checkCancellation()
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
            _ = try await journal.finish(id: attempt.id, outcome: .success, phase: .capture,
                sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
                timings: .init(captureSeconds: elapsed, totalSeconds: elapsed))
            return snapshot
        } catch {
            let outcome: MeasurementAttemptOutcome
            if error is CancellationError { outcome = .cancelled }
            else if let captureError = error as? ARKitCaptureError {
                switch captureError {
                case .timedOut: outcome = .timedOut
                case .interrupted, .stopped: outcome = .interrupted
                default: outcome = .captureFailed
                }
            } else { outcome = .captureFailed }
            _ = try? await journal.finish(id: attempt.id, outcome: outcome, phase: .capture,
                timings: .init(totalSeconds: max(0, ProcessInfo.processInfo.systemUptime - started)),
                message: error.localizedDescription)
            throw error
        }
    }
}
