// Created by mason on 11/9/26.
import CoreGraphics

/// Detail adapter for shared photo placement. Video fills only the photograph,
/// so navigation space cannot introduce an additional aspect-fill crop.
nonisolated struct DetailCameraPreviewLayout {
    let photoFrame: CGRect
    let previewFrame: CGRect
    let isBottomAligned: Bool
    private let layout: CameraPhotoPreviewLayout

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio,
         prefersBottomAlignedPortrait: Bool = false, portraitPhotoTop: CGFloat? = nil) {
        layout = CameraPhotoPreviewLayout(containerSize: containerSize,
            photoAspectRatio: aspectRatio.previewRatio(isLandscape: containerSize.width > containerSize.height),
            prefersBottomAlignedPortrait: prefersBottomAlignedPortrait && aspectRatio == .sixteenNine,
            portraitPhotoTop: portraitPhotoTop)
        photoFrame = layout.photoFrame
        isBottomAligned = layout.isBottomAligned
        previewFrame = photoFrame
    }

    var photoRectInPreview: CGRect {
        photoFrame.offsetBy(dx: -previewFrame.minX, dy: -previewFrame.minY)
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        layout.controls(in: size, bottomSafeAreaInset: bottomSafeAreaInset)
    }
}
