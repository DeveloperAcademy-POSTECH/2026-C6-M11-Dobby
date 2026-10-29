import Foundation

/// Presentation-only placement. Moving the controls must never resize or crop
/// the calibrated photograph, or change its normalized measurement coordinates.
nonisolated struct MeasurementCameraChromeLayout: Sendable, Equatable {
    let zoomFrame: CameraPhotoViewport
    let guidanceFrame: CameraPhotoViewport?

    var zoomCenterX: Double { zoomFrame.x + zoomFrame.width / 2 }
    var zoomCenterY: Double { zoomFrame.y + zoomFrame.height / 2 }
    var guidanceCenterX: Double? { guidanceFrame.map { $0.x + $0.width / 2 } }
    var guidanceCenterY: Double? { guidanceFrame.map { $0.y + $0.height / 2 } }

    /// The measurement screen may show the tall photograph behind the shutter
    /// chrome. Fit the whole selected photo inside a 9:16 camera canvas, rather
    /// than reserving a second empty 192pt region in its pixel transform.
    /// The default photo's full source field stays intact; this changes only
    /// the view's bounds/placement, not sensor pixels or measurement inputs.
    static func photoViewport(containerWidth: Double, containerHeight: Double,
                              photoAspectRatio: Double) -> CameraPhotoViewport? {
        guard [containerWidth, containerHeight, photoAspectRatio].allSatisfy(\.isFinite),
              containerWidth > 0, containerHeight > 0, photoAspectRatio > 0 else { return nil }
        if containerWidth > containerHeight {
            return CameraPhotoViewport.layout(containerWidth: containerWidth,
                containerHeight: containerHeight, photoAspectRatio: photoAspectRatio)
        }
        let top = 60.0
        let maximumHeight = min(containerWidth * (16.0 / 9), containerHeight - top * 2)
        guard maximumHeight.isFinite, maximumHeight > 0 else { return nil }
        let heightAtFullWidth = containerWidth / photoAspectRatio
        let width: Double, height: Double
        if heightAtFullWidth.isFinite, heightAtFullWidth <= maximumHeight {
            width = containerWidth
            height = heightAtFullWidth
        } else {
            height = maximumHeight
            width = maximumHeight * photoAspectRatio
        }
        let x = (containerWidth - width) / 2
        let y = top + (maximumHeight - height) * 0.375
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= containerWidth, y + height <= containerHeight else { return nil }
        return .init(x: x, y: y, width: width, height: height)
    }

    /// Match the detail camera's 114pt bottom controls row. Safe-area padding
    /// belongs below the row, so the shutter centre is 57pt above that boundary.
    /// Ratios never move this anchor or alter the calibrated photograph.
    static func shutterFrame(containerWidth: Double, containerHeight: Double,
                             sourceAspectRatio: Double = 0.75,
                             diameter: Double = 92, edgeClearance: Double = 8,
                             landscapeControlsWidth: Double = 180,
                             bottomSafeAreaInset: Double = 0) -> CameraPhotoViewport? {
        guard [containerWidth, containerHeight, sourceAspectRatio, diameter,
               edgeClearance, landscapeControlsWidth, bottomSafeAreaInset].allSatisfy(\.isFinite),
              containerWidth > 0, containerHeight > 0, sourceAspectRatio > 0,
              diameter >= 44, edgeClearance >= 0, landscapeControlsWidth >= 0,
              bottomSafeAreaInset >= 0 else { return nil }
        let controlsHeight = 114.0
        guard diameter <= controlsHeight,
              containerWidth >= diameter + 48 * 2 + 16 * 4 else { return nil }
        let radius = diameter / 2
        let centerX = containerWidth / 2
        let centerY = containerHeight - bottomSafeAreaInset - controlsHeight / 2
        guard centerX - radius >= 8, centerX + radius <= containerWidth - 8,
              centerY - radius >= 16,
              centerY + radius <= containerHeight - bottomSafeAreaInset else { return nil }
        return .init(x: centerX - radius, y: centerY - radius, width: diameter, height: diameter)
    }

    /// The fixed shutter row remains independent of the selected aspect ratio.
    /// The zoom follows the photo's lower edge until it reaches that row's
    /// safety margin. In landscape it stays in the photo, left of the sidebar.
    static func layout(containerWidth: Double, containerHeight: Double,
                       photo: CameraPhotoViewport, zoomDiameter: Double = 48,
                       guidanceHeight: Double = 44,
                       bottomControlsHeight: Double = 192,
                       landscapeControlsWidth: Double = 180,
                       shutter: CameraPhotoViewport? = nil) -> Self? {
        let inputs = [containerWidth, containerHeight, photo.x, photo.y, photo.width, photo.height,
                      zoomDiameter, guidanceHeight, bottomControlsHeight, landscapeControlsWidth]
        guard inputs.allSatisfy(\.isFinite), containerWidth > 0, containerHeight > 0,
              photo.x >= 0, photo.y >= 0, photo.width > 0, photo.height > 0,
              zoomDiameter >= 44, guidanceHeight >= 0,
              bottomControlsHeight >= 0, landscapeControlsWidth >= 0 else { return nil }
        let photoRight = photo.x + photo.width, photoBottom = photo.y + photo.height
        guard photoRight.isFinite, photoBottom.isFinite,
              photoRight <= containerWidth, photoBottom <= containerHeight else { return nil }

        let portrait = containerWidth <= containerHeight
        let usableRight = portrait ? containerWidth : containerWidth - landscapeControlsWidth
        if let shutter {
            guard [shutter.x, shutter.y, shutter.width, shutter.height].allSatisfy(\.isFinite),
                  shutter.x >= 0, shutter.y >= 0, shutter.width > 0, shutter.height > 0,
                  shutter.x + shutter.width <= containerWidth,
                  shutter.y + shutter.height <= containerHeight else { return nil }
        }
        let footerBottom = portrait ? containerHeight - bottomControlsHeight - 12 : containerHeight
        let shutterBottom = shutter.map { $0.y - 12 } ?? footerBottom
        let usableBottom = min(footerBottom, shutterBottom)
        let right = min(photoRight, usableRight), bottom = min(photoBottom, usableBottom)
        let width = right - photo.x, height = bottom - photo.y
        guard width.isFinite, height.isFinite, width >= zoomDiameter, height >= zoomDiameter else { return nil }

        let radius = zoomDiameter / 2
        // Normally radius + 16pt above the photo edge; compact windows reduce
        // only the empty margin, never the button's 44pt-or-larger hit area.
        let centerX = min(max(photo.x + photo.width / 2, photo.x + radius), right - radius)
        let centerY = min(photoBottom - radius - 16, bottom - radius)
        let clampedCenterY = max(photo.y + radius, centerY)
        let zoom = CameraPhotoViewport(x: centerX - radius, y: clampedCenterY - radius,
                                      width: zoomDiameter, height: zoomDiameter)

        let guidanceWidth = min(380, width - 32)
        let guidanceTop = zoom.y - 12 - guidanceHeight
        let guidance: CameraPhotoViewport?
        if guidanceHeight > 0, guidanceWidth >= 44, guidanceTop >= photo.y + 8 {
            guidance = .init(x: min(max(centerX - guidanceWidth / 2, photo.x + 16),
                                   right - 16 - guidanceWidth),
                             y: guidanceTop, width: guidanceWidth, height: guidanceHeight)
        } else {
            // Keeping the zoom usable is preferable to shrinking both controls
            // or drawing a guidance label over the navigation/shutter controls.
            guidance = nil
        }
        return .init(zoomFrame: zoom, guidanceFrame: guidance)
    }
}
