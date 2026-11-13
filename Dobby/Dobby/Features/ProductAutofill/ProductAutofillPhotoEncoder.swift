import CoreGraphics
import Foundation
import ImageIO

/// Makes separate upload copies. Camera originals and their metadata are never rewritten.
nonisolated enum ProductAutofillPhotoEncoder {
    static let maximumPhotoCount = 5
    static let maximumPhotoBytes = 2 * 1024 * 1024
    static let maximumTotalBytes = 8 * 1024 * 1024

    struct Photo: Encodable, Sendable {
        let id: String
        let role: String
        let imageDataUrl: String
    }

    static func encode(_ photos: [CapturedAsset], totalBudget: Int = maximumTotalBytes) throws -> [Photo] {
        let selected = Array(photos.prefix(maximumPhotoCount))
        guard totalBudget > 0, totalBudget <= maximumTotalBytes, let first = selected.first,
              selected.allSatisfy({ $0.garmentID == first.garmentID && $0.sessionID == first.sessionID }),
              Set(selected.map(\.id)).count == selected.count else {
            throw ProductAutofillError.invalidPhotos
        }
        // A per-image share guarantees the aggregate limit even for five noisy photos.
        let budget = min(maximumPhotoBytes, totalBudget / selected.count)
        return try selected.map { photo in
            try Task.checkCancellation()
            guard case let .localFile(url, _) = photo.source, url.isFileURL else {
                throw ProductAutofillError.unreadablePhoto
            }
            let data = try jpeg(at: url, maximumBytes: budget)
            return Photo(id: photo.id.uuidString, role: "detail",
                         imageDataUrl: "data:image/jpeg;base64," + data.base64EncodedString())
        }
    }

    private static func jpeg(at url: URL, maximumBytes: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ProductAutofillError.unreadablePhoto
        }
        // ImageIO applies all eight EXIF orientations, including mirrored captures,
        // while decoding a thumbnail instead of the full camera image.
        for dimension in [2048, 1536, 1024, 768] {
            try Task.checkCancellation()
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary),
            let image = opaqueSRGBImage(thumbnail) else {
                throw ProductAutofillError.unreadablePhoto
            }
            for quality in [0.8, 0.65, 0.5, 0.35] {
                try Task.checkCancellation()
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
                    throw ProductAutofillError.unreadablePhoto
                }
                // Do not copy EXIF, GPS, filenames, or embedded camera thumbnails.
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyOrientation: 1,
                    kCGImageDestinationLossyCompressionQuality: quality
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ProductAutofillError.unreadablePhoto
                }
                if data.length <= maximumBytes { return data as Data }
            }
        }
        throw ProductAutofillError.photoTooLarge
    }

    private static func opaqueSRGBImage(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
