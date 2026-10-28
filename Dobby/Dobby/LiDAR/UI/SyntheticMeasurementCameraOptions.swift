import Foundation

/// An explicitly labelled UI fixture. No capture device or sensor receipt is
/// created here, and these controls cannot establish physical EV response.
@MainActor
final class SyntheticMeasurementCameraOptions {
    let options: DetailCameraOptions
    private let controller: SyntheticMeasurementExposureController

    init() {
        let controller = SyntheticMeasurementExposureController()
        self.controller = controller
        options = DetailCameraOptions(controller: controller)
    }

    func synchronize(exposure: Double, available: Bool, invalidatePendingRequests: Bool = false) {
        controller.exposure = exposure
        controller.available = available
        options.synchronizeExternalState(capabilities: controller.snapshot,
            invalidatePendingRequests: invalidatePendingRequests)
    }
}

@MainActor
private final class SyntheticMeasurementExposureController: DetailCameraControlling {
    var exposure = 0.0
    var available = false
    var snapshot: DetailCameraCapabilities {
        available ? .init(exposure: .init(minimum: -2, maximum: 2), exposureBias: exposure) : .init()
    }

    @MainActor func capabilities() async throws -> DetailCameraCapabilities { snapshot }

    @MainActor func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        try Task.checkCancellation()
        guard available else { throw DetailCameraControlFailure.unavailable }
        guard case .exposure(let value) = request else { throw DetailCameraControlFailure.unsupported }
        guard let accepted = snapshot.exposure?.clamped(value) else { throw DetailCameraControlFailure.invalidValue }
        exposure = accepted
        return accepted
    }
}
