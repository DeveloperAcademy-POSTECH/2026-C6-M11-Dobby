//
//  CameraTestDoubles.swift
//  DobbyTests
//
//  Created by mason on 9/29/26.
//

import Foundation
@testable import Dobby

@MainActor
struct WrongGarmentProvider: CaptureProviding {
    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        CapturedAsset(
            id: UUID(), sessionID: sessionID, garmentID: UUID(),
            purpose: .measurement, capturedAt: Date(), source: .mockPlaceholder
        )
    }
}

@MainActor
struct StubProcessor: CaptureProcessing {
    var mismatchedID = false
    var outcome: ProcessingResult.Outcome = .ready

    func process(_ asset: CapturedAsset) async throws -> ProcessingResult {
        ProcessingResult(
            captureID: mismatchedID ? UUID() : asset.id,
            source: .mock, outcome: outcome, confidence: nil
        )
    }
}

@MainActor
struct FailingProcessor: CaptureProcessing {
    func process(_ asset: CapturedAsset) async throws -> ProcessingResult {
        throw CameraFailure.processingFailed
    }
}

/// Deliberately ignores cancellation so the model must reject a late completion itself.
@MainActor
final class SuspendedProcessor: CaptureProcessing {
    private var pending: CheckedContinuation<ProcessingResult, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var captureID: UUID?

    func process(_ asset: CapturedAsset) async throws -> ProcessingResult {
        captureID = asset.id
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete() {
        guard let captureID else { return }
        pending?.resume(returning: ProcessingResult(
            captureID: captureID, source: .mock, outcome: .ready, confidence: nil
        ))
        pending = nil
    }
}
