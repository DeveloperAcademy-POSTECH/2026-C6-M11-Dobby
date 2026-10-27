import Foundation
import SwiftData

extension GarmentStore {
    /// Removes a product photo from display/export while retaining the original
    /// file and measurement evidence. Restore only these edits if saving fails.
    @MainActor
    @discardableResult
    static func removeProductPhoto(id: UUID, from garment: Garment, in context: ModelContext,
                                   persist: @MainActor (ModelContext) throws -> Void = { try $0.save() }) throws -> Bool {
        guard let photo = garment.productPhotos.first(where: { $0.id == id }) else { return false }
        let previous = garment.photos.map { ($0, $0.isSelectedForProduct, $0.roleRaw) }
        let previousUpdatedAt = garment.updatedAt

        photo.isSelectedForProduct = false
        for existing in garment.photos where existing.role == .thumbnail {
            existing.role = .detail
        }
        garment.productPhotos.first?.role = .thumbnail
        garment.updatedAt = .now

        do {
            try persist(context)
        } catch {
            for (photo, selected, role) in previous {
                photo.isSelectedForProduct = selected
                photo.roleRaw = role
            }
            garment.updatedAt = previousUpdatedAt
            throw error
        }
        return true
    }
}
