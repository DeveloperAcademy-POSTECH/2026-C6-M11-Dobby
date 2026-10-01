import Foundation

/// Coordinates are normalized to the full image extent, not to a cropped preview.
/// The exact boundary value 1 is preserved here; callers clamp it before sampling.
nonisolated enum ImageCoordinateTransform {
    static func originalToDisplay(_ point: ImagePoint, orientation: ImageOrientation) -> ImagePoint {
        switch orientation {
        case .up: point
        case .right: .init(x: 1 - point.y, y: point.x)
        case .down: .init(x: 1 - point.x, y: 1 - point.y)
        case .left: .init(x: point.y, y: 1 - point.x)
        }
    }

    static func displayToOriginal(_ point: ImagePoint, orientation: ImageOrientation) -> ImagePoint {
        switch orientation {
        case .up: point
        case .right: .init(x: point.y, y: 1 - point.x)
        case .down: .init(x: 1 - point.x, y: 1 - point.y)
        case .left: .init(x: 1 - point.y, y: point.x)
        }
    }
}
