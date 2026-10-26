import CoreGraphics
import Foundation
import ImageIO

/// A view resolves its SwiftData-backed photo into these immutable values on
/// the UI actor. Neither a managed model nor its context enters the decoder.
nonisolated struct ProductThumbnailRequest: Hashable, Sendable {
    let url: URL
    let maximumPixelSize: Int
}

/// CGImage is immutable; only this privately decoded raster crosses from the
/// serial decoder actor to the UI. No mutable ImageIO source is shared.
nonisolated final class ProductThumbnail: @unchecked Sendable {
    let image: CGImage

    init(image: CGImage) { self.image = image }

    var byteCost: Int { image.bytesPerRow * image.height }
}

/// File I/O and decoding run on this actor, never inside a SwiftUI view task's
/// UI executor. A single serial decode also bounds physical workers to one.
/// Queued equal requests reuse the first result rather than decoding it again.
actor ProductThumbnailLoader {
    static let shared = ProductThumbnailLoader()
    nonisolated static let maximumDecodedDimension = 4096

    private let cache = NSCache<NSString, ProductThumbnail>()
    private let maximumCachedBytes: Int
    private let maximumCachedImages: Int
    private let decoder: @Sendable (URL, Int) -> ProductThumbnail?
    // NSCache may evict early. These upper bounds deliberately overcount such
    // evictions; clearing before an insertion keeps the hard budgets bounded.
    private var insertedByteCost = 0
    private var insertedImageCount = 0

    init(maximumCachedBytes: Int = 32 * 1024 * 1024, maximumCachedImages: Int = 64,
         decoder: (@Sendable (URL, Int) -> ProductThumbnail?)? = nil) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.maximumCachedImages = max(0, maximumCachedImages)
        self.decoder = decoder ?? Self.decode
        cache.totalCostLimit = max(0, maximumCachedBytes)
        cache.countLimit = max(0, maximumCachedImages)
    }

    func image(for request: ProductThumbnailRequest) -> ProductThumbnail? {
        guard !Task.isCancelled, request.url.isFileURL, request.maximumPixelSize > 0 else { return nil }
        let url = request.url.standardizedFileURL
        let size = min(Self.maximumDecodedDimension, request.maximumPixelSize)
        let key = "\(url.absoluteString)|\(size)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let thumbnail = decoder(url, size), !Task.isCancelled else { return nil }

        let cost = thumbnail.byteCost
        if maximumCachedBytes > 0, maximumCachedImages > 0,
           cost > 0, cost <= maximumCachedBytes {
            if insertedByteCost > maximumCachedBytes - cost || insertedImageCount >= maximumCachedImages {
                cache.removeAllObjects()
                insertedByteCost = 0
                insertedImageCount = 0
            }
            cache.setObject(thumbnail, forKey: key, cost: cost)
            insertedByteCost += cost
            insertedImageCount += 1
        }
        return thumbnail
    }

    private nonisolated static func decode(_ url: URL, maximumPixelSize: Int) -> ProductThumbnail? {
        autoreleasepool {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return ProductThumbnail(image: image)
        }
    }
}
