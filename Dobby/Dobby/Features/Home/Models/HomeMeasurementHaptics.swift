import QuartzCore
import UIKit

/// One owner follows a home pull into its short capture transition. Call stop
/// before a cancelled pull resets, on app suspension, or when that session exits.
/// This produces impacts only: no audio, idle loop, or capture-timeline changes.
@MainActor
final class HomeMeasurementHaptics {
    private enum Phase { case idle, pulling, rolling }
    private struct Pulse {
        let offset: TimeInterval
        let intensity: CGFloat
    }

    // Finer distance detents make a slow pull feel like unwinding the scale;
    // the independent time limit still caps fast drags at 40 impacts/second.
    private static let pullSpacing: CGFloat = 3
    private static let minimumInterval: TimeInterval = 0.025
    private static let rollingPulses: [Pulse] = [
        .init(offset: 0, intensity: 1.0),
        .init(offset: 0.028, intensity: 0.94),
        .init(offset: 0.057, intensity: 0.90),
        .init(offset: 0.087, intensity: 0.85),
        .init(offset: 0.118, intensity: 0.81),
        .init(offset: 0.150, intensity: 0.76),
        .init(offset: 0.183, intensity: 0.71),
        .init(offset: 0.217, intensity: 0.66),
        .init(offset: 0.252, intensity: 0.61),
        .init(offset: 0.288, intensity: 0.56),
        .init(offset: 0.325, intensity: 0.51),
        .init(offset: 0.363, intensity: 0.46),
        .init(offset: 0.402, intensity: 0.41),
        .init(offset: 0.442, intensity: 0.36),
        .init(offset: 0.483, intensity: 0.32),
        .init(offset: 0.525, intensity: 0.28),
        .init(offset: 0.568, intensity: 0.24),
        .init(offset: 0.612, intensity: 0.20)
    ]

    private lazy var feedback = UIImpactFeedbackGenerator(style: .medium)
    private var phase = Phase.idle
    private var lastCrossedPull: CGFloat = 0
    private var lastImpactTime: CFTimeInterval = -.infinity
    private var generation: UInt64 = 0
    private var rollingTask: Task<Void, Never>?

    deinit { rollingTask?.cancel() }

    func startPull() {
        guard phase != .pulling else { return }
        stop()
        guard Self.supportsFeedback, UIApplication.shared.applicationState == .active else { return }
        phase = .pulling
        feedback.prepare()
    }

    /// The caller supplies the same 402pt reference distance as the motion seed.
    /// A fast move never queues impacts to play later while the finger is still.
    func updatePull(_ value: CGFloat) {
        guard phase == .pulling, value.isFinite else { return }
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        let pull = HomeMeasurementMotion.clampedPull(value)
        guard abs(pull - lastCrossedPull) >= Self.pullSpacing else { return }
        // Consume this crossing even when rate-limited. Identical/nearby input
        // cannot emit a delayed duplicate after the 25ms interval has elapsed.
        lastCrossedPull = pull
        emit(intensity: 0.80)
    }

    /// Commit once per gesture. The independent rolling tail ends within 650ms,
    /// even when a recent pull impact delays its first pulse by up to 25ms.
    func finishPull() {
        guard phase == .pulling else { return }
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        phase = .rolling
        generation &+= 1
        let token = generation
        let start = CACurrentMediaTime()
        let firstDelay = max(0, Self.minimumInterval - (start - lastImpactTime))
        feedback.prepare()
        rollingTask = Task { @MainActor [weak self] in
            defer { self?.completeTail(generation: token) }
            for pulse in Self.rollingPulses {
                let target = start + firstDelay + pulse.offset
                let delay = max(0, target - CACurrentMediaTime())
                do {
                    try Task.checkCancellation()
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                } catch { return }
                guard let self, self.generation == token, self.phase == .rolling else { return }
                let now = CACurrentMediaTime()
                guard now - start < HomeMeasurementMotion.transitionDuration else { return }
                // Skip overdue pulses after a busy main-thread interval rather
                // than catching up with a burst or replaying the initial impact.
                guard now - target <= Self.minimumInterval else { continue }
                self.emit(intensity: pulse.intensity)
            }
        }
    }

    func stop() {
        generation &+= 1
        rollingTask?.cancel()
        rollingTask = nil
        phase = .idle
        lastCrossedPull = 0
        // Keep the hardware rate limit across stop/start of adjacent gestures.
    }

    private func emit(intensity: CGFloat) {
        guard Self.supportsFeedback else { return }
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        let now = CACurrentMediaTime()
        guard now - lastImpactTime >= Self.minimumInterval else { return }
        lastImpactTime = now
        feedback.impactOccurred(intensity: intensity)
        feedback.prepare()
    }

    private func completeTail(generation token: UInt64) {
        guard generation == token, phase == .rolling else { return }
        rollingTask = nil
        phase = .idle
    }

    private static var supportsFeedback: Bool {
#if targetEnvironment(simulator)
        false
#else
        true // UIKit safely ignores impacts on devices without a Taptic Engine.
#endif
    }
}
