import SwiftUI

/// Opaque camera chrome, shared by measurement and detail capture. The exact
/// photograph viewport remains a transparent hole; no material/blur is sampled.
struct CameraBlackSurroundings: View, Animatable {
    var photoRect: CGRect
    var animatableData: CameraSurroundingsMask.AnimatableData {
        get { CameraSurroundingsMask(photoRect: photoRect).animatableData }
        set {
            var mask = CameraSurroundingsMask(photoRect: photoRect)
            mask.animatableData = newValue; photoRect = mask.photoRect
        }
    }
    var body: some View {
        Color.black
            .mask { CameraSurroundingsMask(photoRect: photoRect).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transaction { $0.animation = nil }
    }
}

struct CameraSurroundingsMask: Shape {
    var photoRect: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(photoRect.minX, photoRect.minY), .init(photoRect.width, photoRect.height)) }
        set { photoRect = CGRect(x: newValue.first.first, y: newValue.first.second,
                                width: newValue.second.first, height: newValue.second.second) }
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
