// Created by mason on 10/6/26.
import Foundation
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductPhotoDeletionTests {
    @Test func diskDeletionRemovesOnlyRequestedDetailAndKeepsMeasurement() async throws {
        let folder = URL.temporaryDirectory.appending(path: "Dobby-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seedURL = folder.appending(path: "measurement.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).jpegData(withCompressionQuality: 1) {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        try data.write(to: seedURL)
        let source = CapturedAsset.Source.localFile(seedURL, metadata: .init(
            pixelWidth: 10, pixelHeight: 10, contentType: "public.jpeg", orientation: .up))
        let measured = CapturedAsset(id: UUID(), sessionID: UUID(), garmentID: UUID(),
            purpose: .measurement, capturedAt: .now, source: source)
        let model = try ProductPhotoModel(input: .init(sessionID: measured.sessionID,
            garmentID: measured.garmentID, measurement: measured),
            captureProvider: ProductPhotoFixtureCaptureProvider(seed: source, directory: folder.appending(path: "details")))
        try await model.captureDetail()
        try await model.captureDetail()
        let first = model.detailPhotos[0], second = model.detailPhotos[1]
        guard case let .localFile(firstURL, _) = first.source,
              case let .localFile(secondURL, _) = second.source else { Issue.record("파일 촬영본 필요"); return }
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        try await model.deleteDetail(first.id)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(try Data(contentsOf: seedURL) == data)
    }

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

    @Test func allPhotoKindsCanBeDeletedAndEmptyDraftRestoresWithoutResurrection() async throws {
        let (seed, provider) = try fixture()
        var input = seed.input
        let visual = CapturedAsset(id: UUID(), sessionID: input.sessionID, garmentID: input.garmentID,
            purpose: .measurementVisualization, capturedAt: .now,
            source: .localFile(URL(fileURLWithPath: "/tmp/measurement-visual.png"), metadata: .init(
                pixelWidth: 10, pixelHeight: 10, contentType: "public.png", orientation: .up)))
        input.measurementVisualization = visual
        let model = try ProductPhotoModel(input: input, captureProvider: provider)
        try await model.captureDetail()
        let detail = try #require(model.detailPhotos.first)
        try await model.deletePhoto(input.measurement.id)
        #expect(model.allPhotosOutput?.selectedPhotos.map(\.id) == [visual.id, detail.id])
        #expect(model.allPhotosOutput?.representativePhotoID == visual.id)
        try await model.deletePhoto(visual.id)
        #expect(model.allPhotosOutput?.representativePhotoID == detail.id)
        #expect(provider.discarded.isEmpty) // 실측 보정용 원자료는 촬영 provider가 삭제하지 않는다.
        try await model.deletePhoto(detail.id)
        #expect(model.allPhotosOutput == nil)
        #expect(model.selectablePhotos.isEmpty)
        let snapshot = try model.makeDraftSnapshot()
        let restored = try JSONDecoder().decode(ProductPhotoDraftSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        let resumed = try ProductPhotoModel(input: input, captureProvider: provider,
            initialDetailPhotos: restored.restoredDetailPhotos(for: input),
            initialSelectedPhotoIDs: restored.selectedPhotoIDs,
            initialDeletedPhotoIDs: restored.deletedPhotoIDs ?? [])
        #expect(resumed.selectablePhotos.isEmpty)
        #expect(resumed.allPhotosOutput == nil)
        try await resumed.captureDetail()
        #expect(resumed.allPhotosOutput?.selectedPhotos.count == 1)
        #expect(resumed.allPhotosOutput?.deletedPhotoIDs == [input.measurement.id, visual.id, detail.id])
        await #expect(throws: CameraFailure.missingCapture) { try await resumed.deletePhoto(visual.id) }

        // 기존 초안에는 삭제 필드가 없어도 디코딩된다.
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "deletedPhotoIDs")
        let old = try JSONDecoder().decode(ProductPhotoDraftSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.deletedPhotoIDs == nil)
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
