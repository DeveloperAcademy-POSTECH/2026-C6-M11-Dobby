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

    /// One shutter position is shared by every selected ratio. In particular,
    /// it must clear BOTH the 4:3 lower border and the 16:9 lower border rather
    /// than moving with whichever photograph happens to be selected now.
    static func shutterFrame(containerWidth: Double, containerHeight: Double,
                             sourceAspectRatio: Double = 0.75,
                             diameter: Double = 92, edgeClearance: Double = 8,
                             landscapeControlsWidth: Double = 180) -> CameraPhotoViewport? {
        guard [containerWidth, containerHeight, sourceAspectRatio, diameter,
               edgeClearance, landscapeControlsWidth].allSatisfy(\.isFinite),
              containerWidth > 0, containerHeight > 0, sourceAspectRatio > 0,
              diameter >= 44, edgeClearance >= 0, landscapeControlsWidth >= 0 else { return nil }
        let portrait = containerWidth <= containerHeight
        let radius = diameter / 2
        let centerX = portrait ? containerWidth / 2 : containerWidth - landscapeControlsWidth / 2
        guard centerX - radius >= 8, centerX + radius <= containerWidth - 8 else { return nil }
        let lower = portrait ? max(146 + radius + edgeClearance, containerHeight * 0.4) : radius + 16
        let upper = containerHeight - radius - 16
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        let preferred = portrait ? containerHeight - 156 : containerHeight / 2
        let clearanceRadius = radius + edgeClearance
        guard clearanceRadius.isFinite else { return nil }
        let aspects = [sourceAspectRatio, 1, portrait ? 9.0 / 16 : 16.0 / 9]
        let photos = aspects.compactMap {
            photoViewport(containerWidth: containerWidth, containerHeight: containerHeight, photoAspectRatio: $0)
        }
        guard photos.count == aspects.count else { return nil }

        // Each interval contains shutter-centre positions that would bring its
        // circular edge within edgeClearance of an actual photo border segment.
        // Vertical segments matter too for narrow source photos and sidebars.
        var excluded: [(lower: Double, upper: Double)] = []
        for photo in photos {
            let right = photo.x + photo.width, bottom = photo.y + photo.height
            let horizontalDistance = max(photo.x - centerX, centerX - right, 0)
            if horizontalDistance < clearanceRadius {
                let reach = (clearanceRadius * clearanceRadius - horizontalDistance * horizontalDistance).squareRoot()
                excluded.append((photo.y - reach, photo.y + reach))
                excluded.append((bottom - reach, bottom + reach))
            }
            for x in [photo.x, right] {
                let distance = abs(centerX - x)
                if distance < clearanceRadius {
                    let reach = (clearanceRadius * clearanceRadius - distance * distance).squareRoot()
                    excluded.append((photo.y - reach, bottom + reach))
                }
            }
        }
        var candidates = [min(max(preferred, lower), upper), lower, upper]
        for interval in excluded {
            for endpoint in [interval.lower, interval.upper] where endpoint >= lower && endpoint <= upper {
                candidates.append(endpoint)
            }
        }
        let epsilon = 1e-9
        let accepted = candidates.filter { candidate in
            candidate.isFinite && !excluded.contains {
                candidate > $0.lower + epsilon && candidate < $0.upper - epsilon
            }
        }
        guard let centerY = accepted.min(by: { a, b in
            let lhs = abs(a - preferred), rhs = abs(b - preferred)
            return abs(lhs - rhs) > epsilon ? lhs < rhs : a < b
        }) else { return nil }
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
        let shutterBottom = portrait ? shutter.map { $0.y - 12 } ?? footerBottom : containerHeight
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
