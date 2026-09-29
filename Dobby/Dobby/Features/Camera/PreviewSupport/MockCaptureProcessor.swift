//
//  MockCaptureProcessor.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

/// Only proves routing and capture/result identity. Produces no measured values or confidence.
struct MockCaptureProcessor: CaptureProcessing {
    func process(_ asset: CapturedAsset) async throws -> ProcessingResult {
        try Task.checkCancellation()
        return ProcessingResult(
            captureID: asset.id, source: .mock, outcome: .ready, confidence: nil
        )
    }
}
