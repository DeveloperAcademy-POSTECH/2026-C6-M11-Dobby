// Created by mason on 11/9/26.
import CoreGraphics

/// Shared presentation geometry only; camera selection and sensor crops belong to each capture flow.
nonisolated struct CameraPhotoPreviewLayout {
    let photoFrame: CGRect
    let isBottomAligned: Bool
    private let isSquarePortrait: Bool

    init(containerSize: CGSize, photoAspectRatio: Double,
         prefersBottomAlignedPortrait: Bool = false, portraitPhotoTop: CGFloat? = nil) {
        let width = containerSize.width, height = containerSize.height
        isSquarePortrait = width.isFinite && height.isFinite && width > 0 && width < height
            && abs(photoAspectRatio - 1) < 0.000001
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              photoAspectRatio.isFinite, photoAspectRatio > 0 else {
            photoFrame = .zero; isBottomAligned = false
            return
        }
        if isSquarePortrait {
            // Both capture screens use Figma 6396:10031: a 402pt square
            // centered at y=236 on an 874pt canvas, clear of the real header.
            let headerTop = portraitPhotoTop.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            let top = min(max((height - width) / 2, headerTop), height - 1)
            let side = min(width, height - top)
            photoFrame = CGRect(x: (width - side) / 2, y: top, width: side, height: side)
            isBottomAligned = false
            return
        }
        let photoHeight = width / CGFloat(photoAspectRatio)
        // Keep enough room for navigation on compact windows. Other ratios retain
        // the established measurement placement rather than filling the whole screen.
        let preferredFrame: CGRect
        if prefersBottomAlignedPortrait, abs(photoAspectRatio - 9.0 / 16) < 0.000001,
           width < height, height - photoHeight >= 120 {
            preferredFrame = CGRect(x: 0, y: height - photoHeight, width: width, height: photoHeight)
            isBottomAligned = true
        } else {
            let viewport = MeasurementCameraChromeLayout.photoViewport(
                containerWidth: Double(width), containerHeight: Double(height),
                photoAspectRatio: photoAspectRatio)
            preferredFrame = viewport.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .zero
            isBottomAligned = false
        }
        // Anchor ordinary portrait ratios below the real navigation header.
        // Keep the tall photo bottom-aligned when it already clears the header.
        // Compact windows scale the intact photo to preserve the same clearance.
        if width < height, let requestedTop = portraitPhotoTop,
           requestedTop.isFinite, requestedTop >= 0, preferredFrame.height > 0,
           !isBottomAligned || requestedTop > preferredFrame.minY {
            let top = min(requestedTop, max(0, height - 1))
            let fittedHeight = min(preferredFrame.height, height - top)
            let scale = fittedHeight / preferredFrame.height
            let fittedSize = CGSize(width: preferredFrame.width * scale, height: fittedHeight)
            photoFrame = CGRect(x: (width - fittedSize.width) / 2, y: top,
                                width: fittedSize.width, height: fittedSize.height)
        } else {
            photoFrame = preferredFrame
        }
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        guard let fallback = MeasurementCameraChromeLayout.controls(containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            photo: .init(x: photoFrame.minX, y: photoFrame.minY,
                         width: photoFrame.width, height: photoFrame.height),
            bottomSafeAreaInset: Double(bottomSafeAreaInset),
            diameter: 98, // Matches the shared shutter's Figma asset and touch surface.
            edgeClearance: isBottomAligned ? 32 : 16) else { return nil }
        guard isSquarePortrait else { return fallback }

        // The 64pt design padding includes a 34pt home safe area. Share the
        // same row in measurement and detail; compact screens keep the intact
        // row inside the photo when there is insufficient space beneath it.
        let shutterTop = Double(size.height - bottomSafeAreaInset) - 30 - fallback.shutter.height
        guard shutterTop >= Double(photoFrame.maxY) + 16 else { return fallback }
        let centerY = shutterTop + fallback.shutter.height / 2
        return .init(
            shutter: .init(x: fallback.shutter.x, y: shutterTop,
                           width: fallback.shutter.width, height: fallback.shutter.height),
            more: .init(x: fallback.more.x, y: centerY - fallback.more.height / 2,
                        width: fallback.more.width, height: fallback.more.height),
            accessory: .init(x: fallback.accessory.x, y: centerY - fallback.accessory.height / 2,
                             width: fallback.accessory.width, height: fallback.accessory.height))
    }
}
