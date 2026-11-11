import SwiftUI

/// A stage illustration, rather than an estimate of the work remaining.
struct MeasurementProcessingIndicator: View {
    let phase: AutomaticMeasurementPhase
    var forceReduceMotion = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = MeasurementProcessingMotion.holding(0)

    private var usesReducedMotion: Bool { reduceMotion || forceReduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))

            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 67, height: 67)

            // Only this small drawing subtree ticks; no capture or inference
            // state is written on a frame, and removal leaves no async work.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                paused: usesReducedMotion || !phase.isProcessingIndicatorActive)) { context in
                MeasurementProcessingArc(progress: motion.sample(at: context.date).progress)
                    .stroke(Color(red: 243 / 255, green: 77 / 255, blue: 38 / 255),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            Circle()
                .fill(Color(red: 224 / 255, green: 90 / 255, blue: 61 / 255))
                .frame(width: 25, height: 25)
        }
        // Keep the occupied bounds aligned with the shared 98pt shutter while
        // preserving the processing ring's existing animation and dimensions.
        .frame(width: 98, height: 98)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.processingIndicatorLabel)
        .accessibilityIdentifier("measurementProcessingIndicator")
        .onAppear { updateMotion() }
        .onChange(of: phase) { _, _ in updateMotion() }
        .onChange(of: usesReducedMotion) { _, _ in updateMotion() }
        .transaction { transaction in
            if usesReducedMotion || phase != .completed {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private func updateMotion() {
        let now = Date()
        let current = motion.sample(at: now)

        if phase == .completed {
            // The owner supplies this only after preparing the result, then
            // retains the view long enough for this finite closing animation.
            withAnimation(usesReducedMotion ? nil : .linear(duration: 0.26)) {
                motion = .holding(1)
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if usesReducedMotion {
                    motion = .holding(max(current.progress, phase.processingIndicatorStaticProgress))
                } else if phase.isProcessingIndicatorActive {
                    motion = MeasurementProcessingMotion(
                        anchor: now,
                        start: current.progress,
                        ceiling: max(current.progress, phase.processingIndicatorCeiling),
                        initialVelocity: current.velocity,
                        rate: phase.processingIndicatorRate)
                } else {
                    motion = .holding(current.progress)
                }
            }
        }
    }
}

private struct MeasurementProcessingArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fraction = min(1, max(0, progress))
        guard fraction > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 33.5
        var path = Path()
        if fraction == 1 {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2))
        } else {
            path.addArc(center: center, radius: radius,
                startAngle: .degrees(-90), endAngle: .degrees(-90 + fraction * 360),
                clockwise: false)
        }
        return path
    }
}

/// A bounded critically damped curve preserves both position and velocity when
/// a new stage arrives. Its ceiling stays below one until explicit completion.
private struct MeasurementProcessingMotion {
    var anchor: Date
    var start: Double
    var ceiling: Double
    var initialVelocity: Double
    var rate: Double

    static func holding(_ progress: Double) -> Self {
        .init(anchor: Date(), start: progress, ceiling: progress, initialVelocity: 0, rate: 1)
    }

    func sample(at date: Date) -> (progress: Double, velocity: Double) {
        let gap = ceiling - start
        guard gap > 0 else { return (start, 0) }
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let damping = max(rate, initialVelocity / gap)
        let slope = damping * gap - initialVelocity
        let decay = exp(-damping * elapsed)
        let progress = ceiling - (gap + slope * elapsed) * decay
        let velocity = (initialVelocity + damping * slope * elapsed) * decay
        return (min(ceiling, max(start, progress)), max(0, velocity))
    }
}

private extension AutomaticMeasurementPhase {
    var isProcessingIndicatorActive: Bool {
        switch self {
        case .idle, .capturing, .detectingLandmarks, .measuring: true
        case .completed, .failed, .cancelled: false
        }
    }

    var processingIndicatorCeiling: Double {
        switch self {
        case .idle, .capturing: 0.28
        case .detectingLandmarks: 0.74
        case .measuring: 0.94
        case .completed: 1
        case .failed, .cancelled: 0
        }
    }

    var processingIndicatorStaticProgress: Double {
        switch self {
        case .idle, .capturing: 0.12
        case .detectingLandmarks: 0.46
        case .measuring: 0.8
        case .completed: 1
        case .failed, .cancelled: 0
        }
    }

    var processingIndicatorRate: Double {
        switch self {
        case .idle, .capturing: 3
        case .detectingLandmarks: 1.4
        case .measuring: 1.2
        case .completed, .failed, .cancelled: 1
        }
    }

    var processingIndicatorLabel: String {
        switch self {
        case .idle, .capturing: "사진 준비 중"
        case .detectingLandmarks: "측정점 확인 중"
        case .measuring: "길이 계산 중"
        case .completed: "처리 완료"
        case .failed: "처리 실패"
        case .cancelled: "처리 취소"
        }
    }
}
