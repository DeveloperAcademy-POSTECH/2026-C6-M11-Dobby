import Foundation
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductPhotoImportCleanupTests {
    @Test func cancellingAnEditRemovesOnlyItsUnsavedImportsAndDerivedVariants() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let originalBytes = try Data(contentsOf: f.originalURL)
        let session = try ProductInformationEditSession(garmentID: f.garment.id, container: f.container)
        try await ProductPhotoImportStore.append(f.bytes, to: session.garment, in: session.context)
        let newPhoto = try #require(session.garment.productPhotos.first { $0.id != f.original.id })
        let imported = GarmentStore.photosDirectory.appending(path: newPhoto.fileName)
        let cleanup = ProductPhotoImportStore.uncommittedFileURLs(for: session.garment, in: session.context)
        #expect(cleanup.count == 4 && cleanup.contains(imported))
        #expect(!cleanup.contains(f.originalURL))
        // Match the immutable variant names without depending on #179 here.
        for url in cleanup where url != imported { try Data("variant".utf8).write(to: url) }
        session.discard()
        #expect(session.garment.productPhotos.count == 1 && !session.hasChanges)
        #expect(cleanup.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: f.originalURL) == originalBytes)
        #expect(Set(session.garment.photos.map(\.id)) == [f.original.id])
        #expect(session.context.insertedModelsArray.isEmpty)
        // A later save must not resurrect the rolled-back relationship/model.
        try session.context.save()
        let reader = ModelContext(f.container)
        let reopened = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(reopened.photos.count == 1 && reopened.photos.first?.id == f.original.id)
    }

    @Test func successfulPersistenceRemovesCleanupAuthorityEvenAfterPhotoIsExcluded() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let context = ModelContext(f.container); context.autosaveEnabled = false
        let garment = try #require(context.fetch(FetchDescriptor<Garment>()).first)
        try await ProductPhotoImportStore.append(f.bytes, to: garment, in: context)
        let newPhoto = try #require(garment.photos.first { $0.id != f.original.id })
        let importedURL = GarmentStore.photosDirectory.appending(path: newPhoto.fileName)
        defer { try? FileManager.default.removeItem(at: importedURL) }
        try context.save()
        #expect(ProductPhotoImportStore.uncommittedFileURLs(for: garment, in: context).isEmpty)
        #expect(try GarmentStore.removeProductPhoto(id: newPhoto.id, from: garment, in: context, persist: { _ in }))
        #expect(ProductPhotoImportStore.uncommittedFileURLs(for: garment, in: context).isEmpty)
        #expect(FileManager.default.fileExists(atPath: importedURL.path), "A saved, excluded original stays retained")
    }

    @Test func durableDraftDeletionAndUnsavedImportCleanupRemoveBothOwnersFiles() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let flowContext = ModelContext(f.container); flowContext.autosaveEnabled = false
        let garment = try #require(flowContext.fetch(FetchDescriptor<Garment>()).first)
        try await ProductPhotoImportStore.append(f.bytes, to: garment, in: flowContext)
        let imported = try #require(garment.photos.first { $0.id != f.original.id })
        let newURL = GarmentStore.photosDirectory.appending(path: imported.fileName)
        let cleanup = ProductPhotoImportStore.uncommittedFileURLs(for: garment, in: flowContext)
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        // Same ordering as the creation flow: commit the isolated deletion,
        // then release this flow's unsaved imports. Neither precedes the commit.
        #expect(try GarmentStore.deleteSavedGarment(id: garment.id, in: f.container))
        ProductPhotoImportStore.removeUncommittedFiles(cleanup)
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.originalURL.path))
        let reader = ModelContext(f.container)
        #expect(try reader.fetch(FetchDescriptor<Garment>()).isEmpty)
    }

    @Test func unreadableOrCancelledImportsDoNotAddRecordsOrLeaveProductFiles() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let previousIDs = f.garment.photos.map(\.id)
        await #expect(throws: ProductPhotoImportStore.ImportError.self) {
            try await ProductPhotoImportStore.append(Data("not an image".utf8), to: f.garment, in: f.context)
        }
        let pending = Task { try await ProductPhotoImportStore.append(f.bytes, to: f.garment, in: f.context) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(f.garment.photos.map(\.id) == previousIDs)
        #expect(ProductPhotoImportStore.uncommittedFileURLs(for: f.garment, in: f.context).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: GarmentStore.photosDirectory,
            includingPropertiesForKeys: nil)
        #expect(!files.contains { $0.lastPathComponent.hasPrefix(f.garment.id.uuidString + "-") })
        #expect(FileManager.default.fileExists(atPath: f.originalURL.path))
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let garment: Garment
        let garmentID: UUID
        let original: GarmentPhoto
        let originalURL: URL
        let bytes: Data
        init() throws {
            container = try ModelContainer(for: ProductAppStorage.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            context = ModelContext(container); context.autosaveEnabled = false
            garment = Garment(category: "Shirt", group: .top, name: "상품", detail: "설명", price: 100)
            garmentID = garment.id
            original = GarmentPhoto(fileName: "qa-import-original-\(UUID()).jpg", role: .thumbnail, order: 0)
            garment.photos = [original]
            let recordID = UUID(); garment.sourceMeasurementID = recordID
            garment.creationDraftData = try JSONEncoder().encode(ProductCreationDraft(step: .information,
                measurementRecordID: recordID, photoState: nil, measurementInputData: nil, savedAt: .now))
            context.insert(garment)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            bytes = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format)
                .jpegData(withCompressionQuality: 0.9) { renderer in
                    UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
                }
            originalURL = GarmentStore.photosDirectory.appending(path: original.fileName)
            try bytes.write(to: originalURL, options: .atomic)
            try context.save()
        }
        func removeFiles() {
            try? FileManager.default.removeItem(at: originalURL)
            guard let files = try? FileManager.default.contentsOfDirectory(at: GarmentStore.photosDirectory,
                includingPropertiesForKeys: nil) else { return }
            for url in files where url.lastPathComponent.hasPrefix(garmentID.uuidString + "-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
