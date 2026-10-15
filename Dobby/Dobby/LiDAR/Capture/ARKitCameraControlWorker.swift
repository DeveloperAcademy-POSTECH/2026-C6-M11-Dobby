import AVFoundation
import Foundation

nonisolated enum CameraHardwareControlError: LocalizedError, Sendable {
    case unavailable, busy, invalidInput, staleSession, configuration(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "이 카메라에서 해당 설정을 지원하지 않아요."
        case .busy: "촬영 중에는 카메라 설정을 바꿀 수 없어요."
        case .invalidInput: "카메라 설정값을 확인해 주세요."
        case .staleSession: "카메라가 다시 시작되었어요. 다시 조절해 주세요."
        case .configuration(let reason): "카메라 설정을 적용하지 못했어요. \(reason)"
        }
    }
}

nonisolated struct CameraHardwareReceipt: Sendable {
    var revision: UInt64
    var focusPoint: ImagePoint?
    var exposureBias: Double
}

/// The ARKit-owned primary device is the only device this worker configures.
/// Its serial queue owns all mutable state and short configuration locks.
nonisolated final class ARKitCameraControlWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dobby.lidar.camera-controls", qos: .userInitiated)
    private var sessionID: UUID?
    private var device: AVCaptureDevice?
    private var captureActive = false
    private var receipt = CameraHardwareReceipt(revision: 0, focusPoint: nil, exposureBias: 0)

    func activate(sessionID: UUID, device: AVCaptureDevice?, exposureBias: Double) async -> CameraControlCapabilities {
        await withCheckedContinuation { continuation in
            queue.async {
                self.sessionID = sessionID
                self.device = device
                self.captureActive = false
                self.receipt = .init(revision: 0, focusPoint: nil, exposureBias: 0)
                guard let device else { continuation.resume(returning: .unavailable); return }
                let range = device.isExposureModeSupported(.continuousAutoExposure)
                    ? CameraExposureRange(minimum: Double(device.minExposureTargetBias),
                                          maximum: Double(device.maxExposureTargetBias)) : nil
                let focusSupported = device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus)
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = .init(x: 0.5, y: 0.5) }
                        device.focusMode = .continuousAutoFocus
                    }
                    if let target = range?.clamp(exposureBias) {
                        device.exposureMode = .continuousAutoExposure
                        device.setExposureTargetBias(Float(target), completionHandler: nil)
                        self.receipt.exposureBias = target
                    }
                    continuation.resume(returning: .init(focusSupported: focusSupported, exposureRange: range,
                                                          availableZooms: [.standard]))
                } catch {
                    // Failure to restore a control must never disable capture.
                    self.device = nil
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func deactivate() {
        queue.async { self.sessionID = nil; self.device = nil; self.captureActive = false }
    }

    func focus(at point: ImagePoint, sessionID: UUID) async throws -> CameraHardwareReceipt {
        try await perform(sessionID: sessionID) { device in
            guard point.isValid else { throw CameraHardwareControlError.invalidInput }
            guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else {
                throw CameraHardwareControlError.unavailable
            }
            // Sensor coordinates are landscape-right, independent of UI rotation.
            device.focusPointOfInterest = .init(x: point.x, y: point.y)
            device.focusMode = .autoFocus
            self.receipt.focusPoint = point
        }
    }

    /// Enqueue immediately from the UI action so a following shutter barrier
    /// cannot overtake a focus command waiting for a Swift task to be scheduled.
    func submitFocus(at point: ImagePoint, sessionID: UUID,
                     completion: @escaping @Sendable (Result<CameraHardwareReceipt, Error>) -> Void) {
        enqueue(sessionID: sessionID, operation: { device in
            guard point.isValid else { throw CameraHardwareControlError.invalidInput }
            guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else {
                throw CameraHardwareControlError.unavailable
            }
            device.focusPointOfInterest = .init(x: point.x, y: point.y)
            device.focusMode = .autoFocus
            self.receipt.focusPoint = point
        }, completion: completion)
    }

    func submitExposure(_ bias: Double, sessionID: UUID,
                        completion: @escaping @Sendable (Result<CameraHardwareReceipt, Error>) -> Void) {
        enqueue(sessionID: sessionID, operation: { device in
            guard device.isExposureModeSupported(.continuousAutoExposure),
                  let range = CameraExposureRange(minimum: Double(device.minExposureTargetBias),
                                                   maximum: Double(device.maxExposureTargetBias)),
                  let target = range.clamp(bias) else { throw CameraHardwareControlError.invalidInput }
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(Float(target), completionHandler: nil)
            self.receipt.exposureBias = target
        }, completion: completion)
    }

    func exposure(_ bias: Double, sessionID: UUID) async throws -> CameraHardwareReceipt {
        try await perform(sessionID: sessionID) { device in
            guard device.isExposureModeSupported(.continuousAutoExposure),
                  let range = CameraExposureRange(minimum: Double(device.minExposureTargetBias),
                                                   maximum: Double(device.maxExposureTargetBias)),
                  let target = range.clamp(bias) else { throw CameraHardwareControlError.invalidInput }
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(Float(target), completionHandler: nil)
            self.receipt.exposureBias = target
        }
    }

    /// A queue barrier drains accepted commands before snapshot selection. It
    /// never waits for AF/AE to settle and never depends on garment recognition.
    func beginCapture(sessionID: UUID) async throws -> CameraHardwareReceipt {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.sessionID == sessionID else {
                    continuation.resume(throwing: CameraHardwareControlError.staleSession); return
                }
                self.captureActive = true
                continuation.resume(returning: self.receipt)
            }
        }
    }

    func endCapture(sessionID: UUID) {
        queue.async { if self.sessionID == sessionID { self.captureActive = false } }
    }

    private func perform(sessionID: UUID,
                         operation: @escaping @Sendable (AVCaptureDevice) throws -> Void) async throws -> CameraHardwareReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(sessionID: sessionID, operation: operation) { continuation.resume(with: $0) }
        }
    }

    private func enqueue(sessionID: UUID, operation: @escaping @Sendable (AVCaptureDevice) throws -> Void,
                         completion: @escaping @Sendable (Result<CameraHardwareReceipt, Error>) -> Void) {
            queue.async {
                guard self.sessionID == sessionID else {
                    completion(.failure(CameraHardwareControlError.staleSession)); return
                }
                guard !self.captureActive else { completion(.failure(CameraHardwareControlError.busy)); return }
                guard let device = self.device else { completion(.failure(CameraHardwareControlError.unavailable)); return }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    try operation(device)
                    self.receipt.revision &+= 1
                    completion(.success(self.receipt))
                } catch {
                    completion(.failure(error))
                }
            }
    }
}
