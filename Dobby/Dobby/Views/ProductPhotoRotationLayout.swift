import CoreGraphics
import Foundation
import SwiftUI

/// Rotation belongs to the picture, not the gallery's fixed chrome. These
/// calculations use the interpolated angle so the image also fits at 45°.
nonisolated enum ProductPhotoRotationLayout {
    static func normalizedQuarterTurns(_ value: Int) -> Int {
        ((value % 4) + 4) % 4
    }

    static func nextDisplayAngle(currentDegrees: Double, previousQuarterTurns: Int,
                                 nextQuarterTurns: Int) -> Double {
        let previous = normalizedQuarterTurns(previousQuarterTurns)
        let next = normalizedQuarterTurns(nextQuarterTurns)
        let delta = normalizedQuarterTurns(next - previous)
        // A CCW turn is persisted as 0 → 3. Keep it at -90° instead of taking
        // a long 270° route, while four clockwise turns continue 270° → 360°.
        let signedDelta = delta == 3 ? -1 : delta
        return currentDegrees + Double(signedDelta) * 90
    }

    static func rotatedBounds(imageSize: CGSize, angleDegrees: Double) -> CGSize {
        guard isUsable(imageSize), angleDegrees.isFinite else { return .zero }
        let radians = angleDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = CGFloat(abs(cos(radians)))
        let sine = CGFloat(abs(sin(radians)))
        return CGSize(width: imageSize.width * cosine + imageSize.height * sine,
                      height: imageSize.width * sine + imageSize.height * cosine)
    }

    /// The returned dimensions are the unrotated image frame. Rotating this
    /// frame by angleDegrees produces a bounding box inside containerSize.
    static func fittedImageSize(imageSize: CGSize, containerSize: CGSize,
                                angleDegrees: Double) -> CGSize {
        guard isUsable(imageSize), isUsable(containerSize) else { return .zero }
        let bounds = rotatedBounds(imageSize: imageSize, angleDegrees: angleDegrees)
        guard isUsable(bounds) else { return .zero }
        let scale = min(containerSize.width / bounds.width, containerSize.height / bounds.height)
        guard scale.isFinite, scale > 0 else { return .zero }
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return isUsable(fitted) ? fitted : .zero
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

/// An animatable angle keeps the fit calculation in step with every animation
/// frame. No black canvas, controls, or saved-image mutation are part of this view.
struct ProductPhotoRotatingImage: View, Animatable {
    let image: CGImage
    var angleDegrees: Double

    var animatableData: Double {
        get { angleDegrees }
        set { angleDegrees = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = ProductPhotoRotationLayout.fittedImageSize(
                imageSize: CGSize(width: image.width, height: image.height),
                containerSize: geometry.size, angleDegrees: angleDegrees)
            if size.width > 0, size.height > 0 {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(angleDegrees))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}
