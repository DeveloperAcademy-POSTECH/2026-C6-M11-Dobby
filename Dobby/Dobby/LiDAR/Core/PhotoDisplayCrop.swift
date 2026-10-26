import Foundation

/// A presentation window in the oriented photograph, with its origin at the
/// displayed top-left. This never crops stored RGB/depth, changes calibration,
/// or replaces the raw sensor coordinates used for measurement and editing.
nonisolated struct PhotoDisplayCrop: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = Self(x: 0, y: 0, width: 1, height: 1)

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }

    /// Reproduces the region visible through a portion of an aspect-fill camera
    /// preview. `visibleRect` is normalized in the complete preview viewport;
    /// the returned rectangle is normalized in the oriented photograph.
    /// Registered 2x snapshots already contain their RGB/depth crop, so callers
    /// must pass that snapshot's dimensions without applying zoom again.
    static func matchingPreview(imageSize: PixelSize, orientation: ImageOrientation,
                                viewportWidth: Double, viewportHeight: Double,
                                visibleRect: NormalizedRect) -> Self? {
        guard imageSize.isValid,
              viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0,
              visibleRect.isValid,
              visibleRect.x + visibleRect.width <= 1,
              visibleRect.y + visibleRect.height <= 1 else { return nil }

        let quarterTurn = orientation == .left || orientation == .right
        let imageWidth = Double(quarterTurn ? imageSize.height : imageSize.width)
        let imageHeight = Double(quarterTurn ? imageSize.width : imageSize.height)
        let scale = max(viewportWidth / imageWidth, viewportHeight / imageHeight)
        let displayedWidth = imageWidth * scale
        let displayedHeight = imageHeight * scale
        guard scale.isFinite, scale > 0,
              displayedWidth.isFinite, displayedHeight.isFinite,
              displayedWidth > 0, displayedHeight > 0 else { return nil }

        let originX = (viewportWidth - displayedWidth) / 2
        let originY = (viewportHeight - displayedHeight) / 2
        let left = (visibleRect.x * viewportWidth - originX) / displayedWidth
        let top = (visibleRect.y * viewportHeight - originY) / displayedHeight
        let right = ((visibleRect.x + visibleRect.width) * viewportWidth - originX) / displayedWidth
        let bottom = ((visibleRect.y + visibleRect.height) * viewportHeight - originY) / displayedHeight
        guard [left, top, right, bottom].allSatisfy(\.isFinite) else { return nil }
        // Arithmetic at a full-frame edge can stray a few ulps beyond 0 or 1.
        let minX = min(1, max(0, left)), minY = min(1, max(0, top))
        let maxX = min(1, max(0, right)), maxY = min(1, max(0, bottom))
        let result = Self(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return result.isValid ? result : nil
    }

    /// Preserve observed measurement handles even if they lie outside the
    /// initial camera window. Points must already be in oriented DISPLAY
    /// coordinates; raw sensor points must be rotated by the caller first.
    /// Invalid imported crops fall back to the full photograph.
    func including(displayPoints: [ImagePoint], padding: Double = 0.02) -> Self {
        let base = isValid ? self : .full
        let inset = padding.isFinite ? min(1, max(0, padding)) : 0
        var minX = base.x, minY = base.y
        var maxX = base.x + base.width, maxY = base.y + base.height
        for point in displayPoints where Self.isValidDisplayPoint(point) {
            minX = min(minX, max(0, point.x - inset))
            minY = min(minY, max(0, point.y - inset))
            maxX = max(maxX, min(1, point.x + inset))
            maxY = max(maxY, min(1, point.y + inset))
        }
        // Keep an unchanged axis byte-for-byte stable instead of introducing
        // rounding through a redundant (origin + dimension) - origin cycle.
        let width = minX == base.x && maxX == base.x + base.width ? base.width : maxX - minX
        let height = minY == base.y && maxY == base.y + base.height ? base.height : maxY - minY
        return Self(x: minX, y: minY, width: width, height: height)
    }

    private static func isValidDisplayPoint(_ point: ImagePoint) -> Bool {
        // An original pixel at x/y == 0 can rotate onto the display's right or
        // bottom edge (1). That is a valid DISPLAY edge, even though the raw
        // sampling contract deliberately excludes normalized coordinate 1.
        point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }
}
