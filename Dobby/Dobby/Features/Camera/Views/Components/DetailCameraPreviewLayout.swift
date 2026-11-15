// Created by mason on 11/9/26.
import CoreGraphics

/// Detail presentation geometry. Video fills only the photograph, so moving
/// the square viewport cannot introduce an additional aspect-fill crop.
nonisolated struct DetailCameraPreviewLayout {
    let photoFrame: CGRect
    let previewFrame: CGRect
    let isBottomAligned: Bool
    private let layout: CameraPhotoPreviewLayout
    private let isSquarePortrait: Bool

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio,
         prefersBottomAlignedPortrait: Bool = false, portraitPhotoTop: CGFloat? = nil) {
        layout = CameraPhotoPreviewLayout(containerSize: containerSize,
            photoAspectRatio: aspectRatio.previewRatio(isLandscape: containerSize.width > containerSize.height),
            prefersBottomAlignedPortrait: prefersBottomAlignedPortrait && aspectRatio == .sixteenNine,
            portraitPhotoTop: portraitPhotoTop)
        let width = containerSize.width, height = containerSize.height
        isSquarePortrait = aspectRatio == .square && width.isFinite && height.isFinite
            && width > 0 && width < height
        if isSquarePortrait {
            // Figma 6396:10031: a 402pt square is centered at y=236 on an
            // 874pt canvas. Compact windows still clear the actual header.
            let headerTop = portraitPhotoTop.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            let top = min(max((height - width) / 2, headerTop), height - 1)
            let side = min(width, height - top)
            photoFrame = CGRect(x: (width - side) / 2, y: top, width: side, height: side)
            isBottomAligned = false
        } else {
            photoFrame = layout.photoFrame
            isBottomAligned = layout.isBottomAligned
        }
        previewFrame = photoFrame
    }

    var photoRectInPreview: CGRect {
        photoFrame.offsetBy(dx: -previewFrame.minX, dy: -previewFrame.minY)
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        guard isSquarePortrait else {
            return layout.controls(in: size, bottomSafeAreaInset: bottomSafeAreaInset)
        }
        guard let fallback = MeasurementCameraChromeLayout.controls(
            containerWidth: size.width, containerHeight: size.height,
            photo: .init(x: photoFrame.minX, y: photoFrame.minY,
                         width: photoFrame.width, height: photoFrame.height),
            bottomSafeAreaInset: bottomSafeAreaInset, diameter: 98, edgeClearance: 16) else { return nil }

        // The design's 64pt bottom padding includes the 34pt home safe area.
        // Keep that 30pt clearance instead of centering the row in all empty
        // space below the square. Fall back inside the photo on compact screens.
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
