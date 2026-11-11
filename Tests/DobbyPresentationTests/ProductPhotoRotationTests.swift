import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductPhotoRotationTests {
    @Test func fourRotationsReturnToOriginalWithoutChangingMeasurementEvidence() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let sourceBytes = try Data(contentsOf: f.originalURL)
        let originalDimensions = (f.photo.imageWidth, f.photo.imageHeight)
        let frame = f.photo.measurementFrameID
        let record = f.photo.measurementRecordID
        let landmark = LandmarkPoint(name: "neck", index: 0, x: 0.25, y: 0.125)
        f.photo.landmarks = [landmark]
        for turn in 1...4 {
            try await GarmentStore.rotateProductPhoto(f.photo, in: f.garment)
            #expect((f.photo.productRotationQuarterTurns ?? 0) == turn % 4)
            let url = GarmentStore.url(for: f.photo)
            let metadata = try ProductPhotoHandoff.metadata(for: url)
            #expect(metadata.pixelWidth == (turn % 2 == 0 ? 128 : 64))
            #expect(metadata.pixelHeight == (turn % 2 == 0 ? 64 : 128))
            #expect(try Data(contentsOf: f.originalURL) == sourceBytes)
            #expect(f.photo.fileName == f.originalURL.lastPathComponent)
            #expect(f.photo.imageWidth == originalDimensions.0 && f.photo.imageHeight == originalDimensions.1)
            #expect(f.photo.measurementFrameID == frame && f.photo.measurementRecordID == record)
            #expect(landmark.x == 0.25 && landmark.y == 0.125)
        }
        #expect(f.photo.productRotationQuarterTurns == nil)
        #expect(GarmentStore.url(for: f.photo) == f.originalURL)
    }

    @Test func snapshotRestoresRotationAndSuccessfulSaveSurvivesContextReopen() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        var input = GarmentMeasurementInputState()
        let before = ProductInformationEditSnapshot(garment: f.garment, measurementInput: input)
        try await GarmentStore.rotateProductPhoto(f.photo, in: f.garment)
        #expect(before.hasChanges(in: f.garment, measurementInput: input))
        let rotatedURL = GarmentStore.url(for: f.photo)
        before.restore(f.garment, measurementInput: &input)
        #expect(!before.hasChanges(in: f.garment, measurementInput: input))
        #expect(GarmentStore.url(for: f.photo) == f.originalURL)
        #expect(FileManager.default.fileExists(atPath: rotatedURL.path), "An immutable variant remains available for rollback/retry")
        try await GarmentStore.rotateProductPhoto(f.photo, in: f.garment)
        try f.context.save()
        let reader = ModelContext(f.container)
        let saved = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        let photo = try #require(saved.productPhotos.first)
        #expect(photo.productRotationQuarterTurns == 1)
        #expect(GarmentStore.url(for: photo) == rotatedURL)
    }

    @Test func failedProductSaveKeepsRotationForRetryAndDiscardRestoresStoredProduct() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let session = try ProductInformationEditSession(garmentID: f.garment.id, container: f.container)
        let editingPhoto = try #require(session.garment.productPhotos.first)
        try await GarmentStore.rotateProductPhoto(editingPhoto, in: session.garment)
        #expect(session.hasChanges)
        #expect(throws: CocoaError.self) {
            try GarmentInputCompletion.save(garment: session.garment, drafts: &session.measurementInput.drafts) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #expect(editingPhoto.productRotationQuarterTurns == 1 && session.hasChanges)
        let reader = ModelContext(f.container)
        let saved = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(saved.productPhotos.first?.productRotationQuarterTurns == nil)
        session.discard()
        #expect(!session.hasChanges)
        #expect(session.garment.productPhotos.first?.productRotationQuarterTurns == nil)
        #expect(FileManager.default.fileExists(atPath: f.originalURL.path))
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let garment: Garment
        let photo: GarmentPhoto
        let originalURL: URL
        init() throws {
            container = try ModelContainer(for: ProductAppStorage.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            context = ModelContext(container)
            context.autosaveEnabled = false
            garment = Garment(category: "Jacket", group: .top, name: "회전 테스트", detail: "설명", price: 40000)
            photo = GarmentPhoto(fileName: "qa-rotation-\(UUID()).jpg", role: .thumbnail, order: 0, isMeasurementSource: true)
            photo.imageWidth = 128; photo.imageHeight = 64
            photo.measurementFrameID = UUID(); photo.measurementRecordID = UUID()
            garment.photos = [photo]
            context.insert(garment)
            originalURL = GarmentStore.photosDirectory.appending(path: photo.fileName)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let bytes = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 64), format: format)
                .jpegData(withCompressionQuality: 0.95) { renderer in
                    UIColor.red.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                    UIColor.blue.setFill(); renderer.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
                }
            try bytes.write(to: originalURL, options: .atomic)
            try context.save()
        }
        func removeFiles() {
            for url in GarmentStore.retainedPhotoURLs(for: photo) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
