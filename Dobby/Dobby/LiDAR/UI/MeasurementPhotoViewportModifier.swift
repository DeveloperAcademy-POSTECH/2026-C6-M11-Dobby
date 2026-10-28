import SwiftUI

/// Interpolate the actual UIKit camera bounds along with its photo window.
/// Scaling a snapshot of the old view would leave outlines and taps behind.
struct MeasurementPhotoViewportModifier: AnimatableModifier {
    var rect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)) }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second)
        }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .position(x: rect.midX, y: rect.midY)
            .transaction { $0.animation = nil }
    }
}
