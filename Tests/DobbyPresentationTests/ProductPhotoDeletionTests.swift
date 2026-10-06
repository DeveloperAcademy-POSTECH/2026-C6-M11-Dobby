// Created by mason on 10/6/26.
import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoDeletionTests {
    @Test func deletionProtectsMeasurementAndPreservesRemainingOrder() async throws {
        let (model, provider) = try fixture()
        for _ in 0..<3 { try await model.captureDetail() }
        let ids = model.detailPhotos.map(\.id)
        model.toggleSelection(ids[1])
        model.toggleSelection(ids[0])
        await #expect(throws: CameraFailure.missingCapture) { try await model.deleteDetail(model.input.measurement.id) }
        await #expect(throws: CameraFailure.missingCapture) { try await model.deleteDetail(UUID()) }
        #expect(provider.discarded.isEmpty)
        try await model.deleteDetail(ids[1])
        #expect(model.detailPhotos.map(\.id) == [ids[0], ids[2]])
        #expect(model.selectedPhotoIDs == [ids[0]])
        #expect(model.output?.representativePhotoID == ids[0])
        #expect(model.output?.selectedPhotos.map(\.id) == [ids[0]])
        try await model.deleteDetail(ids[2]) // 선택하지 않은 컷
        #expect(model.selectedPhotoIDs == [ids[0]])
        try await model.deleteDetail(ids[0])
        #expect(model.photos == [model.input.measurement])
        #expect(model.output == nil)
        #expect(provider.discarded == [ids[1], ids[2], ids[0]])
        try await model.captureDetail()
        #expect(model.detailPhotos.count == 1)
    }

    @Test func failurePreservesPhotosAndSelectionUntilRetrySucceeds() async throws {
        let (model, provider) = try fixture()
        try await model.captureDetail()
        let id = try #require(model.detailPhotos.first?.id)
        model.toggleSelection(id)
        let before = model.photos
        provider.shouldFail = true
        await #expect(throws: CameraFailure.saveFailed) { try await model.deleteDetail(id) }
        #expect(model.photos == before)
        #expect(model.selectedPhotoIDs == [id])
        #expect(model.output?.representativePhotoID == id)
        #expect(!model.isDeleting)
        provider.shouldFail = false
        try await model.deleteDetail(id)
        #expect(model.detailPhotos.isEmpty && model.selectedPhotoIDs.isEmpty)
    }

    @Test func pendingDeletionBlocksConflictsAndCompletesBeforeDraftCleanup() async throws {
        let (model, provider) = try fixture()
        try await model.captureDetail()
        let id = try #require(model.detailPhotos.first?.id)
        model.toggleSelection(id)
        provider.suspend = true
        let deletion = Task { try await model.deleteDetail(id) }
        await provider.waitUntilStarted()
        #expect(model.isDeleting && model.output == nil)
        #expect(model.detailPhotos.count == 1)
        await #expect(throws: CameraFailure.operationInProgress) { try await model.deleteDetail(id) }
        await #expect(throws: CameraFailure.operationInProgress) { try await model.captureDetail() }
        model.toggleSelection(id)
        #expect(model.selectedPhotoIDs == [id])
        let cleanup = Task { try await model.discardUncommittedDetails() }
        await Task.yield()
        deletion.cancel()
        provider.complete()
        try await deletion.value
        try await cleanup.value
        #expect(provider.discarded == [id])
        #expect(model.photos == [model.input.measurement])
        #expect(model.selectedPhotoIDs.isEmpty && !model.isDeleting)
    }

    private func fixture() throws -> (ProductPhotoModel, DeleteProvider) {
        let measurement = CapturedAsset(id: UUID(), sessionID: UUID(), garmentID: UUID(),
            purpose: .measurement, capturedAt: .now, source: .mockPlaceholder)
        let provider = DeleteProvider()
        return (try ProductPhotoModel(input: .init(sessionID: measurement.sessionID,
            garmentID: measurement.garmentID, measurement: measurement), captureProvider: provider), provider)
    }

    private final class DeleteProvider: CaptureProviding {
        var discarded: [UUID] = []
        var shouldFail = false
        var suspend = false
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
            CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID,
                purpose: .detail, capturedAt: .now, source: .mockPlaceholder)
        }
        func discardUncommitted(_ asset: CapturedAsset) async throws {
            if suspend {
                await withCheckedContinuation { continuation in
                    pending = continuation; started?.resume(); started = nil
                }
            }
            if shouldFail { throw CameraFailure.saveFailed }
            discarded.append(asset.id)
        }
        func waitUntilStarted() async {
            if pending == nil { await withCheckedContinuation { started = $0 } }
        }
        func complete() { pending?.resume(); pending = nil; suspend = false }
    }
}
