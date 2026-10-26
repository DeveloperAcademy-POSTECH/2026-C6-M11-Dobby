import Combine
import CoreMotion
import Foundation

/// Advisory presentation only. Neither recognition nor the shutter waits for
/// this sensor, and its gravity values never enter measurement calculations.
@MainActor
final class GarmentCameraLevelGuide: ObservableObject {
    @Published private(set) var needsLevelAdvice = false
    private let motion = CMMotionManager()
    private var generation = UUID()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        generation = UUID()
        let token = generation
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let sample else { return }
            let alignment = abs(sample.gravity.z)
            Task { @MainActor [weak self] in
                guard let self, generation == token, motion.isDeviceMotionActive else { return }
                // Hysteresis keeps the cue from flickering near its boundary.
                let needsAdvice = needsLevelAdvice ? alignment < 0.95 : alignment < 0.90
                if needsLevelAdvice != needsAdvice { needsLevelAdvice = needsAdvice }
            }
        }
    }

    func stop() {
        generation = UUID()
        motion.stopDeviceMotionUpdates()
        needsLevelAdvice = false
    }
}
