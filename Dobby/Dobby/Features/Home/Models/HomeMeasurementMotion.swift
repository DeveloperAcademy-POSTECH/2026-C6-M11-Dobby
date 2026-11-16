import Foundation

/// An immutable handoff from the home gesture to the capture presentation.
/// `pull` uses the prototype's 402pt-wide coordinate space, not device pixels.
nonisolated struct HomeMeasurementTransitionSeed: Equatable, Sendable {
    let pull: CGFloat
    let canvasSize: CGSize

    init(pull: CGFloat, canvasSize: CGSize) {
        self.pull = HomeMeasurementMotion.clampedPull(pull)
        self.canvasSize = canvasSize
    }
}

/// All lengths in a pose are actual canvas points. Time/rotation stay unscaled.
nonisolated struct HomeMeasurementTransitionPose: Equatable, Sendable {
    let scale: CGFloat
    let pull: CGFloat
    let follow: CGFloat
    let drop: CGFloat
    let bodyCenter: CGPoint
    let bodyDiameter: CGFloat
    let bodyRotationRadians: Double
    let homeOpacity: Double
    let homeDrift: CGFloat
    let guideMaskOpaqueEnd: CGFloat
    let guideMaskTransparentEnd: CGFloat
    let isComplete: Bool
}

/// The supplied Chak prototype is 804×1748px, exactly twice this reference.
/// Keep the analytic curves instead of substituting a spring or ease-in-out.
nonisolated enum HomeMeasurementMotion {
    static let referenceSize = CGSize(width: 402, height: 874)
    static let maximumPull: CGFloat = 270
    static let commitThreshold: CGFloat = 87.5
    static let idleDuration: TimeInterval = 2.0
    static let transitionDuration: TimeInterval = 0.65
    static let returnDuration: TimeInterval = 0.25
    static let accessiblePullDuration: TimeInterval = 0.30
    static let accessiblePullDistance: CGFloat = 100

    static func clampedPull(_ pull: CGFloat) -> CGFloat {
        guard pull.isFinite else { return 0 }
        return min(maximumPull, max(0, pull))
    }

    static func normalizedPull(translation: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        guard canvasWidth.isFinite, canvasWidth > 0 else { return 0 }
        return clampedPull(translation / (canvasWidth / referenceSize.width))
    }

    static func shouldCommit(pull: CGFloat) -> Bool {
        clampedPull(pull) >= commitThreshold
    }

    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value.isFinite ? value : 0))
        return t * t * (3 - 2 * t)
    }

    static func idleArrowOffset(elapsed: TimeInterval, reducedMotion: Bool = false) -> CGFloat {
        guard !reducedMotion, elapsed.isFinite else { return 0 }
        let keys: [(Double, Double)] = [
            (0, 0), (0.05, 0), (0.10, 5), (0.15, 12), (0.20, 13.5),
            // Shorten only the hold by 250ms so the movement stays gentle.
            (0.30, 9), (0.45, 10.5), (0.60, 10), (1.60, 10),
            (1.70, -1), (1.80, 0), (idleDuration, 0)
        ]
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: idleDuration)
        for index in 1..<keys.count where phase < keys[index].0 {
            let (start, from) = keys[index - 1]
            let (end, to) = keys[index]
            return CGFloat(from + (to - from) * (phase - start) / (end - start))
        }
        return 0
    }

    static func pose(seed: HomeMeasurementTransitionSeed, progress: Double) -> HomeMeasurementTransitionPose {
        let size = seed.canvasSize
        let scale = max(0, size.width.isFinite ? size.width / referenceSize.width : 0)
        let t = min(1, max(0, progress.isFinite ? progress : 0))
        let enter = smooth(t)
        let pull = clampedPull(seed.pull)
        let follow = max(0, pull - 22.5) * 0.24
        let drop = follow + (1225 - follow) * CGFloat(pow(t, 1.45))
        let centerY = -17 + drop
        let radius: CGFloat = 302
        let sideUpperEdge = centerY - sqrt(radius * radius - 201 * 201)
        let height = scale > 0 && size.height.isFinite ? max(0, size.height / scale) : referenceSize.height
        let edge = max((height + 22) * CGFloat(smooth((t - 0.27) / 0.63)), sideUpperEdge + 23)
        return HomeMeasurementTransitionPose(scale: scale, pull: pull * scale,
            follow: follow * scale, drop: drop * scale,
            bodyCenter: CGPoint(x: 201 * scale, y: centerY * scale),
            bodyDiameter: 604 * scale, bodyRotationRadians: -0.215 * enter,
            homeOpacity: 1 - smooth(Double(pull / 125) + t * 1.4),
            homeDrift: 15 * CGFloat(enter) * scale,
            // The mask is disabled at t=0. Once visible, opacity decreases over
            // 25pt, with the circle's side edge preventing exposed home gaps.
            guideMaskOpaqueEnd: (edge - 22) * scale,
            guideMaskTransparentEnd: (edge + 3) * scale,
            isComplete: t >= 1)
    }
}
