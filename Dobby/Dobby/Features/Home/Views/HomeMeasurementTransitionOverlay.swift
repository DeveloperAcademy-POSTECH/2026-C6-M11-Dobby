import SwiftUI
import UIKit

/// The guide is constructed once, remains mounted throughout the transition,
/// and keeps its normal safe-area layout. Only the decorative home cover moves.
struct HomeMeasurementTransitionOverlay<Guide: View>: View, Animatable {
    let snapshot: UIImage?
    let seed: HomeMeasurementTransitionSeed
    var progress: Double
    private let guide: Guide

    init(snapshot: UIImage?, seed: HomeMeasurementTransitionSeed, progress: Double,
         @ViewBuilder guide: () -> Guide) {
        self.snapshot = snapshot
        self.seed = seed
        self.progress = progress
        self.guide = guide()
    }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        guide
            .allowsHitTesting(pose.isComplete)
            .accessibilityHidden(!pose.isComplete)
            .overlay {
                GeometryReader { geometry in
                    let origin = geometry.frame(in: .global).origin
                    ZStack(alignment: .topLeading) {
                        HomeMeasurementHomeCover(snapshot: snapshot, seed: seed, progress: progress)
                            .mask { HomeMeasurementCoverMask(seed: seed, progress: progress) }
                        HomeMeasurementBody(pose: pose)
                            .opacity(pose.isComplete ? 0 : 1)
                    }
                    .frame(width: seed.canvasSize.width, height: seed.canvasSize.height, alignment: .topLeading)
                    .offset(x: -origin.x, y: -origin.y)
                    // Progress is already interpolated by this Animatable view.
                    // Apply the analytic pose directly, including its terminal
                    // visibility change, without another child animation.
                    .transaction { $0.animation = nil }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct HomeMeasurementHomeCover: View {
    let snapshot: UIImage?
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        let lowerTop = 494 * pose.scale
        ZStack(alignment: .topLeading) {
            Color("BrandNeutral50")
            if let snapshot {
                // The supplied home PNGs are references only. Keep the real
                // current card, fonts, thumbnail and native tab bar from the window.
                Image(uiImage: snapshot).resizable()
                    .frame(width: seed.canvasSize.width, height: seed.canvasSize.height)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(height: max(0, seed.canvasSize.height - lowerTop))
                            .offset(y: lowerTop)
                    }
                    .offset(y: pose.homeDrift)
                    .opacity(pose.homeOpacity)
            }
            HomeMeasurementTapeArtwork(seed: seed, progress: progress)
        }
        .frame(width: seed.canvasSize.width, height: seed.canvasSize.height)
    }
}

/// Complement of the prototype's destination-in guide gradient. Keeping the
/// real guide underneath an inverse mask avoids clipping its extended safe-area
/// background or re-laying out a NavigationStack as the wipe finishes.
private struct HomeMeasurementCoverMask: View {
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        Canvas { context, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            if progress <= 0 {
                context.fill(bounds, with: .color(.white))
            } else if !pose.isComplete {
                let band = CGRect(x: 0, y: pose.guideMaskOpaqueEnd, width: size.width,
                    height: pose.guideMaskTransparentEnd - pose.guideMaskOpaqueEnd)
                context.fill(Path(band), with: .linearGradient(Gradient(colors: [.clear, .white]),
                    startPoint: CGPoint(x: 0, y: pose.guideMaskOpaqueEnd),
                    endPoint: CGPoint(x: 0, y: pose.guideMaskTransparentEnd)))
                let lowerTop = max(0, pose.guideMaskTransparentEnd)
                context.fill(Path(CGRect(x: 0, y: lowerTop, width: size.width,
                    height: max(0, size.height - lowerTop))), with: .color(.white))
            }
        }
    }
}

struct HomeMeasurementBody: View {
    let pose: HomeMeasurementTransitionPose

    var body: some View {
        Image("HomeTransitionTapeReel")
            .resizable()
            .scaledToFit()
            .frame(width: pose.bodyDiameter, height: pose.bodyDiameter)
            .rotationEffect(.radians(pose.bodyRotationRadians))
            .position(pose.bodyCenter)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Keep Chak's dynamic strip length, with the Figma tip's 8pt corners and 5° tilt.
/// The strip enters an inset slot; the wider handle keeps its visible shoulders.
struct HomeMeasurementTapeArtwork: View {
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        Canvas { context, _ in
            guard pose.scale > 0 else { return }
            context.translateBy(x: (seed.canvasSize.width - seed.artworkWidth) / 2, y: 0)
            context.scaleBy(x: pose.scale, y: pose.scale)
            let pull = seed.pull
            let drop = pose.drop / pose.scale
            let enter = CGFloat(HomeMeasurementMotion.smooth(progress))
            let top = 275 + drop
            let base = 411.5 + pull + drop * (enter * 0.9 + 0.1)
            let length = max(130, base - top)
            let tipRadius: CGFloat = 8
            let tipAngle = CGFloat.pi / 36
            let tipTransform = CGAffineTransform(translationX: 157, y: top + length - 1)
                .rotated(by: tipAngle)
            // Figma's ribbon is narrower than the 92pt handle. Keep these
            // attachment points inside the handle rather than on its outer arc.
            let leftJoin = CGPoint(x: 4.8, y: tipRadius).applying(tipTransform)
            let rightJoin = CGPoint(x: 90.35, y: tipRadius).applying(tipTransform)
            fill(&context, color: Color("BrandNeutral200"),
                 points: [CGPoint(x: 179.2, y: top), CGPoint(x: 231.7, y: top),
                          rightJoin, leftJoin])
            fill(&context, color: Color("BrandNeutral400"),
                 points: [CGPoint(x: 208.8, y: top), CGPoint(x: 231.7, y: top),
                          rightJoin])
            var offset: CGFloat = 9
            while offset < length - 2 {
                let x = 179.2 + (leftJoin.x - 179.2) * offset / (leftJoin.y - top)
                let longMark = Int(((length - offset) / 8).rounded()) % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: top + offset))
                let width: CGFloat = longMark ? 29 : 17
                tick.addLine(to: CGPoint(x: x + width, y: top + offset + width * tan(tipAngle)))
                context.stroke(tick, with: .color(.black), lineWidth: 1)
                offset += 8
            }
            // Paint the tip over the strip's joining chord so there is no empty
            // wedge at either rounded corner or at the shading's lower end.
            context.concatenate(tipTransform)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 92, height: 68), cornerRadius: tipRadius),
                with: .color(Color("BrandNeutral600")))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func fill(_ context: inout GraphicsContext, color: Color, points: [CGPoint]) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}
