import CoreGraphics
import Foundation

/// An immutable handoff from the home gesture to the capture presentation.
/// `pull` uses the prototype's 402pt-wide coordinate space, not device pixels.
nonisolated struct HomeMeasurementTransitionSeed: Equatable, Sendable {
    let pull: CGFloat
    let canvasSize: CGSize
    let artworkWidth: CGFloat
    let bottomChromeTop: CGFloat?
    let tapeLead: CGFloat

    init(pull: CGFloat, canvasSize: CGSize, artworkWidth: CGFloat? = nil,
         bottomChromeTop: CGFloat? = nil, tapeLead: CGFloat = 0) {
        self.pull = HomeMeasurementMotion.clampedPull(pull)
        self.canvasSize = canvasSize
        self.artworkWidth = artworkWidth ?? canvasSize.width
        self.bottomChromeTop = bottomChromeTop
        self.tapeLead = tapeLead.isFinite ? min(HomeMeasurementMotion.idleTapePullDistance, max(0, tapeLead)) : 0
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
    let guideRevealOpacity: Double
    let tape: HomeMeasurementTapeGeometry
    let isComplete: Bool
}

/// Canvas-space geometry shared by the gesture and the presentation. The white
/// ribbon always has parallel edges; the fold is painted inside that ribbon.
nonisolated struct HomeMeasurementTapeGeometry: Equatable, Sendable {
    let capCenter: CGPoint
    let capAngleRadians: Double
    let capSize: CGSize
    let leftJoin: CGPoint
    let rightJoin: CGPoint
    let leftTop: CGPoint
    let rightTop: CGPoint
    let axis: CGPoint
    let normal: CGPoint
    let width: CGFloat
    let shadowTip: CGPoint
    let shadowOuter: CGPoint
    let shadowInner: CGPoint
    let shadowOpacity: Double
    let shadowVisibleLength: CGFloat
}

/// The supplied Chak prototype is 804×1748px, exactly twice this reference.
/// Keep the analytic curves instead of substituting a spring or ease-in-out.
nonisolated enum HomeMeasurementMotion {
    static let referenceSize = CGSize(width: 402, height: 874)
    // Keep the wordmark visible and leave room for the strip's idle pull above
    // the native guidance/snapshot boundary.
    static let restingVerticalOffset: CGFloat = 86
    static let maximumPull: CGFloat = 140
    static let commitThreshold: CGFloat = 87.5
    static let idleDuration: TimeInterval = 2.0
    static let idleTapePullDistance: CGFloat = 8
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

    /// Zero velocity and acceleration at both ends prevents a crease popping
    /// when the fold starts retracting or finally disappears into the reel.
    static func smoother(_ value: Double) -> Double {
        let t = min(1, max(0, value.isFinite ? value : 0))
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    static func idleTapeOffset(elapsed: TimeInterval, reducedMotion: Bool = false) -> CGFloat {
        guard !reducedMotion, elapsed.isFinite else { return 0 }
        let keys: [(Double, Double)] = [
            (0, 0), (0.30, 0), (0.62, Double(idleTapePullDistance)),
            (0.90, 0), (1.10, 3), (1.32, 0), (idleDuration, 0)
        ]
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: idleDuration)
        for index in 1..<keys.count where phase < keys[index].0 {
            let (start, from) = keys[index - 1]
            let (end, to) = keys[index]
            return CGFloat(from + (to - from) * smoother((phase - start) / (end - start)))
        }
        return 0
    }

    static func pose(seed: HomeMeasurementTransitionSeed, progress: Double) -> HomeMeasurementTransitionPose {
        let size = seed.canvasSize
        let scale = max(0, seed.artworkWidth.isFinite ? seed.artworkWidth / referenceSize.width : 0)
        let t = min(1, max(0, progress.isFinite ? progress : 0))
        let pull = clampedPull(seed.pull)
        let height = scale > 0 && size.height.isFinite ? max(0, size.height / scale) : referenceSize.height
        // Only the strip moves under the finger. The reel stays high enough to
        // cover the top corners until the released assembly begins its wipe.
        let follow: CGFloat = 0
        let diameter = referenceSize.width * 1.12
        let radius = diameter / 2
        let idleCenterY: CGFloat = -8.5 + restingVerticalOffset
        let idleCapY: CGFloat = 352.445 + restingVerticalOffset
        let finalDrop = height + radius + 24 - idleCenterY
        let drop = follow + (finalDrop - follow) * CGFloat(pow(t, 1.45))
        let centerX = scale > 0 && size.width.isFinite ? max(0, size.width) / (2 * scale) : 201
        let center = CGPoint(x: centerX, y: idleCenterY + drop)
        let flattenAtRelease = smoother(Double((pull - 100) / 170)) * 0.6
        let flatten = flattenAtRelease + (1 - flattenAtRelease) * smoother(t / 0.65)
        let angle = (6.74 + (1.48 - 6.74) * flatten) * .pi / 180
        // The final pull unrolls another ~2cm before the whole assembly exits.
        // Extra length belongs to the ribbon, rather than separating its cap.
        let extensionLength = 56 * CGFloat(smoother(t / 0.65))
        let capCenter = CGPoint(x: centerX - 7.45,
            y: idleCapY + seed.tapeLead + pull + (drop - follow) + extensionLength)
        let releaseAngle = (6.74 + (1.48 - 6.74) * flattenAtRelease) * .pi / 180
        let releaseCap = CGPoint(x: centerX - 7.45, y: idleCapY + seed.tapeLead + pull)
        let releaseCenter = CGPoint(x: centerX, y: idleCenterY + follow)
        let initialShadowLength = naturalShadowLength(cap: releaseCap, angle: releaseAngle,
            center: releaseCenter, radius: radius)
        let tape = tapeGeometry(cap: capCenter, angle: angle, center: center,
            radius: radius, initialShadowLength: initialShadowLength, progress: t, scale: scale)
        return HomeMeasurementTransitionPose(scale: scale, pull: pull * scale,
            follow: follow * scale, drop: drop * scale,
            bodyCenter: scaled(center, by: scale),
            bodyDiameter: radius * 2 * scale, bodyRotationRadians: 0,
            homeOpacity: 1 - smooth(Double(pull / 125) + t * 1.4),
            homeDrift: 15 * CGFloat(smooth(t)) * scale,
            guideRevealOpacity: smooth(t / 0.14), tape: tape,
            isComplete: t >= 1)
    }

    private static func tapeGeometry(cap: CGPoint, angle: Double, center: CGPoint,
        radius: CGFloat, initialShadowLength: CGFloat, progress: Double, scale: CGFloat
    ) -> HomeMeasurementTapeGeometry {
        let normal = CGPoint(x: cos(angle), y: sin(angle))
        let axis = CGPoint(x: sin(angle), y: -cos(angle))
        let left = point(cap, along: normal, distance: -42, axis: axis, rise: 26)
        let right = point(cap, along: normal, distance: 42, axis: axis, rise: 26)
        let boundary = intersectionDistance(from: right, along: axis, center: center, radius: radius)
        let top = max(boundary,
            intersectionDistance(from: left, along: axis, center: center, radius: radius)) + 64
        let rollPhase = min(1, max(0, (progress - 0.08) / 0.66))
        let roll = CGFloat(smoother(rollPhase))
        let hiddenLength: CGFloat = 35
        let initialWidth: CGFloat = 21
        let width = initialWidth * (1 - 0.25 * roll)
        // Control visible shaded AREA, not height*width*opacity independently.
        // Most of the fold's width/color remains until its tip reaches the reel.
        let initialArea = initialWidth * initialShadowLength * initialShadowLength
            / (2 * (initialShadowLength + hiddenLength))
        let area = initialArea * (1 - roll)
        let k = 2 * area / width
        let length = (k + sqrt(k * k + 4 * k * hiddenLength)) / 2
        let shadowTip = point(right, along: axis, distance: boundary - length)
        let shadowOuter = point(right, along: axis, distance: boundary + hiddenLength)
        let shadowInner = point(shadowOuter, along: normal, distance: -width)
        return HomeMeasurementTapeGeometry(capCenter: scaled(cap, by: scale), capAngleRadians: angle,
            capSize: CGSize(width: 92 * scale, height: 68 * scale),
            leftJoin: scaled(left, by: scale), rightJoin: scaled(right, by: scale),
            leftTop: scaled(point(left, along: axis, distance: top), by: scale),
            rightTop: scaled(point(right, along: axis, distance: top), by: scale),
            axis: axis, normal: normal, width: 84 * scale,
            shadowTip: scaled(shadowTip, by: scale), shadowOuter: scaled(shadowOuter, by: scale),
            shadowInner: scaled(shadowInner, by: scale),
            shadowOpacity: 1 - smoother((rollPhase - 0.86) / 0.14),
            shadowVisibleLength: length * scale)
    }

    private static func naturalShadowLength(cap: CGPoint, angle: Double,
        center: CGPoint, radius: CGFloat
    ) -> CGFloat {
        let axis = CGPoint(x: sin(angle), y: -cos(angle))
        let normal = CGPoint(x: cos(angle), y: sin(angle))
        let right = point(cap, along: normal, distance: 42, axis: axis, rise: 26)
        let boundary = intersectionDistance(from: right, along: axis, center: center, radius: radius)
        let tipDistance = (center.y + radius + 61 - right.y) / axis.y
        return max(0, boundary - tipDistance)
    }

    private static func intersectionDistance(from point: CGPoint, along axis: CGPoint,
        center: CGPoint, radius: CGFloat
    ) -> CGFloat {
        let x = point.x - center.x, y = point.y - center.y
        let b = 2 * (x * axis.x + y * axis.y)
        let c = x * x + y * y - radius * radius
        let root = sqrt(max(0, b * b - 4 * c))
        let near = (-b - root) / 2
        let far = (-b + root) / 2
        return max(0, near >= 0 ? near : far)
    }

    private static func point(_ origin: CGPoint, along vector: CGPoint, distance: CGFloat,
        axis: CGPoint = .zero, rise: CGFloat = 0
    ) -> CGPoint {
        CGPoint(x: origin.x + vector.x * distance + axis.x * rise,
            y: origin.y + vector.y * distance + axis.y * rise)
    }

    private static func scaled(_ point: CGPoint, by scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }
}
