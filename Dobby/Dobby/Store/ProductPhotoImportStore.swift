import Foundation
import ImageIO
import SwiftData

@MainActor
enum ProductPhotoImportStore {
    /// Detail capture returns every new photo, including overflow. Prepare all
    /// product copies before touching SwiftData so an import failure/retry can
    /// never append the first few captures twice or change existing photo order.
    /// Album selection uses the single-photo import path below.
    static func appendCapturedPhotos(_ photos: [CapturedAsset], to garment: Garment,
                                     in context: ModelContext) async throws {
        try Task.checkCancellation()
        guard garment.modelContext === context,
              !photos.isEmpty, Set(photos.map(\.id)).count == photos.count,
              Set(photos.map(\.id)).isDisjoint(with: garment.photos.map(\.id)),
              Set(photos.map(\.sessionID)).count == 1,
              photos.allSatisfy({ $0.garmentID == garment.id && $0.purpose == .detail }) else {
            throw CameraFailure.mismatchedCapture
        }
        let garmentID = garment.id
        let directory = GarmentStore.photosDirectory
        let copies = try await Task.detached(priority: .userInitiated) {
            var prepared: [CapturedProductPhotoCopy] = []
            do {
                for photo in photos {
                    try Task.checkCancellation()
                    guard case let .localFile(source, _) = photo.source, source.isFileURL else {
                        throw ImportError.unreadablePhoto
                    }
                    // Preserve capture identity for the existing Photos saving
                    // receipt when the creation flow revisits detail capture.
                    // The file is still a separate product-owned JPEG copy.
                    let id = photo.id
                    let destination = directory.appending(path: "\(garmentID.uuidString)-\(id.uuidString).jpg")
                    let size = try autoreleasepool {
                        try writeJPEG(Data(contentsOf: source), to: destination)
                    }
                    prepared.append(CapturedProductPhotoCopy(id: id, destination: destination,
                        width: size.width, height: size.height, capturedAt: photo.capturedAt))
                }
                return prepared
            } catch {
                removeUncommittedFiles(prepared.map(\.destination))
                throw error
            }
        }.value
        do {
            try Task.checkCancellation()
            guard garment.modelContext === context else { throw CameraFailure.mismatchedCapture }
            var nextOrder = (garment.photos.map(\.order).max() ?? -1) + 1
            var isFirst = garment.productPhotos.isEmpty
            // No suspension between inserting copies: the parent draft observes
            // one complete batch and its own Done validation applies <=10.
            for copy in copies {
                let photo = GarmentPhoto(fileName: copy.destination.lastPathComponent,
                    role: isFirst ? .thumbnail : .detail, order: nextOrder)
                photo.id = copy.id
                photo.imageWidth = copy.width
                photo.imageHeight = copy.height
                photo.capturedAt = copy.capturedAt
                photo.isSelectedForProduct = true
                context.insert(photo)
                garment.photos.append(photo)
                nextOrder += 1
                isFirst = false
            }
            garment.updatedAt = .now
        } catch {
            removeUncommittedFiles(copies.map(\.destination))
            throw error
        }
    }

    /// Writes only a new product copy. Album originals and measurement evidence
    /// remain untouched, and the caller's isolated edit context owns persistence.
    static func append(_ data: Data, to garment: Garment, in context: ModelContext) async throws {
        guard garment.modelContext === context else { throw ImportError.detachedGarment }
        let id = UUID()
        let fileName = "\(garment.id.uuidString)-\(id.uuidString).jpg"
        let destination = GarmentStore.photosDirectory.appending(path: fileName)
        let dimensions = try await Task.detached(priority: .userInitiated) {
            try writeJPEG(data, to: destination)
        }.value
        do {
            try Task.checkCancellation()
            guard garment.modelContext === context else { throw ImportError.detachedGarment }
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
        case unreadablePhoto, detachedGarment
        var errorDescription: String? {
            switch self {
            case .unreadablePhoto: "사진을 읽을 수 없어요. 다른 사진을 선택해 주세요."
            case .detachedGarment: "제품 정보를 확인할 수 없어요. 다시 시도해 주세요."
            }
        }
    }
}

private nonisolated struct CapturedProductPhotoCopy: Sendable {
    let id: UUID
    let destination: URL
    let width: Int
    let height: Int
    let capturedAt: Date
}
