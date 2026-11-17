import Foundation
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct AdditionalProductPhotoCaptureTests {
    @Test func captureOnlySessionReturnsAllNewDetailsWithoutMeasurementOrTenPhotoTruncation() async throws {
        let provider = Provider()
        let model = AdditionalProductPhotoModel(garmentID: UUID(), captureProvider: provider)
        #expect(model.allPhotosOutput == nil)
        #expect(model.measurementRecord == nil && model.hasAcknowledgedCaptureGuide)
        for _ in 0..<12 { try await model.captureDetail() }
        let output = try #require(model.allPhotosOutput)
        #expect(output.detailPhotos.count == 12 && output.selectedPhotos == output.detailPhotos)
        #expect(output.selectedPhotos.allSatisfy { $0.purpose == .detail && $0.garmentID == model.garmentID })
        #expect(output.representativePhotoID == model.detailPhotos.first?.id)
        await model.discardTemporaryPhotos()
        #expect(model.allPhotosOutput == nil && model.photos.isEmpty)
        #expect(Set(provider.discarded) == Set(output.detailPhotos.map(\.id)))
    }

    @Test func closedSessionRejectsAndDiscardsALateCaptureWithoutPublishingIt() async throws {
        let provider = Provider()
        provider.suspendsCapture = true
        let model = AdditionalProductPhotoModel(garmentID: UUID(), captureProvider: provider)
        let capture = Task { try await model.captureDetail() }
        await provider.waitForCapture()
        await model.discardTemporaryPhotos()
        provider.resumeCapture()
        await #expect(throws: CancellationError.self) { try await capture.value }
        #expect(model.photos.isEmpty && model.allPhotosOutput == nil)
        #expect(provider.discarded.count == 1)
    }

    @Test func failedGalleryDeletionKeepsNewCapturesUntilRetry() async throws {
        let provider = Provider()
        let model = AdditionalProductPhotoModel(garmentID: UUID(), captureProvider: provider)
        try await model.captureDetail()
        try await model.captureDetail()
        let ids = model.photos.map(\.id)
        provider.failsDeletion = true
        await #expect(throws: CameraFailure.saveFailed) { try await model.deletePhoto(ids[0]) }
        #expect(model.photos.map(\.id) == ids && !model.isDeleting)
        provider.failsDeletion = false
        try await model.deletePhoto(ids[0])
        #expect(model.allPhotosOutput?.detailPhotos.map(\.id) == [ids[1]])
    }

    @Test func preloadedGalleryUsesCurrentSelectionOrderRotationAndIDsBeforeCapture() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let reversedIDs = Array(f.garment.productPhotos.map(\.id).reversed())
        #expect(GarmentStore.reorderProductPhotos(ids: reversedIDs, in: f.garment))
        let rotated = try #require(f.garment.productPhotos.first)
        try await GarmentStore.rotateProductPhoto(rotated, in: f.garment)
        let previousUpdatedAt = f.garment.updatedAt
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let model = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: photos, captureProvider: Provider())
        #expect(model.photos.map(\.id) == reversedIDs)
        #expect(model.selectablePhotos == photos && model.photos.last == photos.last)
        #expect(model.allPhotosOutput?.selectedPhotos == photos)
        #expect(model.newlyCapturedPhotos.isEmpty && model.photosRequiringLibrarySave.isEmpty)
        guard case let .localFile(url, metadata) = photos[0].source else { Issue.record("Missing stored preview"); return }
        #expect(url == GarmentStore.url(for: rotated))
        #expect(metadata.pixelWidth == 32 && metadata.pixelHeight == 24)
        #expect(f.garment.updatedAt == previousUpdatedAt && f.garment.productPhotos.map(\.id) == reversedIDs)
        // A photo already excluded in the input view must not reappear on entry.
        f.garment.productPhotos.last?.isSelectedForProduct = false
        let selected = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        #expect(selected.map(\.id) == [reversedIDs[0]])
    }

    @Test func cancelPreloadedGalleryDeletionDiscardsOnlyNewCapturesAndLeavesExistingDraftUntouched() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let provider = Provider()
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let model = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: photos, captureProvider: provider)
        try await model.deletePhoto(photos[0].id)
        try await model.captureDetail()
        let newIDs = model.newlyCapturedPhotos.map(\.id)
        #expect(model.photos.map(\.id) == [photos[1].id] + newIDs)
        #expect(model.allPhotosOutput?.deletedPhotoIDs == [photos[0].id])
        #expect(provider.discarded.isEmpty, "Borrowed deletions may not reach the temporary capture provider")
        await model.discardTemporaryPhotos()
        #expect(provider.discarded == newIDs && model.photos.isEmpty)
        #expect(f.garment.productPhotos.map(\.id) == photos.map(\.id))
        #expect(f.garment.productPhotos.allSatisfy { FileManager.default.fileExists(atPath: GarmentStore.url(for: $0).path) })
        let reentered = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID),
            captureProvider: provider)
        #expect(reentered.photos == photos && reentered.photosRequiringLibrarySave.isEmpty)
        #expect(reentered.allPhotosOutput?.deletedPhotoIDs.isEmpty == true)
    }

    @Test func completionAppendsOnlyNewCapturesAndAppliesBorrowedExclusionsWithoutReorderingSurvivors() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let originalIDs = Array(f.garment.productPhotos.map(\.id).reversed())
        #expect(GarmentStore.reorderProductPhotos(ids: originalIDs, in: f.garment))
        let provider = Provider()
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let model = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: photos, captureProvider: provider)
        let capture = f.capture(at: 0)
        provider.nextCapture = capture
        try await model.captureDetail()
        try await model.deletePhoto(originalIDs[0])
        #expect(model.photos.map(\.id) == [originalIDs[1], capture.id])
        #expect(model.photosRequiringLibrarySave == [capture])
        let output = try #require(model.allPhotosOutput)
        try await ProductPhotoImportStore.applyAdditionalCapture(model.newlyCapturedPhotos,
            removing: output.deletedPhotoIDs, to: f.garment, in: f.context)
        #expect(f.garment.productPhotos.map(\.id) == [originalIDs[1], capture.id])
        #expect(f.garment.photos.count == 3 && f.garment.productPhotos.first?.role == .thumbnail)
        let excluded = try #require(f.garment.photos.first { $0.id == originalIDs[0] })
        #expect(excluded.isSelectedForProduct == false && FileManager.default.fileExists(atPath: GarmentStore.url(for: excluded).path))
        // Re-entering and pressing Next without a new capture must not copy/save
        // any existing photograph, even after a successful previous handoff.
        let reentered = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID),
            captureProvider: provider)
        #expect(reentered.photos.map(\.id) == [originalIDs[1], capture.id])
        #expect(reentered.newlyCapturedPhotos.isEmpty && reentered.photosRequiringLibrarySave.isEmpty)
        try await ProductPhotoImportStore.applyAdditionalCapture(reentered.newlyCapturedPhotos,
            removing: reentered.removedExistingPhotoIDs, to: f.garment, in: f.context)
        #expect(f.garment.photos.count == 3 && f.garment.productPhotos.map(\.id) == [originalIDs[1], capture.id])
        await model.discardTemporaryPhotos()
        #expect(provider.discarded == [capture.id])
        #expect(f.garment.photos.allSatisfy { FileManager.default.fileExists(atPath: GarmentStore.url(for: $0).path) })
    }

    @Test func existingOnlyGalleryDeletionReturnsWithoutSavingOrCopyingBorrowedPhotos() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let model = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: photos, captureProvider: Provider())
        try await model.deletePhoto(photos[0].id)
        let output = try #require(model.allPhotosOutput)
        #expect(output.selectedPhotos.map(\.id) == [photos[1].id])
        #expect(model.newlyCapturedPhotos.isEmpty && model.photosRequiringLibrarySave.isEmpty)
        try await ProductPhotoImportStore.applyAdditionalCapture(model.newlyCapturedPhotos,
            removing: output.deletedPhotoIDs, to: f.garment, in: f.context)
        #expect(f.garment.productPhotos.map(\.id) == [photos[1].id])
        #expect(f.garment.photos.count == 2 && f.importedFileNames.isEmpty)
        #expect(f.garment.photos.allSatisfy { FileManager.default.fileExists(atPath: GarmentStore.url(for: $0).path) })
    }

    @Test func originalDetailFlowStillSavesMeasurementAndEveryDetailPhoto() async throws {
        let sessionID = UUID(), garmentID = UUID()
        let measurement = CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID,
            purpose: .measurement, capturedAt: .now, source: .mockPlaceholder)
        let model = try ProductPhotoModel(input: .init(sessionID: sessionID, garmentID: garmentID,
            measurement: measurement), captureProvider: Provider())
        try await model.captureDetail()
        try await model.captureDetail()
        let capture: any DetailPhotoCaptureModeling = model
        #expect(capture.photosRequiringLibrarySave == [measurement] + model.detailPhotos)
    }

    @Test func borrowedIdentityOrFileCannotBecomeAnOwnedCaptureOrBeDeletedOnRejection() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let provider = Provider()
        let model = AdditionalProductPhotoModel(garmentID: f.garment.id, sessionID: f.captureSessionID,
            existingPhotos: photos, captureProvider: provider)
        provider.nextCapture = photos[0]
        await #expect(throws: CameraFailure.mismatchedCapture) { try await model.captureDetail() }
        provider.nextCapture = CapturedAsset(id: UUID(), sessionID: f.captureSessionID, garmentID: f.garment.id,
            purpose: .detail, capturedAt: .now, source: photos[0].source)
        await #expect(throws: CameraFailure.mismatchedCapture) { try await model.captureDetail() }
        await model.discardTemporaryPhotos()
        #expect(provider.discarded.isEmpty)
        #expect(f.garment.photos.allSatisfy { (try? Data(contentsOf: GarmentStore.url(for: $0))) == f.bytes })
    }

    @Test func failedImportDoesNotApplyStagedBorrowedDeletion() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let photos = try ProductPhotoImportStore.capturePreviewPhotos(for: f.garment, sessionID: f.captureSessionID)
        let missing = CapturedAsset(id: UUID(), sessionID: f.captureSessionID, garmentID: f.garment.id,
            purpose: .detail, capturedAt: .now,
            source: .localFile(f.folder.appending(path: "missing.jpg"), metadata: f.metadata))
        await #expect(throws: (any Error).self) {
            try await ProductPhotoImportStore.applyAdditionalCapture([missing], removing: [photos[0].id],
                to: f.garment, in: f.context)
        }
        #expect(f.garment.productPhotos.map(\.id) == photos.map(\.id))
        #expect(f.importedFileNames.isEmpty)
        #expect(f.garment.photos.allSatisfy { (try? Data(contentsOf: GarmentStore.url(for: $0))) == f.bytes })
    }

    @Test func batchAppendPreservesExistingDraftAndAllOverflowPhotosInCaptureOrder() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let existingIDs = f.garment.productPhotos.map(\.id)
        let captures = (0..<11).map { f.capture(at: $0) }
        try await ProductPhotoImportStore.appendCapturedPhotos(captures, to: f.garment, in: f.context)
        let photos = f.garment.productPhotos
        #expect(photos.count == 13)
        #expect(Array(photos.prefix(2)).map(\.id) == existingIDs)
        #expect(Array(photos.dropFirst(2)).map(\.capturedAt) == captures.map(\.capturedAt))
        #expect(f.garment.name == "기존 입력" && f.garment.detail == "작성하던 설명" && f.garment.price == 12345)
        #expect(!GarmentInformationValidation.canAttemptCompletion(f.garment))
        #expect(Set(photos.map(\.id)).count == 13)
        // Canceling the camera's temp files after the handoff cannot remove any
        // of the product copies, whose files are independently owned.
        #expect(Array(photos.dropFirst(2)).map(\.id) == captures.map(\.id))
        #expect(photos.dropFirst(2).allSatisfy { GarmentStore.url(for: $0) != f.captureURL })
        try FileManager.default.removeItem(at: f.captureURL)
        #expect(photos.allSatisfy { FileManager.default.fileExists(atPath: GarmentStore.url(for: $0).path) })
    }

    @Test func partialBatchFailureLeavesNoDraftChangesOrCopiesAndRetryAddsExactlyOnce() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let beforeIDs = f.garment.productPhotos.map(\.id)
        let source = f.capture(at: 0)
        let missing = CapturedAsset(id: UUID(), sessionID: f.captureSessionID, garmentID: f.garment.id,
            purpose: .detail, capturedAt: .now,
            source: .localFile(f.folder.appending(path: "missing.jpg"), metadata: f.metadata))
        await #expect(throws: (any Error).self) {
            try await ProductPhotoImportStore.appendCapturedPhotos([source, missing], to: f.garment, in: f.context)
        }
        #expect(f.garment.productPhotos.map(\.id) == beforeIDs)
        #expect(ProductPhotoImportStore.uncommittedFileURLs(for: f.garment, in: f.context).isEmpty)
        #expect(f.importedFileNames.isEmpty)
        try await ProductPhotoImportStore.appendCapturedPhotos([source], to: f.garment, in: f.context)
        #expect(f.garment.productPhotos.count == 3)
        #expect(Array(f.garment.productPhotos.prefix(2)).map(\.id) == beforeIDs)
        #expect(f.importedFileNames.count == 1)
        #expect(try Data(contentsOf: f.captureURL) == f.bytes)
    }

    @Test func captureIdentitySurvivesProductCopyAndCreationSessionSynchronization() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let measurementPhoto = try #require(f.garment.productPhotos.first)
        let measurement = CapturedAsset(id: measurementPhoto.id, sessionID: f.captureSessionID,
            garmentID: f.garment.id, purpose: .measurement, capturedAt: .now,
            source: .localFile(GarmentStore.url(for: measurementPhoto), metadata: f.metadata))
        let originalFlow = try ProductPhotoModel(input: .init(sessionID: f.captureSessionID,
            garmentID: f.garment.id, measurement: measurement), captureProvider: Provider())
        let captured = f.capture(at: 0)
        try await ProductPhotoImportStore.appendCapturedPhotos([captured], to: f.garment, in: f.context)
        try originalFlow.synchronizeStoredProductPhotos(f.garment.productPhotos)
        let synchronized = try #require(originalFlow.detailPhotos.first { $0.id == captured.id })
        let receipt = DetailPhotoLibraryReceipt(schemaVersion: 1, captureID: captured.id,
            captureSessionID: captured.sessionID, photoLibraryIdentifier: "fixture-only",
            savedAt: .now, visualizationRenderVersion: nil)
        #expect(receipt.matches(synchronized, visualizationRenderVersion: nil),
                "Returning through the creation camera must not save an added capture to Photos twice")
        #expect(synchronized.source != captured.source, "Product files and camera originals have distinct ownership")
        let previousIDs = f.garment.productPhotos.map(\.id)
        let originalCopy = try #require(f.garment.photos.first { $0.id == captured.id })
        let originalCopyBytes = try Data(contentsOf: GarmentStore.url(for: originalCopy))
        await #expect(throws: CameraFailure.mismatchedCapture) {
            try await ProductPhotoImportStore.appendCapturedPhotos([captured], to: f.garment, in: f.context)
        }
        #expect(f.garment.productPhotos.map(\.id) == previousIDs)
        #expect(try Data(contentsOf: GarmentStore.url(for: originalCopy)) == originalCopyBytes)
    }

    @Test func libraryEditDiscardRestoresExistingOrderAndCleansOnlyNewProductCopies() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let originalIDs = f.garment.productPhotos.map(\.id)
        let session = try ProductInformationEditSession(garmentID: f.garment.id, container: f.container)
        session.garment.name = "수정하던 이름"
        try await ProductPhotoImportStore.appendCapturedPhotos([f.capture(at: 0), f.capture(at: 1)],
            to: session.garment, in: session.context)
        let copies = ProductPhotoImportStore.uncommittedFileURLs(for: session.garment, in: session.context)
        #expect(session.garment.productPhotos.count == 4 && session.hasChanges)
        session.discard()
        #expect(session.garment.productPhotos.map(\.id) == originalIDs)
        #expect(session.garment.name == "기존 입력" && !session.hasChanges)
        #expect(copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: f.captureURL.path))
        #expect(f.garment.productPhotos.allSatisfy { FileManager.default.fileExists(atPath: GarmentStore.url(for: $0).path) })
    }

    private final class Provider: CaptureProviding {
        var discarded: [UUID] = []
        var failsDeletion = false
        var suspendsCapture = false
        var nextCapture: CapturedAsset?
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
            if suspendsCapture {
                await withCheckedContinuation { continuation in
                    pending = continuation; started?.resume(); started = nil
                }
            }
            if let nextCapture { self.nextCapture = nil; return nextCapture }
            return CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID,
                purpose: .detail, capturedAt: .now, source: .mockPlaceholder)
        }
        func discardUncommitted(_ asset: CapturedAsset) async throws {
            if failsDeletion { throw CameraFailure.saveFailed }
            discarded.append(asset.id)
        }
        func waitForCapture() async {
            if pending == nil { await withCheckedContinuation { started = $0 } }
        }
        func resumeCapture() { pending?.resume(); pending = nil }
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let garment: Garment
        let folder: URL
        let captureURL: URL
        let captureSessionID = UUID()
        let bytes: Data
        let metadata = CapturedAsset.ImageMetadata(pixelWidth: 24, pixelHeight: 32,
            contentType: "public.jpeg", orientation: .up)
        init() throws {
            container = try ModelContainer(for: ProductAppStorage.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            context = ModelContext(container); context.autosaveEnabled = false
            garment = Garment(category: "Shirt", group: .top, name: "기존 입력", detail: "작성하던 설명", price: 12345)
            folder = URL.temporaryDirectory.appending(path: "additional-photo-tests-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            captureURL = folder.appending(path: "capture.jpg")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            bytes = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32), format: format)
                .jpegData(withCompressionQuality: 0.9) { renderer in
                    UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
                }
            try bytes.write(to: captureURL)
            garment.photos = (0..<2).map { index in
                GarmentPhoto(fileName: "qa-existing-\(UUID()).jpg", role: index == 0 ? .thumbnail : .detail, order: index)
            }
            context.insert(garment)
            for photo in garment.photos { try bytes.write(to: GarmentStore.url(for: photo)) }
            try context.save()
        }
        func capture(at index: Int) -> CapturedAsset {
            CapturedAsset(id: UUID(), sessionID: captureSessionID, garmentID: garment.id, purpose: .detail,
                capturedAt: Date(timeIntervalSince1970: Double(index)), source: .localFile(captureURL, metadata: metadata))
        }
        var importedFileNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: GarmentStore.photosDirectory.path)) ?? [])
                .filter { $0.hasPrefix(garment.id.uuidString + "-") }
        }
        func removeFiles() {
            for photo in garment.photos {
                for url in GarmentStore.retainedPhotoURLs(for: photo) { try? FileManager.default.removeItem(at: url) }
            }
            for name in importedFileNames {
                try? FileManager.default.removeItem(at: GarmentStore.photosDirectory.appending(path: name))
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
