import Foundation

/// Reduce only the preview analysis raster. Normalized points keep referring to
/// the complete camera field of view, and the snapshot uses the original RGB.
nonisolated enum LivePreviewRasterGeometry {
    static let maximumDimension = 960

    static func analysisSize(for original: PixelSize, maximumDimension: Int = maximumDimension) -> PixelSize? {
        guard original.isValid, maximumDimension > 0, maximumDimension <= 16_384 else { return nil }
        if max(original.width, original.height) <= maximumDimension { return original }
        var a = original.width, b = original.height
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let unitWidth = original.width / a, unitHeight = original.height / a
        let multiplier = min(a, maximumDimension / max(unitWidth, unitHeight))
        // ARKit formats reduce exactly. Refuse an incompatible custom format
        // instead of stretching it or changing its normalized coordinates.
        guard multiplier > 0 else { return nil }
        return .init(width: unitWidth * multiplier, height: unitHeight * multiplier)
    }
}
