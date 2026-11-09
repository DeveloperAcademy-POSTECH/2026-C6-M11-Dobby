// Created by mason on 11/9/26.
import CoreGraphics

/// Detail adapter for shared photo placement. The video surface remains separate
/// until the capture/framing integration is migrated to the photo-sized surface.
nonisolated struct DetailCameraPreviewLayout {
    let photoFrame: CGRect
    let previewFrame: CGRect
    let usesExtendedPreview: Bool
    private let layout: CameraPhotoPreviewLayout

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio,
         extendsPreviewBehindChrome: Bool = false) {
        layout = CameraPhotoPreviewLayout(containerSize: containerSize,
            photoAspectRatio: aspectRatio.previewRatio(isLandscape: containerSize.width > containerSize.height),
            prefersBottomAlignedPortrait: extendsPreviewBehindChrome && aspectRatio == .sixteenNine)
        photoFrame = layout.photoFrame
        usesExtendedPreview = layout.isBottomAligned
        previewFrame = usesExtendedPreview ? CGRect(origin: .zero, size: containerSize) : photoFrame
    }

    var photoRectInPreview: CGRect {
        photoFrame.offsetBy(dx: -previewFrame.minX, dy: -previewFrame.minY)
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        layout.controls(in: size, bottomSafeAreaInset: bottomSafeAreaInset)
    }
}
