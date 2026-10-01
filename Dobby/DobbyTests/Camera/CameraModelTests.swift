//
//  CameraModelTests.swift
//  DobbyTests
//
//  Created by mason on 9/29/26.
//

import Foundation
import Testing
@testable import Dobby

@MainActor
struct CameraModelTests {
    @Test func happyPathKeepsDraftAndCaptureIdentity() async throws {
        let model = makeModel()
        let sessionID = model.draft.sessionID
        let garmentID = model.draft.garmentID
        #expect(!model.canHandoff)
        try await model.capture()
        let asset = try #require(model.draft.measurement)
        #expect(asset.sessionID == sessionID)
        #expect(asset.garmentID == garmentID)
        #expect(asset.source == .mockPlaceholder)
        #expect(!model.canHandoff)
        try await model.process()
        #expect(model.draft.processingResult?.captureID == asset.id)
        #expect(model.draft.processingResult?.source == .mock)
        #expect(model.draft.processingResult?.confidence == nil)
        #expect(model.canHandoff)
    }

    @Test func processingRequiresCapture() async {
        let model = makeModel()
        await #expect(throws: CameraFailure.missingCapture) { try await model.process() }
        #expect(model.draft.processingResult == nil)
        #expect(!model.canHandoff)
    }

    @Test func captureFromAnotherGarmentIsRejected() async {
        let model = CameraModel(
            captureProvider: WrongGarmentProvider(), processor: MockCaptureProcessor()
        )
        await #expect(throws: CameraFailure.mismatchedCapture) { try await model.capture() }
        #expect(model.draft.measurement == nil)
    }

    @Test func resultFromAnotherCaptureIsRejected() async throws {
        let model = makeModel(processor: StubProcessor(mismatchedID: true))
        try await model.capture()
        await #expect(throws: CameraFailure.mismatchedResult) { try await model.process() }
        #expect(model.draft.processingResult == nil)
        #expect(model.draft.measurement != nil)
    }

    @Test(arguments: [ProcessingResult.Outcome.lowConfidence, .unsupported])
    func uncertainResultCannotCompleteHandoff(outcome: ProcessingResult.Outcome) async throws {
        let model = makeModel(processor: StubProcessor(outcome: outcome))
        try await model.capture()
        try await model.process()
        #expect(!model.canHandoff)
    }

    @Test func processingFailureKeepsInputAndAllowsRetry() async throws {
        let model = makeModel(processor: FailingProcessor())
        try await model.capture()
        let asset = model.draft.measurement
        for _ in 0..<2 {
            await #expect(throws: CameraFailure.processingFailed) { try await model.process() }
        }
        #expect(model.draft.measurement == asset)
        #expect(model.draft.processingResult == nil)
    }

    @Test func resetIgnoresLateResult() async throws {
        let processor = SuspendedProcessor()
        let model = makeModel(processor: processor)
        try await model.capture()
        let oldGarmentID = model.draft.garmentID
        let operation = Task { try await model.process() }
        await processor.waitUntilStarted()
        model.reset()
        processor.complete()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(model.draft.garmentID != oldGarmentID)
        #expect(model.draft.measurement == nil)
        #expect(model.draft.processingResult == nil)
    }

    @Test func cancellationDoesNotCommitResult() async throws {
        let processor = SuspendedProcessor()
        let model = makeModel(processor: processor)
        try await model.capture()
        let operation = Task { try await model.process() }
        await processor.waitUntilStarted()
        operation.cancel()
        processor.complete()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(model.draft.measurement != nil)
        #expect(model.draft.processingResult == nil)
        // Cancellation releases the operation lock too.
        try await model.capture()
    }

    @Test func overlappingRequestsAreRejected() async throws {
        let processor = SuspendedProcessor()
        let model = makeModel(processor: processor)
        try await model.capture()
        let operation = Task { try await model.process() }
        await processor.waitUntilStarted()
        await #expect(throws: CameraFailure.operationInProgress) { try await model.capture() }
        await #expect(throws: CameraFailure.operationInProgress) { try await model.process() }
        processor.complete()
        try await operation.value
        #expect(model.canHandoff)
    }

    @Test func newCaptureClearsPreviousResult() async throws {
        let model = makeModel()
        try await model.capture()
        try await model.process()
        let oldID = model.draft.measurement?.id
        try await model.capture()
        #expect(model.draft.measurement?.id != oldID)
        #expect(model.draft.processingResult == nil)
        #expect(!model.canHandoff)
    }

    private func makeModel(processor: (any CaptureProcessing)? = nil) -> CameraModel {
        CameraModel(captureProvider: MockCameraService(), processor: processor ?? MockCaptureProcessor())
    }
}
