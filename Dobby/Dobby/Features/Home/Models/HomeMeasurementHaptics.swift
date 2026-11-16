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

    private static let pullSpacing: CGFloat = 6
    private static let minimumInterval: TimeInterval = 0.035
    private static let rollingPulses: [Pulse] = [
        .init(offset: 0, intensity: 1.0),
        .init(offset: 0.040, intensity: 0.92),
        .init(offset: 0.085, intensity: 0.84),
        .init(offset: 0.135, intensity: 0.76),
        .init(offset: 0.190, intensity: 0.68),
        .init(offset: 0.250, intensity: 0.60),
        .init(offset: 0.315, intensity: 0.52),
        .init(offset: 0.385, intensity: 0.43),
        .init(offset: 0.460, intensity: 0.33),
        .init(offset: 0.540, intensity: 0.22)
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
        // cannot emit a delayed duplicate after the 35ms interval has elapsed.
        lastCrossedPull = pull
        emit(intensity: 0.80)
    }

    /// Commit once per gesture. The independent rolling tail ends within 650ms,
    /// even when a recent pull impact delays its first pulse by up to 35ms.
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
