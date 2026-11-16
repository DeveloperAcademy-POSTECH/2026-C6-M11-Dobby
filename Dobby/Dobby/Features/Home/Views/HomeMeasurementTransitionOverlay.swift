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

/// The dynamic tape geometry comes directly from Chak's draw(extension,t).
/// Only its housing is a supplied static asset; the strip must stretch with drag.
struct HomeMeasurementTapeArtwork: View {
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        Canvas { context, _ in
            guard pose.scale > 0 else { return }
            context.scaleBy(x: pose.scale, y: pose.scale)
            let pull = seed.pull
            let drop = pose.drop / pose.scale
            let enter = CGFloat(HomeMeasurementMotion.smooth(progress))
            let top = 275 + drop
            let base = 411.5 + pull + drop * (enter * 0.9 + 0.1)
            let length = max(130, base - top)
            fill(&context, color: Color(red: 224 / 255, green: 223 / 255, blue: 221 / 255),
                 points: [CGPoint(x: 176, y: top), CGPoint(x: 233, y: top),
                          CGPoint(x: 245.5, y: top + length + 7.5), CGPoint(x: 157, y: top + length)])
            fill(&context, color: Color(red: 171 / 255, green: 168 / 255, blue: 163 / 255),
                 points: [CGPoint(x: 209.5, y: top), CGPoint(x: 233, y: top),
                          CGPoint(x: 245.5, y: top + length + 7.5)])
            var offset: CGFloat = 9
            while offset < length - 2 {
                let x = 176 - 19 * offset / length
                let longMark = Int(((length - offset) / 8).rounded()) % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: top + offset))
                tick.addLine(to: CGPoint(x: x + (longMark ? 29 : 17), y: top + offset + 2))
                context.stroke(tick, with: .color(Color(white: 20 / 255)), lineWidth: 0.95)
                offset += 8
            }
            context.translateBy(x: 157, y: top + length - 1)
            context.rotate(by: .radians(0.083))
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 92, height: 68), cornerRadius: 8.5),
                with: .color(Color(red: 111 / 255, green: 106 / 255, blue: 98 / 255)))
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
