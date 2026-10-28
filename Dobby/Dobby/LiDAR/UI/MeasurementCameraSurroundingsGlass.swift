import SwiftUI

/// Show the matte interior of one native regular-glass pane. Its reflective
/// outer rim lives beyond the camera canvas, not on the photo's boundary.
/// The post-effect mask keeps measurement pixels and gestures untouched.
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
        GeometryReader { geometry in
            let canvas = CGRect(origin: .zero, size: geometry.size)
            if let pane = MeasurementCameraSurroundingsSurface.paneFrame(in: canvas) {
                Color.clear
                    .frame(width: pane.width, height: pane.height)
                    .glassEffect(.regular, in: Rectangle())
                    // Do not hide the real surrounding camera behind the
                    // regular material's adaptive backplate. Accessibility's
                    // explicit reduced-transparency preference still wins.
                    .opacity(reduceTransparency ? 1 : MeasurementCameraSurroundingsSurface.opacity)
                    .position(x: pane.midX, y: pane.midY)
            }
        }
            .clipped()
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

/// The effect's physical glass edge must never coincide with a visible screen
/// or photograph edge. Overscan changes only the material, never camera pixels.
nonisolated enum MeasurementCameraSurroundingsSurface {
    static let overscan: CGFloat = 96
    static let opacity: Double = 0.42

    static func paneFrame(in canvas: CGRect) -> CGRect? {
        guard [canvas.minX, canvas.minY, canvas.width, canvas.height].allSatisfy(\.isFinite),
              canvas.width > 0, canvas.height > 0 else { return nil }
        let pane = canvas.insetBy(dx: -overscan, dy: -overscan)
        guard [pane.minX, pane.minY, pane.width, pane.height].allSatisfy(\.isFinite) else { return nil }
        return pane
    }
}

/// Two rectangles use even-odd filling: everything outside the photo is glass,
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
