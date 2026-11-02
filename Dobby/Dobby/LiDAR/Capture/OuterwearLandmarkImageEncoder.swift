import CoreGraphics
import Foundation
import ImageIO

/// Encodes the supplied raster in ImageCoordinateTransform's upright coordinates.
/// Garment crops are explicitly prepared before encoding; encoding only resizes.
nonisolated enum OuterwearLandmarkImageEncoder {
    static let maximumImageBytes = 2 * 1024 * 1024
    static let maximumDimension = 2048

    struct Image: Encodable, Sendable {
        let imageDataUrl: String
        let width: Int
        let height: Int
    }

    struct Region: Encodable, Sendable {
        let id: String
        let image: Image
    }

    /// The normalized rect must describe actual pixel boundaries so the same
    /// rect can restore model coordinates without a hidden rounding offset.
    static func croppedImage(_ image: CGImage, rect: NormalizedRect) throws -> CGImage {
        guard rect.isValid else { throw OuterwearLandmarkClientError.invalidImage }
        let components = [rect.x * Double(image.width), rect.y * Double(image.height),
                          rect.width * Double(image.width), rect.height * Double(image.height)]
        guard components.allSatisfy({ abs($0 - $0.rounded()) < 1e-8 }),
              let raster = image.cropping(to: CGRect(x: components[0].rounded(), y: components[1].rounded(),
                width: components[2].rounded(), height: components[3].rounded())) else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        return raster
    }

    static func encode(_ image: CGImage, orientation: ImageOrientation) throws -> Image {
        guard image.width > 0, image.height > 0,
              image.width <= 16_384, image.height <= 16_384 else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        let quarterTurn = orientation == .right || orientation == .left
        let uprightWidth = quarterTurn ? image.height : image.width
        let uprightHeight = quarterTurn ? image.width : image.height
        for maximum in [maximumDimension, 1536, 1024, 768] {
            try Task.checkCancellation()
            let scale = min(1, Double(maximum) / Double(max(uprightWidth, uprightHeight)))
            let width = max(1, Int((Double(uprightWidth) * scale).rounded()))
            let height = max(1, Int((Double(uprightHeight) * scale).rounded()))
            guard let raster = uprightImage(image, orientation: orientation, width: width, height: height) else {
                throw OuterwearLandmarkClientError.invalidImage
            }
            for quality in [0.85, 0.7, 0.55, 0.4] {
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                    throw OuterwearLandmarkClientError.invalidImage
                }
                // Only upload metadata is created; EXIF, GPS and camera thumbnails
                // are not copied from the captured photo.
                CGImageDestinationAddImage(destination, raster, [
                    kCGImagePropertyOrientation: 1,
                    kCGImageDestinationLossyCompressionQuality: quality
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw OuterwearLandmarkClientError.invalidImage
                }
                if output.length <= maximumImageBytes {
                    return Image(imageDataUrl: "data:image/jpeg;base64," + (output as Data).base64EncodedString(),
                                 width: width, height: height)
                }
            }
        }
        throw OuterwearLandmarkClientError.imageTooLarge
    }

    static func uprightImage(_ image: CGImage, orientation: ImageOrientation,
                                     width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let w = CGFloat(width), h = CGFloat(height)
        let sourceW = CGFloat(image.width), sourceH = CGFloat(image.height)
        // Core Graphics uses bottom-left coordinates. These transforms are the
        // top-left originalToDisplay rotations expressed in that coordinate space.
        let transform: CGAffineTransform
        switch orientation {
        case .up:
            transform = .init(a: w / sourceW, b: 0, c: 0, d: h / sourceH, tx: 0, ty: 0)
        case .right:
            transform = .init(a: 0, b: -h / sourceW, c: w / sourceH, d: 0, tx: 0, ty: h)
        case .down:
            transform = .init(a: -w / sourceW, b: 0, c: 0, d: -h / sourceH, tx: w, ty: h)
        case .left:
            transform = .init(a: 0, b: h / sourceW, c: -w / sourceH, d: 0, tx: w, ty: 0)
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
