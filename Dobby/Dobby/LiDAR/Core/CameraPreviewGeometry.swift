import Foundation

/// ARKit's normalized sensor-to-viewport affine transform, without a dependency
/// on UIKit/CoreGraphics. x' = a*x + c*y + tx; y' = b*x + d*y + ty.
nonisolated struct CameraAffineTransform: Sendable, Equatable {
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var tx: Double
    var ty: Double

    static let identity = Self(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    fileprivate var determinant: Double? {
        guard [a, b, c, d, tx, ty].allSatisfy(\.isFinite) else { return nil }
        let scale = max(max(abs(a), abs(b)), max(abs(c), abs(d)))
        guard scale > 0 else { return nil }
        // Test conditioning relative to the matrix scale, rather than assuming
        // that every camera transform has the same absolute coefficient size.
        let relative = (a / scale) * (d / scale) - (b / scale) * (c / scale)
        let determinant = a * d - b * c
        guard relative.isFinite, abs(relative) > 1e-12,
              determinant.isFinite, determinant != 0 else { return nil }
        return determinant
    }
}

nonisolated enum CameraPreviewGeometry {
    /// Layout is in preview points, using the actually VISIBLE crop instead of
    /// the enlarged 2x ARSCNView. The icon may move; the focus point never does.
    static func exposureHandleCenter(focusPoint: ImagePoint, viewportOrigin: ImagePoint,
                                     viewportWidth: Double, viewportHeight: Double) -> ImagePoint? {
        guard validViewport(width: viewportWidth, height: viewportHeight),
              [focusPoint.x, focusPoint.y, viewportOrigin.x, viewportOrigin.y].allSatisfy(\.isFinite),
              viewportWidth >= 28, viewportHeight >= 28,
              focusPoint.x >= viewportOrigin.x, focusPoint.x <= viewportOrigin.x + viewportWidth,
              focusPoint.y >= viewportOrigin.y, focusPoint.y <= viewportOrigin.y + viewportHeight else { return nil }
        let minimumX = viewportOrigin.x + 14, maximumX = viewportOrigin.x + viewportWidth - 14
        let minimumY = viewportOrigin.y + 14, maximumY = viewportOrigin.y + viewportHeight - 14
        let proposedX = focusPoint.x + 64 <= viewportOrigin.x + viewportWidth ? focusPoint.x + 54 : focusPoint.x - 54
        return .init(x: min(maximumX, max(minimumX, proposedX)),
                     y: min(maximumY, max(minimumY, focusPoint.y)))
    }

    /// `viewPoint` is in PIXELS relative to the actual ARSCNView bounds, including
    /// any enlarged view used for zoom. `displayTransform` already contains
    /// orientation, mirroring and aspect-fill crop; none is applied a second time.
    static func sensorPoint(viewPoint: ImagePoint, viewportWidth: Double, viewportHeight: Double,
                            displayTransform transform: CameraAffineTransform) -> ImagePoint? {
        guard validViewport(width: viewportWidth, height: viewportHeight),
              viewPoint.x.isFinite, viewPoint.y.isFinite,
              viewPoint.x >= 0, viewPoint.x <= viewportWidth,
              viewPoint.y >= 0, viewPoint.y <= viewportHeight,
              let determinant = transform.determinant else { return nil }
        let x = viewPoint.x / viewportWidth - transform.tx
        let y = viewPoint.y / viewportHeight - transform.ty
        let sensorX = (transform.d * x - transform.c * y) / determinant
        let sensorY = (-transform.b * x + transform.a * y) / determinant
        return sensorBoundaryPoint(x: sensorX, y: sensorY)
    }

    /// Returns PIXELS in the actual preview bounds, or nil when the raw point is
    /// cropped out. This is the forward counterpart used to place a focus indicator.
    static func displayPoint(sensorPoint: ImagePoint, viewportWidth: Double, viewportHeight: Double,
                             displayTransform transform: CameraAffineTransform) -> ImagePoint? {
        guard validViewport(width: viewportWidth, height: viewportHeight),
              sensorPoint.isValid, transform.determinant != nil else { return nil }
        let x = transform.a * sensorPoint.x + transform.c * sensorPoint.y + transform.tx
        let y = transform.b * sensorPoint.x + transform.d * sensorPoint.y + transform.ty
        guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        let result = ImagePoint(x: x * viewportWidth, y: y * viewportHeight)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    private static func validViewport(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    private static func sensorBoundaryPoint(x: Double, y: Double) -> ImagePoint? {
        guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        // An exact viewport edge may map to sensor boundary 1. Preserve that
        // edge as the last representable normalized pixel, never clamp an
        // actually off-image/letterboxed tap onto the photographed subject.
        return .init(x: x == 1 ? 1.0.nextDown : x, y: y == 1 ? 1.0.nextDown : y)
    }
}
