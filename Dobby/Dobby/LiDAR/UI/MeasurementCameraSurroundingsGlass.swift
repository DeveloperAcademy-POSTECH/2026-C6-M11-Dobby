import SwiftUI

/// Dim the surrounding camera with a single translucent fill. The photo hole
/// stays clear, and this overlay never intercepts camera gestures.
struct MeasurementCameraSurroundingsGlass: View, Animatable {
    var photoRect: CGRect
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var animatableData: MeasurementCameraSurroundingsMask.AnimatableData {
        get { MeasurementCameraSurroundingsMask(photoRect: photoRect).animatableData }
        set {
            var mask = MeasurementCameraSurroundingsMask(photoRect: photoRect)
            mask.animatableData = newValue
            photoRect = mask.photoRect
        }
    }

    var body: some View {
        Color.black
            .opacity(reduceTransparency ? 1 : MeasurementCameraSurroundingsSurface.opacity)
            .mask {
                MeasurementCameraSurroundingsMask(photoRect: photoRect)
                    .fill(style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // This wrapper already interpolates the same CGRect as the camera
            // viewport. Do not animate a second, delayed child mask separately.
            .transaction { $0.animation = nil }
    }
}

nonisolated enum MeasurementCameraSurroundingsSurface {
    static let opacity: Double = 0.42
}

/// Two rectangles use even-odd filling: everything outside the photo is dimmed,
/// and the inner photo rectangle is a true transparent hole. Coordinates are
/// always in the complete camera canvas, including safe-area chrome.
struct MeasurementCameraSurroundingsMask: Shape {
    var photoRect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(photoRect.minX, photoRect.minY), .init(photoRect.width, photoRect.height)) }
        set {
            photoRect = CGRect(x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return Path() }
        var path = Path(rect)
        guard [photoRect.minX, photoRect.minY, photoRect.width, photoRect.height].allSatisfy(\.isFinite),
              photoRect.width > 0, photoRect.height > 0 else { return path }
        let hole = photoRect.intersection(rect)
        if !hole.isNull, hole.width > 0, hole.height > 0 { path.addRect(hole) }
        return path
    }
}
