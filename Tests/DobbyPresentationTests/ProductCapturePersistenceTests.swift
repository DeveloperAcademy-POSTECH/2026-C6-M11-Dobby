// Created by mason on 11/8/26.
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductCapturePersistenceTests {
    @Test func allOriginalsPersistWhileRegistrationIsLimitedToTenWithoutDuplicateCopies() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let details = try (0..<11).map { _ in try f.detail() }
        try await f.apply(details)
        let expected = f.input.measurementPhotos.map(\.id) + details.map(\.id)
        #expect(f.garment.productPhotos.map(\.id) == Array(expected.prefix(10)))
        #expect(f.garment.thumbnail?.id == f.input.measurement.id)
        let firstAppliedAt = try #require(f.garment.capturePhotosAppliedAt)
        try await f.apply(details)
        #expect(f.garment.photos.count == 13)
        #expect(f.garment.capturePhotosAppliedAt == firstAppliedAt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 13)
        let reader = ModelContext(f.container)
        let stored = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(stored.productPhotos.map(\.id) == Array(expected.prefix(10)))
        #expect(stored.capturePhotosAppliedAt == firstAppliedAt)
        for detail in details {
            let saved = try #require(stored.photos.first { $0.id == detail.id })
            guard case let .localFile(source, _) = detail.source else { return }
            #expect(try Data(contentsOf: source) == Data(contentsOf: f.photos.appending(path: saved.fileName)))
        }
    }

    @Test func revisitingPreservesEditsAndAppendsOnlyNewCapture() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.detail(), second = try f.detail()
        try await f.apply([first])
        let representative = try #require(f.garment.photos.first { $0.id == first.id })
        let original = try #require(f.garment.measurementPhoto)
        let visual = try #require(f.garment.photos.first { $0.id == f.input.measurementVisualization?.id })
        original.isSelectedForProduct = false
        original.role = .detail
        representative.role = .thumbnail
        GarmentStore.reorder([representative, visual, original], in: f.garment)
        try f.context.save()
        try await f.apply([first, second])
        #expect(f.garment.orderedPhotos.map(\.id) == [first.id, visual.id, original.id, second.id])
        #expect(f.garment.productPhotos.map(\.id) == [first.id, visual.id, second.id])
        #expect(f.garment.thumbnail?.id == first.id)
        #expect(f.garment.measurementPhoto === original)
    }

    @Test func failedSaveRestoresMarkerPhotosAndFilesThenRetrySucceeds() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let detail = try f.detail()
        let before = f.garment.productPhotos.map(\.id)
        await #expect(throws: SaveFailure.self) {
            try await f.apply([detail], persist: { _ in throw SaveFailure.failed })
        }
        #expect(f.garment.capturePhotosAppliedAt == nil)
        #expect(f.garment.productPhotos.map(\.id) == before)
        #expect(f.garment.photos.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 2)
        try await f.apply([detail])
        #expect(f.garment.productPhotos.count == 3)
    }

    @Test func partialSelectionIsRejectedByAllPhotosPath() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let output = ProductPhotoOutput(sessionID: f.input.sessionID, garmentID: f.garment.id,
            detailPhotos: [], selectedPhotos: [f.input.measurement], representativePhotoID: f.input.measurement.id)
        await #expect(throws: ProductPhotoHandoff.HandoffError.self) {
            try await ProductPhotoHandoff.apply(output, to: f.garment, in: f.context, input: f.input,
                photosDirectory: f.photos, includesAllCapturedPhotos: true)
        }
        #expect(f.garment.capturePhotosAppliedAt == nil)
    }

    @Test func galleryDeletionExcludesPreviouslyImportedPhotosAndPreservesSourcesOnRetry() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.detail(), remaining = try f.detail()
        try await f.apply([first, remaining])
        let deleted: Set<UUID> = [f.input.measurement.id, try #require(f.input.measurementVisualization?.id), first.id]
        let previous = f.garment.productPhotos.map(\.id)
        let recordID = UUID()
        f.garment.sourceMeasurementID = recordID
        f.garment.measurementPhoto?.measurementSessionID = f.input.sessionID
        let model = try ProductPhotoModel(input: f.input,
            captureProvider: ProductPhotoFixtureCaptureProvider(seed: f.input.measurement.source),
            initialDetailPhotos: [first, remaining])
        try ProductDraftStore.save(garment: f.garment, step: .details, measurementRecordID: recordID,
            photoModel: model, measurementInputData: nil, in: f.context)
        let previousDraft = f.garment.creationDraftData
        for id in deleted { try await model.deletePhoto(id) }
        await #expect(throws: SaveFailure.self) {
            try await f.apply([remaining], deleted: deleted, persist: { context in
                try ProductDraftStore.save(garment: f.garment, step: .information, measurementRecordID: recordID,
                    photoModel: model, measurementInputData: nil, in: context,
                    persist: { _ in throw SaveFailure.failed })
            })
        }
        #expect(f.garment.creationDraftData == previousDraft)
        #expect(f.garment.productPhotos.map(\.id) == previous)
        #expect(f.garment.thumbnail?.id == f.input.measurement.id)
        try await f.apply([remaining], deleted: deleted, persist: { context in
            try ProductDraftStore.save(garment: f.garment, step: .information, measurementRecordID: recordID,
                photoModel: model, measurementInputData: nil, in: context)
        })
        #expect(f.garment.creationDraft?.photoState?.deletedPhotoIDs == deleted)
        #expect(f.garment.productPhotos.map(\.id) == [remaining.id])
        #expect(f.garment.thumbnail?.id == remaining.id)
        #expect(f.garment.measurementPhoto?.id == f.input.measurement.id)
        #expect(FileManager.default.fileExists(atPath: f.photos.appending(path: "original.jpg").path))
        try await f.apply([remaining], deleted: deleted)
        #expect(f.garment.productPhotos.map(\.id) == [remaining.id])
        let reader = ModelContext(f.container)
        let stored = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(stored.productPhotos.map(\.id) == [remaining.id])
    }

    @Test func deletingMeasurementBeforeFirstHandoffKeepsOnlyRemainingDetail() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let detail = try f.detail()
        try await f.apply([detail], deleted: Set(f.input.measurementPhotos.map(\.id)))
        #expect(f.garment.productPhotos.map(\.id) == [detail.id])
        #expect(f.garment.thumbnail?.id == detail.id)
        #expect(f.garment.measurementPhoto != nil)
    }

    @Test func overflowHandoffRollsBackAllCopiesAndSelectionBeforeRetry() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let details = try (0..<11).map { _ in try f.detail() }
        let originalIDs = f.garment.photos.map(\.id)
        await #expect(throws: SaveFailure.self) {
            try await f.apply(details, persist: { _ in throw SaveFailure.failed })
        }
        #expect(f.garment.photos.map(\.id) == originalIDs)
        #expect(f.garment.capturePhotosAppliedAt == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 2)
        try await f.apply(details)
        #expect(f.garment.photos.count == 13 && f.garment.productPhotos.count == 10)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 13)
    }

    @Test func duplicatePhotoIDsAreRejectedBeforeAnyCopyOrMutation() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.detail(), second = try f.detail()
        let duplicate = CapturedAsset(id: first.id, sessionID: second.sessionID,
            garmentID: second.garmentID, purpose: .detail, capturedAt: second.capturedAt, source: second.source)
        let originalIDs = f.garment.photos.map(\.id)
        await #expect(throws: ProductPhotoHandoff.HandoffError.self) {
            try await f.apply([first, duplicate])
        }
        #expect(f.garment.photos.map(\.id) == originalIDs)
        #expect(f.garment.capturePhotosAppliedAt == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 2)
    }

    private enum SaveFailure: Error { case failed }
    private struct Fixture {
        let directory = URL.temporaryDirectory.appending(path: "capture-handoff-\(UUID())")
        let photos: URL
        let container: ModelContainer
        let context: ModelContext
        let garment: Garment
        let input: ProductPhotoInput
        init() throws {
            photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            container = try ModelContainer(for: ProductAppStorage.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            context = ModelContext(container)
            context.autosaveEnabled = false
            garment = Garment(category: "Shirt", group: .top)
            let original = GarmentPhoto(fileName: "original.jpg", role: .thumbnail, order: 0, isMeasurementSource: true)
            let visual = GarmentPhoto(fileName: "visual.jpg", role: .detail, order: 1)
            visual.isSelectedForProduct = false
            garment.photos = [original, visual]
            context.insert(garment)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let bytes = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format)
                .jpegData(withCompressionQuality: 0.9) { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 24)) }
            for photo in garment.photos { try bytes.write(to: photos.appending(path: photo.fileName)) }
            var prepared = try ProductPhotoHandoff.makeInput(for: garment, sessionID: UUID(), photosDirectory: photos)
            let url = photos.appending(path: visual.fileName)
            prepared.measurementVisualization = CapturedAsset(id: visual.id, sessionID: prepared.sessionID,
                garmentID: garment.id, purpose: .measurementVisualization, capturedAt: visual.capturedAt,
                source: .localFile(url, metadata: try ProductPhotoHandoff.metadata(for: url)))
            input = prepared
            try context.save()
        }
        func detail() throws -> CapturedAsset {
            let url = directory.appending(path: "\(UUID()).jpg")
            try FileManager.default.copyItem(at: photos.appending(path: "original.jpg"), to: url)
            return CapturedAsset(id: UUID(), sessionID: input.sessionID, garmentID: garment.id,
                purpose: .detail, capturedAt: .now,
                source: .localFile(url, metadata: try ProductPhotoHandoff.metadata(for: url)))
        }
        func apply(_ details: [CapturedAsset], deleted: Set<UUID> = [], persist: @MainActor (ModelContext) throws -> Void = { try $0.save() }) async throws {
            let remaining = (input.measurementPhotos + details).filter { !deleted.contains($0.id) }
            let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: garment.id,
                detailPhotos: details, selectedPhotos: remaining,
                representativePhotoID: remaining.first?.id ?? input.measurement.id, deletedPhotoIDs: deleted)
            try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: input,
                photosDirectory: photos, includesAllCapturedPhotos: true, persist: persist)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
