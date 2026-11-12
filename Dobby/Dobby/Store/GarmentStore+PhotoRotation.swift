import Foundation
import CoreGraphics
import ImageIO

extension GarmentStore {
    /// The original is immutable: rotation creates a product-only JPEG. Keeping
    /// the three immutable variants also lets an unsaved edit roll back safely.
    @MainActor
    static func rotateProductPhoto(_ photo: GarmentPhoto, in garment: Garment) async throws {
        guard garment.productPhotos.contains(where: { $0.id == photo.id }) else {
            throw StoreError.encodingFailed
        }
        let previous = photo.productRotationQuarterTurns ?? 0
        let next = (previous + 1) % 4
        let original = photosDirectory.appending(path: photo.fileName)
        let destination = productPhotoURL(fileName: photo.fileName, quarterTurns: next)
        if next != 0 {
            try await Task.detached(priority: .userInitiated) {
                try writeProductRotation(original: original, destination: destination, quarterTurns: next)
            }.value
        }
        try Task.checkCancellation()
        guard garment.productPhotos.contains(where: { $0.id == photo.id }),
              (photo.productRotationQuarterTurns ?? 0) == previous else {
            throw CancellationError()
        }
        photo.productRotationQuarterTurns = next == 0 ? nil : next
        garment.updatedAt = .now
    }

    @MainActor
    static func productPhotoURL(fileName: String, quarterTurns: Int) -> URL {
        let original = photosDirectory.appending(path: fileName)
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return original }
        return original.deletingPathExtension().appendingPathExtension("product-rotation-\(turns).jpg")
    }

    @MainActor
    static func retainedPhotoURLs(for photo: GarmentPhoto) -> [URL] {
        (0..<4).map { productPhotoURL(fileName: photo.fileName, quarterTurns: $0) }
    }

    nonisolated static func writeProductRotation(original: URL, destination: URL,
                                                         quarterTurns: Int) throws {
        // A given variant is always generated from the same original, so it
        // never accumulates lossy rotations or invalidates an earlier edit.
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(original as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw StoreError.encodingFailed }
            let swapsAxes = quarterTurns % 2 == 1
            let outputWidth = swapsAxes ? image.height : image.width
            let outputHeight = swapsAxes ? image.width : image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw StoreError.encodingFailed }
            switch quarterTurns {
            case 1:
                context.translateBy(x: 0, y: CGFloat(outputHeight)); context.rotate(by: -.pi / 2)
            case 2:
                context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight)); context.rotate(by: .pi)
            case 3:
                context.translateBy(x: CGFloat(outputWidth), y: 0); context.rotate(by: .pi / 2)
            default: break
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let rotated = context.makeImage() else { throw StoreError.encodingFailed }
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else {
                throw StoreError.encodingFailed
            }
            CGImageDestinationAddImage(encoder, rotated, [kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw StoreError.encodingFailed }
            try Task.checkCancellation()
            try (bytes as Data).write(to: destination, options: .atomic)
        }
    }
}
