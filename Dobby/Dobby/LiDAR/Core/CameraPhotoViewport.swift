import Foundation

/// The camera photograph's actual view bounds, excluding capture controls.
/// Preserve the complete oriented image inside the available region instead
/// of filling the entire phone screen and silently narrowing its field of view.
nonisolated struct CameraPhotoViewport: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func layout(containerWidth: Double, containerHeight: Double,
                       photoAspectRatio: Double) -> Self? {
        guard [containerWidth, containerHeight, photoAspectRatio].allSatisfy(\.isFinite),
              containerWidth > 0, containerHeight > 0, photoAspectRatio > 0 else { return nil }

        let portrait = containerWidth <= containerHeight
        let availableX = 0.0
        let availableY = portrait ? 146.0 : 0.0
        let availableWidth = portrait ? containerWidth : containerWidth - 180
        let availableHeight = portrait ? containerHeight - 338 : containerHeight
        guard availableWidth.isFinite, availableHeight.isFinite,
              availableWidth > 0, availableHeight > 0 else { return nil }

        let heightAtFullWidth = availableWidth / photoAspectRatio
        let widthAtFullHeight = availableHeight * photoAspectRatio
        guard heightAtFullWidth.isFinite, widthAtFullHeight.isFinite,
              heightAtFullWidth > 0, widthAtFullHeight > 0 else { return nil }
        let width: Double
        let height: Double
        if heightAtFullWidth <= availableHeight {
            width = availableWidth
            height = heightAtFullWidth
        } else {
            width = widthAtFullHeight
            height = availableHeight
        }
        let x = availableX + (availableWidth - width) / 2
        let y = availableY + (availableHeight - height) / 2
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= containerWidth, y + height <= containerHeight else { return nil }
        return .init(x: x, y: y, width: width, height: height)
    }
}
