import SwiftUI
import UIKit

/// The guide is constructed once, remains mounted throughout the transition,
/// and stays in its final layout behind Home. Only the reel and Home cover
/// move after release to reveal the real capture screen.
struct HomeMeasurementTransitionOverlay<Guide: View>: View, Animatable {
    let snapshot: UIImage?
    var seed: HomeMeasurementTransitionSeed
    var progress: Double
    let showsCover: Bool
    private let guide: Guide

    init(snapshot: UIImage?, seed: HomeMeasurementTransitionSeed, progress: Double,
         showsCover: Bool = true,
         @ViewBuilder guide: () -> Guide) {
        self.snapshot = snapshot
        self.seed = seed
        self.progress = progress
        self.showsCover = showsCover
        self.guide = guide()
    }

    var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(seed.pull, seed.tapeLead)) }
        set {
            progress = newValue.first
            seed = HomeMeasurementTransitionSeed(pull: newValue.second.first,
                canvasSize: seed.canvasSize, artworkWidth: seed.artworkWidth,
                bottomChromeTop: seed.bottomChromeTop, tapeLead: newValue.second.second)
        }
    }

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        guide
            .ignoresSafeArea()
            .environment(\.measurementCaptureCover,
                showsCover ? MeasurementCaptureCover(center: pose.bodyCenter, diameter: pose.bodyDiameter,
                    revealOpacity: pose.guideRevealOpacity) : nil)
            .overlay {
                if showsCover {
                    GeometryReader { geometry in
                        let origin = geometry.frame(in: .global).origin
                        ZStack(alignment: .topLeading) {
                            HomeMeasurementHomeCover(snapshot: snapshot, seed: seed, progress: progress)
                                .mask {
                                    HomeMeasurementCoverMask(seed: seed, progress: progress)
                                }
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
}

private struct HomeMeasurementHomeCover: View {
    let snapshot: UIImage?
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        let lowerTop = 494 * pose.scale
        let chromeTop = seed.bottomChromeTop ?? max(lowerTop, seed.canvasSize.height - 130 * pose.scale)
        ZStack(alignment: .topLeading) {
            Color("BrandNeutral50")
            if let snapshot {
                // The supplied home PNGs are references only. Keep the real
                // current card, fonts, thumbnail and native tab bar from the window.
                Image(uiImage: snapshot).resizable()
                    .frame(width: seed.canvasSize.width, height: seed.canvasSize.height)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(height: max(0, chromeTop - lowerTop))
                            .offset(y: lowerTop)
                    }
                    .offset(y: pose.homeDrift)
                    .opacity(pose.homeOpacity)
                // The live TabView does not fade during a pull. Keep its actual
                // chrome fixed until the round wipe passes, including safe area.
                Image(uiImage: snapshot).resizable()
                    .frame(width: seed.canvasSize.width, height: seed.canvasSize.height)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(height: max(0, seed.canvasSize.height - chromeTop))
                            .offset(y: chromeTop)
                    }
            }
            HomeMeasurementTapeArtwork(seed: seed, progress: progress)
        }
        .frame(width: seed.canvasSize.width, height: seed.canvasSize.height)
    }
}

/// Reveal the real guide in the round reel's wake. The lower home cover and
/// circle overlap, so no horizontal seam cuts through the circular silhouette.
private struct HomeMeasurementCoverMask: View {
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        Canvas { context, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            if !pose.isComplete {
                // A held pull always keeps the complete Home screen opaque.
                // Only release progress opens the round wipe onto capture.
                context.fill(bounds, with: .color(.white.opacity(1 - pose.guideRevealOpacity)))
                let radius = pose.bodyDiameter / 2
                context.fill(Path(ellipseIn: CGRect(x: pose.bodyCenter.x - radius,
                    y: pose.bodyCenter.y - radius, width: pose.bodyDiameter,
                    height: pose.bodyDiameter)), with: .color(.white))
                let lowerTop = max(0, pose.bodyCenter.y)
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

/// The cap, ticks and parallel ribbon share one basis. The folded gray face is
/// clipped inside the white face and retracts up its straight right-hand edge.
struct HomeMeasurementTapeArtwork: View {
    let seed: HomeMeasurementTransitionSeed
    let progress: Double

    var body: some View {
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
        Canvas { context, _ in
            guard pose.scale > 0 else { return }
            let tape = pose.tape
            var ribbon = Path()
            ribbon.addLines([tape.leftJoin, tape.rightJoin, tape.rightTop, tape.leftTop])
            ribbon.closeSubpath()
            context.fill(ribbon, with: .color(Color("BrandNeutral200")))
            var face = context
            face.clip(to: ribbon)
            fill(&face, color: Color("BrandNeutral400").opacity(tape.shadowOpacity),
                points: [tape.shadowTip, tape.shadowOuter, tape.shadowInner])
            let length = hypot(tape.leftTop.x - tape.leftJoin.x, tape.leftTop.y - tape.leftJoin.y)
            var offset = 9 * pose.scale
            var index = 0
            while offset < length {
                let start = CGPoint(x: tape.leftJoin.x + tape.axis.x * offset,
                    y: tape.leftJoin.y + tape.axis.y * offset)
                let width: CGFloat = (index % 5 == 0 ? 29 : 17) * pose.scale
                var tick = Path()
                tick.move(to: start)
                tick.addLine(to: CGPoint(x: start.x + tape.normal.x * width,
                    y: start.y + tape.normal.y * width))
                face.stroke(tick, with: .color(.black), lineWidth: pose.scale)
                offset += 8 * pose.scale
                index += 1
            }
            context.translateBy(x: tape.capCenter.x, y: tape.capCenter.y)
            context.rotate(by: .radians(tape.capAngleRadians))
            context.fill(Path(roundedRect: CGRect(x: -tape.capSize.width / 2,
                y: -tape.capSize.height / 2, width: tape.capSize.width, height: tape.capSize.height),
                cornerRadius: 8 * pose.scale),
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
