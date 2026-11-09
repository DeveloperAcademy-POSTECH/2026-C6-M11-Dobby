// Created by mason on 11/8/26.
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductCapturePersistenceTests {
    @Test func allPhotosPersistInCaptureOrderWithoutSelectionLimitOrDuplicateCopies() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let details = try (0..<11).map { _ in try f.detail() }
        try await f.apply(details)
        let expected = f.input.measurementPhotos.map(\.id) + details.map(\.id)
        #expect(f.garment.productPhotos.map(\.id) == expected)
        #expect(f.garment.thumbnail?.id == f.input.measurement.id)
        let firstAppliedAt = try #require(f.garment.capturePhotosAppliedAt)
        try await f.apply(details)
        #expect(f.garment.photos.count == 13)
        #expect(f.garment.capturePhotosAppliedAt == firstAppliedAt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.photos.path).count == 13)
        let reader = ModelContext(f.container)
        let stored = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(stored.productPhotos.map(\.id) == expected)
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
        func apply(_ details: [CapturedAsset], persist: @MainActor (ModelContext) throws -> Void = { try $0.save() }) async throws {
            let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: garment.id,
                detailPhotos: details, selectedPhotos: input.measurementPhotos + details, representativePhotoID: input.measurement.id)
            try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: input,
                photosDirectory: photos, includesAllCapturedPhotos: true, persist: persist)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
