//
//  ProductPhotoModelTests.swift
//  DobbyTests
//
//  Created by mason on 9/30/26.
//

import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoModelTests {
    @Test func detailCaptureKeepsUpstreamIdentityWithoutProcessing() async throws {
        let model = try makeModel()
        let input = model.input
        try await model.captureDetail()
        try await model.captureDetail()
        #expect(model.photos.count == 3)
        #expect(model.input == input)
        #expect(Set(model.photos.map(\.id)).count == 3)
        #expect(model.detailPhotos.allSatisfy {
            $0.purpose == .detail && $0.garmentID == input.garmentID && $0.sessionID == input.sessionID
        })
        #expect(model.output == nil)
        model.toggleSelection(input.measurement.id)
        #expect(model.output?.selectedPhotos == [input.measurement])
        #expect(model.output?.garmentID == input.garmentID)
        #expect(model.output?.sessionID == input.sessionID)
    }

    @Test func deselectionKeepsOriginalsAndReselectionAppends() async throws {
        let model = try makeModel()
        try await model.captureDetail()
        let first = model.input.measurement.id
        let second = try #require(model.detailPhotos.first).id
        model.toggleSelection(second)
        model.toggleSelection(first)
        let snapshot = try #require(model.output)
        #expect(snapshot.selectedPhotos.map(\.id) == [second, first])
        #expect(snapshot.representativePhotoID == second)
        model.toggleSelection(second)
        #expect(model.output?.representativePhotoID == first)
        #expect(model.detailPhotos == snapshot.detailPhotos)
        model.toggleSelection(second)
        #expect(model.selectedPhotoIDs == [first, second])
        #expect(snapshot.selectedPhotos.map(\.id) == [second, first])
        model.toggleSelection(first)
        model.toggleSelection(second)
        model.toggleSelection(UUID())
        #expect(model.output == nil)
        #expect(model.photos.count == 2)
    }

    @Test(arguments: ["session", "garment", "purpose"])
    func invalidInputIsRejected(field: String) {
        let input = makeInput()
        let invalid = ProductPhotoInput(
            sessionID: field == "session" ? UUID() : input.sessionID,
            garmentID: field == "garment" ? UUID() : input.garmentID,
            measurement: field == "purpose" ? CapturedAsset(
                id: UUID(), sessionID: input.sessionID, garmentID: input.garmentID,
                purpose: .detail, capturedAt: Date(), source: .mockPlaceholder
            ) : input.measurement
        )
        #expect(throws: CameraFailure.mismatchedCapture) {
            try ProductPhotoModel(input: invalid, captureProvider: MockCameraService(purpose: .detail))
        }
    }

    @Test(arguments: ["session", "garment", "purpose", "duplicate"])
    func invalidCapturePreservesExistingPhotos(field: String) async throws {
        let provider = ProductPhotoCaptureStub()
        let model = try makeModel(provider: provider)
        try await model.captureDetail()
        let existing = model.photos
        provider.nextAsset = CapturedAsset(
            id: field == "duplicate" ? existing[1].id : UUID(),
            sessionID: field == "session" ? UUID() : model.input.sessionID,
            garmentID: field == "garment" ? UUID() : model.input.garmentID,
            purpose: field == "purpose" ? .measurement : .detail,
            capturedAt: Date(), source: .mockPlaceholder
        )
        await #expect(throws: CameraFailure.mismatchedCapture) { try await model.captureDetail() }
        #expect(model.photos == existing)
        #expect(!model.isCapturing)
    }

    @Test func failureKeepsSelectionAndAllowsRetry() async throws {
        let provider = ProductPhotoCaptureStub()
        let model = try makeModel(provider: provider)
        try await model.captureDetail()
        model.toggleSelection(model.detailPhotos[0].id)
        let before = model.output
        provider.failure = .captureFailed
        await #expect(throws: CameraFailure.captureFailed) { try await model.captureDetail() }
        #expect(model.output == before)
        provider.failure = nil
        try await model.captureDetail()
        #expect(model.detailPhotos.count == 2)
        #expect(model.output?.selectedPhotos == before?.selectedPhotos)
    }

    @Test func overlappingCaptureAndCompletionAreBlocked() async throws {
        let provider = ProductPhotoCaptureStub()
        let model = try makeModel(provider: provider)
        model.toggleSelection(model.input.measurement.id)
        provider.suspend = true
        let operation = Task { try await model.captureDetail() }
        await provider.waitUntilStarted()
        #expect(model.isCapturing)
        #expect(model.output == nil)
        await #expect(throws: CameraFailure.operationInProgress) { try await model.captureDetail() }
        provider.complete()
        try await operation.value
        #expect(model.output != nil)
    }

    @Test func cancellationRejectsLatePhotoAndReleasesCapture() async throws {
        let provider = ProductPhotoCaptureStub()
        let model = try makeModel(provider: provider)
        provider.suspend = true
        let operation = Task { try await model.captureDetail() }
        await provider.waitUntilStarted()
        operation.cancel()
        provider.complete()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(model.detailPhotos.isEmpty)
        #expect(!model.isCapturing)
        provider.suspend = false
        try await model.captureDetail()
        #expect(model.detailPhotos.count == 1)
    }

    private func makeInput() -> ProductPhotoInput {
        let asset = CapturedAsset(
            id: UUID(), sessionID: UUID(), garmentID: UUID(),
            purpose: .measurement, capturedAt: Date(), source: .mockPlaceholder
        )
        return ProductPhotoInput(sessionID: asset.sessionID, garmentID: asset.garmentID, measurement: asset)
    }

    private func makeModel(provider: (any CaptureProviding)? = nil) throws -> ProductPhotoModel {
        try ProductPhotoModel(input: makeInput(), captureProvider: provider ?? MockCameraService(purpose: .detail))
    }
}
