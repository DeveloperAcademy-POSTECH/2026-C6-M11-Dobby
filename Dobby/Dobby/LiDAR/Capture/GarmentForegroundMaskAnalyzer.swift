import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

nonisolated struct GarmentImageRecognition: Sendable {
    var points: [GarmentLandmark]
    var detectionConfidence: Double
    var modelVersion: String
}

/// A future top model can implement this contract without changing camera or
/// silhouette presentation. Points always refer to the complete raw RGB raster.
nonisolated protocol GarmentImageRecognizing: Sendable {
    func recognizeImage(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentImageRecognition
}

/// Vision supplies the silhouette; the garment model supplies semantic evidence.
/// Neither the largest foreground nor a model's rectangular box is a silhouette.
nonisolated final class GarmentForegroundMaskAnalyzer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func analyze(_ image: CGImage, points: [GarmentLandmark]) throws -> GarmentMaskSelection {
        let original = PixelSize(width: image.width, height: image.height)
        let size = try Self.analysisSize(for: original)
        let scale = Double(size.width) / Double(original.width)
        let input = CIImage(cgImage: image).transformed(by: .init(scaleX: scale, y: scale))
        guard let resized = context.createCGImage(input,
            from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw GarmentMaskAssociationError.invalidMask
        }
        let handler = VNImageRequestHandler(cgImage: resized, orientation: .up)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw GarmentMaskAssociationError.noForeground
        }
        // Bound work and reject clutter rather than ignoring unexamined objects.
        guard observation.allInstances.count <= 4 else {
            throw GarmentMaskAssociationError.multipleForegrounds
        }
        var masks: [GarmentMask] = []
        for instance in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance), from: handler)
            masks.append(try Self.copyMask(buffer, expectedSize: size))
        }
        return try GarmentMaskAssociation.select(masks: masks, points: points, imageSize: original)
    }

    private static func analysisSize(for original: PixelSize) throws -> PixelSize {
        guard original.isValid else { throw GarmentMaskAssociationError.invalidMask }
        var a = original.width, b = original.height
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let unitWidth = original.width / a, unitHeight = original.height / a
        let multiplier = min(a, 512 / max(unitWidth, unitHeight))
        // Coprime photo dimensions (for example 400 × 533) cannot be reduced
        // to an integer raster of the exact same aspect. Keep those bounded
        // images intact instead of cropping or stretching their mask.
        if multiplier == 0 {
            guard original.width * original.height <= 4_194_304 else {
                throw GarmentMaskAssociationError.invalidMask
            }
            return original
        }
        return .init(width: unitWidth * multiplier, height: unitHeight * multiplier)
    }

    private static func copyMask(_ buffer: CVPixelBuffer, expectedSize: PixelSize) throws -> GarmentMask {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width == expectedSize.width, height == expectedSize.height,
              format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw GarmentMaskAssociationError.invalidMask
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerPixel = format == kCVPixelFormatType_OneComponent32Float ? MemoryLayout<Float>.stride : 1
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= width * bytesPerPixel else {
            throw GarmentMaskAssociationError.invalidMask
        }
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let foreground: Bool
                if format == kCVPixelFormatType_OneComponent32Float {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    foreground = value.isFinite && value >= 0.5
                } else {
                    foreground = row.assumingMemoryBound(to: UInt8.self)[x] >= 128
                }
                values[y * width + x] = foreground ? 1 : 0
            }
        }
        return .init(size: expectedSize, values: values)
    }
}
