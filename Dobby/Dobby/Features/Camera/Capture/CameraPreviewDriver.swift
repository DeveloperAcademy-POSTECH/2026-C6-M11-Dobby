//
//  CameraPreviewDriver.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation

/// Capture 폴더 담당: mason. 가변 세션·출력·delegate 보관은 이 직렬 큐에서만 다룬다.
/// @unchecked Sendable은 큐 소유권에 한정한다. UI는 session을 레이어에 연결만 한다.
nonisolated final class CameraPreviewDriver: DetailCameraControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.dobby.camera.detail-preview", qos: .userInitiated)
    private var pending: [UUID: CameraPhotoRequest] = [:]
    private let exposureCompletion = DetailExposureCompletion()

    func setRunning(_ active: Bool, completion: @escaping @Sendable (CameraPreviewSession.State) -> Void) {
        queue.async { [self] in
            exposureCompletion.cancel()
            if active {
                completion(start())
            } else {
                pending.values.forEach { $0.resolve(.failure(CancellationError())) }
                // 일시 중단 상태에서도 자동 재개 요청이 남지 않도록 중지한다.
                session.stopRunning()
                completion(.stopped)
            }
        }
    }

    func cancelCapture() {
        queue.async { [self] in
            exposureCompletion.cancel()
            pending.values.forEach { $0.resolve(.failure(CancellationError())) }
        }
    }

    func capture(rotationAngle: CGFloat) async throws -> Data {
        let id = UUID()
        // 화면이 닫혀도 최종 콜백까지 driver/delegate를 유지하고 pending 제거로 순환 참조를 끊는다.
        let request = CameraPhotoRequest { [self] in
            queue.async { self.pending[id] = nil }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                queue.async { [self] in
                    guard !request.isResolved else { return }
                    guard pending.isEmpty, !exposureCompletion.isPending else {
                        request.resolve(.failure(CameraFailure.operationInProgress)); return
                    }
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                          session.isRunning, !session.isInterrupted,
                          let connection = output.connection(with: .video), connection.isActive,
                          output.availablePhotoCodecTypes.contains(.jpeg) else {
                        request.resolve(.failure(CameraFailure.cameraUnavailable)); return
                    }
                    if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    settings.flashMode = .off
                    settings.photoQualityPrioritization = .balanced
                    pending[id] = request
                    output.capturePhoto(with: settings, delegate: request)
                }
            }
        } onCancel: { request.resolve(.failure(CancellationError())) }
    }

    private func start() -> CameraPreviewSession.State {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return .unavailable("카메라 권한을 확인해 주세요.")
        }
        if session.inputs.isEmpty {
            let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            guard let device = types.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first else {
                return .unavailable("후면 카메라를 사용할 수 없어요. 실기기에서 확인해 주세요.")
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canAddInput(input) else {
                    return .unavailable("카메라를 연결할 수 없어요. 다시 시도해 주세요.")
                }
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.removeInput(input)
                    return .unavailable("사진 출력을 연결하지 못했어요. 다시 시도해 주세요.")
                }
                session.addOutput(output)
                output.maxPhotoQualityPrioritization = .balanced
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard let initialZoom = zoomRange(device)?.clamped(1) else {
                    throw DetailCameraControlFailure.unsupported
                }
                device.videoZoomFactor = CGFloat(initialZoom) / device.displayVideoZoomFactorMultiplier
            } catch {
                return .unavailable("카메라를 준비하지 못했어요. 다시 시도해 주세요.")
            }
        }
        guard !session.isInterrupted else {
            return .unavailable("카메라 사용이 잠시 중단됐어요. 다른 카메라 사용이 끝나면 다시 시도해 주세요.")
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? .running : .unavailable("카메라를 시작하지 못했어요. 다시 시도해 주세요.")
    }

    func capabilities() async throws -> DetailCameraCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let device = try exposureDevice()
                    continuation.resume(returning: .init(exposure: exposureRange(device), zoom: zoomRange(device),
                        exposureBias: Double(device.exposureTargetBias),
                        zoomFactor: Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        try Task.checkCancellation()
        let applied: Double = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if case .zoom(let factor) = request {
                        guard pending.isEmpty, !exposureCompletion.isPending else {
                            throw DetailCameraControlFailure.operationInProgress
                        }
                        let device = try exposureDevice()
                        guard factor.isFinite, factor > 0 else { throw DetailCameraControlFailure.invalidValue }
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        guard let value = zoomRange(device)?.clamped(factor) else {
                            throw DetailCameraControlFailure.unsupported
                        }
                        device.videoZoomFactor = CGFloat(value) / device.displayVideoZoomFactorMultiplier
                        continuation.resume(returning: Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier))
                        return
                    }
                    guard case .exposure(let bias) = request else { throw DetailCameraControlFailure.unsupported }
                    guard bias.isFinite else { throw DetailCameraControlFailure.invalidValue }
                    guard pending.isEmpty else { throw DetailCameraControlFailure.operationInProgress }
                    let device = try exposureDevice()
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    guard let range = exposureRange(device), let limited = range.clamped(bias) else {
                        throw DetailCameraControlFailure.unsupported
                    }
                    let id = exposureCompletion.begin { continuation.resume(with: $0) }
                    device.exposureMode = .continuousAutoExposure
                    device.setExposureTargetBias(Float(limited)) { [self] _ in
                        queue.async { [self] in
                            guard session.isRunning, !session.isInterrupted else {
                                exposureCompletion.finish(id, with: .failure(DetailCameraControlFailure.unavailable)); return
                            }
                            exposureCompletion.finish(id, with: .success(Double(device.exposureTargetBias)))
                        }
                    }
                    // 세션 오류로 콜백이 누락돼도 호출자가 영구 대기하지 않도록 한다.
                    queue.asyncAfter(deadline: .now() + 5) { [self] in
                        exposureCompletion.finish(id, with: .failure(DetailCameraControlFailure.unavailable))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return applied
    }

    private func exposureDevice() throws -> AVCaptureDevice {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              session.isRunning, !session.isInterrupted,
              let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else {
            throw DetailCameraControlFailure.unavailable
        }
        return device
    }
    private func exposureRange(_ device: AVCaptureDevice) -> DetailCameraControlRange? {
        guard device.isExposureModeSupported(.continuousAutoExposure) else { return nil }
        return .init(minimum: Double(device.minExposureTargetBias), maximum: Double(device.maxExposureTargetBias))
    }

    private func zoomRange(_ device: AVCaptureDevice) -> DetailCameraControlRange? {
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        guard multiplier.isFinite, multiplier > 0 else { return nil }
        return .init(minimum: max(0.5, Double(device.minAvailableVideoZoomFactor) * multiplier),
                     maximum: min(2, Double(device.maxAvailableVideoZoomFactor) * multiplier))
    }
}
