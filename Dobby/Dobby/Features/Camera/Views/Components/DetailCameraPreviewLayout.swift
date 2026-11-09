import CoreGraphics

/// Detail-camera presentation only. The photograph is distinct from the video
/// behind the translucent header; that header must never enter the saved crop.
nonisolated struct DetailCameraPreviewLayout {
    let photoFrame: CGRect
    let previewFrame: CGRect
    let usesExtendedPreview: Bool

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio,
         extendsPreviewBehindChrome: Bool = false) {
        let width = containerSize.width, height = containerSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            photoFrame = .zero; previewFrame = .zero; usesExtendedPreview = false
            return
        }
        let photoHeight = width * 16 / 9
        // Figma 402 × 874: 159.33pt header + 714.67pt photograph. Retain
        // the existing compact/landscape layout when a full-width photograph
        // would overlap the navigation controls (e.g. a short split window).
        if extendsPreviewBehindChrome, aspectRatio == .sixteenNine,
           width < height, height - photoHeight >= 120 {
            photoFrame = CGRect(x: 0, y: height - photoHeight, width: width, height: photoHeight)
            previewFrame = CGRect(origin: .zero, size: containerSize)
            usesExtendedPreview = true
        } else {
            let viewport = MeasurementCameraChromeLayout.photoViewport(
                containerWidth: Double(width), containerHeight: Double(height),
                photoAspectRatio: aspectRatio.previewRatio(isLandscape: width > height))
            photoFrame = viewport.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .zero
            previewFrame = photoFrame
            usesExtendedPreview = false
        }
    }

    var photoRectInPreview: CGRect {
        photoFrame.offsetBy(dx: -previewFrame.minX, dy: -previewFrame.minY)
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        MeasurementCameraChromeLayout.controls(containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            photo: .init(x: photoFrame.minX, y: photoFrame.minY,
                         width: photoFrame.width, height: photoFrame.height),
            bottomSafeAreaInset: Double(bottomSafeAreaInset),
            edgeClearance: usesExtendedPreview ? 32 : 16)
    }
}
