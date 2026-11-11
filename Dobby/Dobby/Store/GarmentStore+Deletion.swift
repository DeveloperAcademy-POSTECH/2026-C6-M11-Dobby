import Foundation
import SwiftData

extension GarmentStore {
    /// Commits only this saved product's deletion, then removes its photo files.
    /// The caller's pending edits and the separate measurement archive stay intact.
    @MainActor
    @discardableResult
    static func deleteSavedGarment(id: UUID, in container: ModelContainer) throws -> Bool {
        let deletionContext = ModelContext(container)
        deletionContext.autosaveEnabled = false
        var descriptor = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let garment = try deletionContext.fetch(descriptor).first else { return false }

        // Capture every file before cascading deletion invalidates the graph,
        // including original measurement photos excluded from product photos.
        let photoURLs = garment.photos.flatMap { retainedPhotoURLs(for: $0) }
            + ProductDraftStore.retainedCameraPhotoURLs(in: garment.creationDraft, garmentID: garment.id)
        deletionContext.delete(garment)
        do {
            try deletionContext.save()
        } catch {
            deletionContext.rollback()
            throw error
        }

        // A cleanup failure may leave an orphan file; it must not undo or
        // misreport a product deletion that has already been committed.
        for photoURL in photoURLs {
            try? FileManager.default.removeItem(at: photoURL)
        }
        return true
    }
}
