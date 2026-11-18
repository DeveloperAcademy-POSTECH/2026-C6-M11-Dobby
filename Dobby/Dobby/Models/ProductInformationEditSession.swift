// Created by mason on 10/30/26.

import Foundation
import Observation
import SwiftData

/// 보관함 편집은 별도 컨텍스트에서 진행하며 완료 버튼만 저장할 수 있습니다.
@MainActor @Observable
final class ProductInformationEditSession {
    let context: ModelContext
    let garment: Garment
    var measurementInput = GarmentMeasurementInputState()
    private let initialSnapshot: ProductInformationEditSnapshot
    private let initialPhotos: [GarmentPhoto]
    private let autofill: ProductAutofillSession
    private let photosDirectory: URL

    init(garmentID: UUID, container: ModelContainer,
         generator: (any ProductAutofillGenerating)? = nil, photosDirectory: URL? = nil) throws {
        autofill = ProductAutofillSession(generator: generator, diagnosticOrigin: "libraryEdit")
        self.photosDirectory = photosDirectory ?? GarmentStore.photosDirectory
        context = ModelContext(container)
        context.autosaveEnabled = false
        var request = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == garmentID })
        request.fetchLimit = 1
        guard let garment = try context.fetch(request).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.garment = garment
        initialPhotos = garment.photos
        initialSnapshot = ProductInformationEditSnapshot(
            garment: garment, measurementInput: GarmentMeasurementInputState()
        )
    }

    var hasChanges: Bool {
        initialSnapshot.hasChanges(in: garment, measurementInput: measurementInput)
    }

    /// Generate against the current editing draft. Only Done persists these changes.
    func generateInformation() async throws {
        let before = ProductAutofillInputSnapshot(garment: garment)
        let photos = garment.productPhotos
        guard !photos.isEmpty else { throw ProductAutofillError.invalidPhotos }
        let sessionID = UUID()
        let uploadLimit = ProductAutofillPhotoEncoder.maximumPhotoCount
        let assets = try photos.prefix(uploadLimit).map { photo in
            let url = photosDirectory.appending(path: photo.fileName)
            return CapturedAsset(id: photo.id, sessionID: sessionID, garmentID: garment.id,
                purpose: .detail, capturedAt: photo.capturedAt,
                source: .localFile(url, metadata: try ProductPhotoHandoff.metadata(for: url)))
        }
        let photoState = ProductInformationEditSnapshot(garment: garment, measurementInput: measurementInput)
        let otherPhotos = photos.dropFirst(uploadLimit).map { photosDirectory.appending(path: $0.fileName) }
        let draft = try await autofill.generate(photos: assets, additionalPhotoURLs: otherPhotos)
        try Task.checkCancellation()
        guard !photoState.hasChanges(in: garment, measurementInput: measurementInput) else {
            throw ProductAutofillCompletionFailure.changedInformation
        }
        try before.apply(draft, to: garment)
    }

    func cancelGeneration() { autofill.cancel() }

    func discard() {
        cancelGeneration()
        let uncommittedFiles = ProductPhotoImportStore.uncommittedFileURLs(for: garment, in: context)
        context.rollback()
        // SwiftData removes inserted models on rollback but can leave their
        // inverse relationship cached on this loaded garment. Reattach exactly
        // the original models from this same context; never delete a rolled-
        // back object or a pre-existing measurement/photo to repair the cache.
        garment.photos = initialPhotos
        ProductPhotoImportStore.removeUncommittedFiles(uncommittedFiles)
        // Rollback can leave optional binary metadata stale on the loaded object.
        // Restore the same initial snapshot used by change detection before reusing it.
        initialSnapshot.restore(garment, measurementInput: &measurementInput)
    }

    /// InfoInputView의 저장 성공 이후, 기존 상세·목록에서 관찰 중인 객체도 갱신합니다.
    func reflectSavedChanges(in original: Garment) {
        // Resolve newly added photos in the observing context; never attach
        // managed models from the editing context to the library context.
        if let originalContext = original.modelContext {
            original.photos = garment.photos.compactMap {
                originalContext.model(for: $0.persistentModelID) as? GarmentPhoto
            }
        }
        var input = GarmentMeasurementInputState()
        ProductInformationEditSnapshot(garment: garment, measurementInput: measurementInput)
            .restore(original, measurementInput: &input)
        original.informationCompletedAt = garment.informationCompletedAt
        original.creationDraftData = garment.creationDraftData
    }
}
