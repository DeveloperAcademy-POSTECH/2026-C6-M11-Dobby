import Foundation

/// An exposure-only view of the ARKit camera. Zoom remains registered with
/// RGB, depth and calibration in the measurement capture provider.
nonisolated struct LiDARDetailCameraSnapshot: Equatable, Sendable {
    var sessionID: UUID?
    var externalRevision: UInt64
    var capabilities: DetailCameraCapabilities

    static let unavailable = Self(sessionID: nil, externalRevision: 0, capabilities: .init())
}

@MainActor
protocol LiDARDetailCameraSource: AnyObject {
    var detailCameraSnapshot: LiDARDetailCameraSnapshot { get }
    /// Returns an accepted hardware receipt, not the requested UI value.
    func applyDetailExposureBias(_ bias: Double) async throws -> Double
}

/// Reuses Mason's option panels while retaining ARKit's camera ownership.
/// No AVCaptureSession, replacement camera or device zoom is created here.
@MainActor
final class LiDARDetailCameraControls: DetailCameraControlling {
    private weak var camera: (any LiDARDetailCameraSource)?

    init(camera: any LiDARDetailCameraSource) { self.camera = camera }

    @MainActor
    func capabilities() async throws -> DetailCameraCapabilities {
        try Task.checkCancellation()
        return camera?.detailCameraSnapshot.capabilities ?? .init()
    }

    @MainActor
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        try Task.checkCancellation()
        guard case .exposure(let bias) = request else { throw DetailCameraControlFailure.unsupported }
        guard bias.isFinite else { throw DetailCameraControlFailure.invalidValue }
        guard let camera else { throw DetailCameraControlFailure.unavailable }
        let initial = camera.detailCameraSnapshot
        guard let sessionID = initial.sessionID, let range = initial.capabilities.exposure,
              let target = range.clamped(bias) else { throw DetailCameraControlFailure.unavailable }
        let applied: Double
        do { applied = try await camera.applyDetailExposureBias(target) }
        catch let error as CameraHardwareControlError {
            switch error {
            case .superseded: throw CancellationError()
            case .invalidInput: throw DetailCameraControlFailure.invalidValue
            case .busy: throw DetailCameraControlFailure.operationInProgress
            case .staleSession, .unavailable: throw DetailCameraControlFailure.unavailable
            default: throw DetailCameraControlFailure.deviceFailure
            }
        }
        try Task.checkCancellation()
        let current = camera.detailCameraSnapshot
        guard current.sessionID == sessionID, current.capabilities.exposure != nil else {
            throw DetailCameraControlFailure.unavailable
        }
        // A subsequent tap (EV 0) or preview drag owns the newer intent. A
        // delayed menu receipt must never restore the preceding menu value.
        guard current.externalRevision == initial.externalRevision else { throw CancellationError() }
        guard applied.isFinite, range.clamped(applied) == applied,
              current.capabilities.exposure?.clamped(applied) == applied else {
            throw DetailCameraControlFailure.deviceFailure
        }
        return applied
    }
}
