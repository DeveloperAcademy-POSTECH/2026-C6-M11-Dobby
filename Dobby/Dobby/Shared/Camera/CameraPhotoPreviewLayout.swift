// Created by mason on 11/9/26.
import CoreGraphics

/// Shared presentation geometry only; camera selection and sensor crops belong to each capture flow.
nonisolated struct CameraPhotoPreviewLayout {
    let photoFrame: CGRect
    let isBottomAligned: Bool

    init(containerSize: CGSize, photoAspectRatio: Double,
         prefersBottomAlignedPortrait: Bool = false) {
        let width = containerSize.width, height = containerSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              photoAspectRatio.isFinite, photoAspectRatio > 0 else {
            photoFrame = .zero; isBottomAligned = false
            return
        }
        let photoHeight = width / CGFloat(photoAspectRatio)
        // Keep enough room for navigation on compact windows. Other ratios retain
        // the established measurement placement rather than filling the whole screen.
        if prefersBottomAlignedPortrait, abs(photoAspectRatio - 9.0 / 16) < 0.000001,
           width < height, height - photoHeight >= 120 {
            photoFrame = CGRect(x: 0, y: height - photoHeight, width: width, height: photoHeight)
            isBottomAligned = true
        } else {
            let viewport = MeasurementCameraChromeLayout.photoViewport(
                containerWidth: Double(width), containerHeight: Double(height),
                photoAspectRatio: photoAspectRatio)
            photoFrame = viewport.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .zero
            isBottomAligned = false
        }
    }

    func controls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        MeasurementCameraChromeLayout.controls(containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            photo: .init(x: photoFrame.minX, y: photoFrame.minY,
                         width: photoFrame.width, height: photoFrame.height),
            bottomSafeAreaInset: Double(bottomSafeAreaInset),
            diameter: 98, // Matches the shared shutter's Figma asset and touch surface.
            edgeClearance: isBottomAligned ? 32 : 16)
    }
}
