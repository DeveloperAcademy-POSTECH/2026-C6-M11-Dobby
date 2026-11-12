// Created by mason on 10/30/26.
import Foundation
import SwiftData

/// Replaces confirmed evidence, never runs measurement or model inference.
@MainActor
enum ProductMeasurementRetake {
    struct Replacement {
        let context: ModelContext
        let garment: Garment
        let photoModel: ProductPhotoModel
    }

    static func replace(_ record: SavedMeasurement, garment: Garment, photoModel: ProductPhotoModel,
                        previousInputData: Data, replacementInputData: Data, step: ProductDraftStep,
                        in context: ModelContext, directory: URL? = nil,
                        allowsSynthetic: Bool = false, allowsUnavailableDraft: Bool = false,
                        persist: (ModelContext) throws -> Void = { try $0.save() }) async throws -> Replacement {
        let directory = directory ?? GarmentStore.photosDirectory
        guard garment.modelContext === context, garment.informationCompletedAt == nil,
              let previousRecordID = garment.sourceMeasurementID,
              previousRecordID != record.id,
              let original = garment.measurementPhoto,
              original.id == photoModel.input.measurement.id,
              garment.id == photoModel.input.garmentID,
              original.measurementSessionID == photoModel.input.sessionID else {
            throw CameraFailure.mismatchedCapture
        }
        // Checkpoint live edits, then stage in an isolated context. SwiftData
        // rollback alone does not reliably refresh already-held model objects.
        try ProductDraftStore.save(garment: garment, step: garment.creationDraft?.step ?? .measurementResult,
            measurementRecordID: previousRecordID, photoModel: photoModel,
            measurementInputData: previousInputData, in: context)
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        let productID = garment.id
        guard let pending = try transaction.fetch(FetchDescriptor<Garment>(
            predicate: #Predicate { $0.id == productID })).first else { throw CameraFailure.missingCapture }
        let oldOriginalURL = directory.appending(path: original.fileName)
        let oldVisualization = photoModel.input.measurementVisualization.flatMap { asset in
            pending.photos.first { $0.id == asset.id }
        }
        let oldVisualURL = oldVisualization.map { directory.appending(path: $0.fileName) }
        let visualID = MeasurementProductPhoto.identifier(garmentID: garment.id, recordID: record.id)
        let newVisualURL = directory.appending(path:
            MeasurementProductPhoto.fileName(garmentID: garment.id, recordID: record.id))
        let visualExisted = FileManager.default.fileExists(atPath: newVisualURL.path)
        var newOriginalURL: URL?
        do {
            newOriginalURL = try GarmentStore.stageRetakenMeasurement(record, for: pending, in: transaction,
                photosDirectory: directory, allowsSynthetic: allowsSynthetic,
                allowsUnavailableDraft: allowsUnavailableDraft)
            var input = try ProductPhotoHandoff.makeInput(for: pending,
                sessionID: record.snapshot.frame.sessionID, photosDirectory: directory)
            input.measurementVisualization = try await MeasurementProductPhoto.prepare(record: record,
                garment: pending, in: transaction, directory: directory, persist: { _ in })
            let candidate = try photoModel.replacingMeasurement(with: input, record: record)
            if let oldVisualization, oldVisualization.id != visualID {
                if let newPhoto = pending.photos.first(where: { $0.id == visualID }) {
                    newPhoto.role = oldVisualization.role
                    newPhoto.order = oldVisualization.order
                    newPhoto.isSelectedForProduct = oldVisualization.isSelectedForProduct
                }
                pending.photos.removeAll { $0.id == oldVisualization.id }
                transaction.delete(oldVisualization)
            }
            try Task.checkCancellation()
            try ProductDraftStore.save(garment: pending, step: step, measurementRecordID: record.id,
                photoModel: candidate, measurementInputData: replacementInputData, in: transaction, persist: persist)
            // The old files remain readable until both new evidence and the
            // retained photo selection have been saved in one transaction.
            try? FileManager.default.removeItem(at: oldOriginalURL)
            if let oldVisualURL, oldVisualURL != newVisualURL { try? FileManager.default.removeItem(at: oldVisualURL) }
            return Replacement(context: transaction, garment: pending, photoModel: candidate)
        } catch {
            transaction.rollback()
            if let newOriginalURL { try? FileManager.default.removeItem(at: newOriginalURL) }
            if !visualExisted { try? FileManager.default.removeItem(at: newVisualURL) }
            throw error
        }
    }
}
