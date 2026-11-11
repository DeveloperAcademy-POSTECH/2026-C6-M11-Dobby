import Foundation
import ImageIO
import SwiftData

@MainActor
enum ProductPhotoImportStore {
    /// Writes only a new product copy. Album originals and measurement evidence
    /// remain untouched, and the caller's isolated edit context owns persistence.
    static func append(_ data: Data, to garment: Garment, in context: ModelContext) async throws {
        guard garment.modelContext === context,
              garment.productPhotos.count < ProductPhotoModel.maximumSelectionCount else { throw ImportError.limitReached }
        let id = UUID()
        let fileName = "\(garment.id.uuidString)-\(id.uuidString).jpg"
        let destination = GarmentStore.photosDirectory.appending(path: fileName)
        let dimensions = try await Task.detached(priority: .userInitiated) {
            try writeJPEG(data, to: destination)
        }.value
        do {
            try Task.checkCancellation()
            guard garment.modelContext === context,
                  garment.productPhotos.count < ProductPhotoModel.maximumSelectionCount else { throw ImportError.limitReached }
            let wasEmpty = garment.productPhotos.isEmpty
            let photo = GarmentPhoto(fileName: fileName, role: wasEmpty ? .thumbnail : .detail,
                                     order: (garment.photos.map(\.order).max() ?? -1) + 1)
            photo.id = id
            photo.imageWidth = dimensions.width
            photo.imageHeight = dimensions.height
            photo.isSelectedForProduct = true
            context.insert(photo)
            garment.photos.append(photo)
            garment.updatedAt = .now
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Only unsaved models owned by this context and this importer's exact
    /// generated filename grant cleanup authority. Saved/retained photos never do.
    static func uncommittedFileURLs(for garment: Garment, in context: ModelContext) -> [URL] {
        let relatedIDs = Set(garment.photos.map(\.id))
        return context.insertedModelsArray.compactMap { $0 as? GarmentPhoto }
            .filter { photo in
                relatedIDs.contains(photo.id) && !photo.isMeasurementSource
                    && photo.fileName == "\(garment.id.uuidString)-\(photo.id.uuidString).jpg"
            }.flatMap { photo -> [URL] in
                let original = GarmentStore.photosDirectory.appending(path: photo.fileName)
                // Immutable rotation variants use this same store-owned stem.
                return [original] + (1...3).map {
                    original.deletingPathExtension().appendingPathExtension("product-rotation-\($0).jpg")
                }
            }
    }

    nonisolated static func removeUncommittedFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private nonisolated static func writeJPEG(_ data: Data, to destination: URL) throws -> (width: Int, height: Int) {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ImportError.unreadablePhoto }
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else {
                throw ImportError.unreadablePhoto
            }
            // Product copies contain no location or other album metadata.
            CGImageDestinationAddImage(encoder, image, [kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw ImportError.unreadablePhoto }
            try Task.checkCancellation()
            try (bytes as Data).write(to: destination, options: .atomic)
            return (image.width, image.height)
        }
    }

    nonisolated enum ImportError: LocalizedError {
        case unreadablePhoto, limitReached
        var errorDescription: String? {
            switch self {
            case .unreadablePhoto: "사진을 읽을 수 없어요. 다른 사진을 선택해 주세요."
            case .limitReached: "제품 사진은 최대 10장까지 등록할 수 있어요."
            }
        }
    }
}
