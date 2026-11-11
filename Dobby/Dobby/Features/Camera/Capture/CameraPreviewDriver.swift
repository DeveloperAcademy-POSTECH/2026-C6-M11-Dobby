//
//  CameraPreviewDriver.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation

/// Capture 폴더 담당: mason. 가변 세션·출력·delegate 보관은 이 직렬 큐에서만 다룬다.
/// @unchecked Sendable은 큐 소유권에 한정한다. UI는 session을 레이어에 연결만 한다.
nonisolated final class CameraPreviewDriver: DetailCameraControlling, DetailCameraFocusing, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.dobby.camera.detail-preview", qos: .userInitiated)
    private var pending: [UUID: CameraPhotoRequest] = [:]
    private let controlEpoch = DetailCameraControlEpoch()
    let diagnostics = DetailCameraDiagnostics()
    private var diagnosticTimer: DispatchSourceTimer?
    private var whiteBalanceHold: DetailWhiteBalanceHold?

    func setRunning(_ active: Bool, completion: @escaping @Sendable (CameraPreviewSession.State) -> Void) {
        controlEpoch.invalidate()
        queue.async { [self] in
            if active {
                completion(start())
                startDiagnosticSampling()
            } else {
                diagnosticTimer?.cancel()
                diagnosticTimer = nil
                whiteBalanceHold?.stop()
                whiteBalanceHold = nil
                diagnostics.record("session_stopping")
                pending.values.forEach { $0.resolve(.failure(CancellationError())) }
                // 일시 중단 상태에서도 자동 재개 요청이 남지 않도록 중지한다.
                session.stopRunning()
                completion(.stopped)
            }
        }
    }

    func cancelCapture() {
        controlEpoch.invalidate()
        queue.async { [self] in
            whiteBalanceHold?.stop()
            whiteBalanceHold = nil
            pending.values.forEach { $0.resolve(.failure(CancellationError())) }
        }
    }

    func capture(rotationAngle: CGFloat, diagnosticID: UUID? = nil) async throws -> Data {
        try Task.checkCancellation()
        controlEpoch.invalidate()
        let ticket = controlEpoch.ticket()
        try await prepareWhiteBalanceHold(ticket: ticket)
        try Task.checkCancellation()
        try ticket.checkCancellation()
        let id = UUID()
        // 화면이 닫혀도 최종 콜백까지 driver/delegate를 유지하고 pending 제거로 순환 참조를 끊는다.
        let request = CameraPhotoRequest(diagnostics: diagnostics, diagnosticID: diagnosticID) { [self] in
            queue.async { self.pending[id] = nil }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                queue.async { [self] in
                    guard !request.isResolved else { return }
                    do { try ticket.checkCancellation() }
                    catch { request.resolve(.failure(error)); return }
                    guard pending.isEmpty else {
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
                    if diagnostics.holdsWhiteBalanceOnInteraction {
                        diagnostics.record("wb_capture_state", captureID: diagnosticID,
                            fields: ["state": whiteBalanceHold?.state ?? "automatic"])
                    }
                    diagnostics.recordDevice("shutter_submitted", device: (session.inputs.first as? AVCaptureDeviceInput)?.device,
                                             captureID: diagnosticID)
                    output.capturePhoto(with: settings, delegate: request)
                }
            }
        } onCancel: {
            ticket.cancel()
            request.resolve(.failure(CancellationError()))
        }
    }

    private func start() -> CameraPreviewSession.State {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return .unavailable("카메라 권한을 확인해 주세요.")
        }
        if session.inputs.isEmpty {
            // 진단 실험에서만 물리 광각을 선택한다. 가상 카메라로 대체하면 A/B 조건이 깨진다.
            let types: [AVCaptureDevice.DeviceType] = diagnostics.usesWideCamera
                ? [.builtInWideAngleCamera]
                : [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
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
                diagnostics.record("camera_configured", fields: [
                    "deviceType": device.deviceType.rawValue, "isVirtualDevice": device.isVirtualDevice,
                    "displayZoomMultiplier": Double(device.displayVideoZoomFactorMultiplier)])
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
                    continuation.resume(returning: deviceCapabilities(device))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        try Task.checkCancellation()
        let ticket = controlEpoch.ticket()
        let applied: Double = try await withTaskCancellationHandler {
            if case .zoom(let factor) = request {
                guard factor.isFinite, factor > 0 else { throw DetailCameraControlFailure.invalidValue }
                try await prepareWhiteBalanceHold(ticket: ticket)
                try Task.checkCancellation()
            }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try ticket.checkCancellation()
                        guard pending.isEmpty else { throw DetailCameraControlFailure.operationInProgress }
                        let device = try exposureDevice()
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        // Cancellation may arrive while the device configuration lock waits.
                        try ticket.checkCancellation()
                        switch request {
                        case .zoom(let factor):
                            guard factor.isFinite, factor > 0 else { throw DetailCameraControlFailure.invalidValue }
                            guard let value = zoomRange(device)?.clamped(factor) else {
                                throw DetailCameraControlFailure.unsupported
                            }
                            diagnostics.recordDevice("zoom_requested", device: device, requestedZoom: value)
                            device.videoZoomFactor = CGFloat(value) / device.displayVideoZoomFactorMultiplier
                            diagnostics.recordDevice("zoom_setter_returned", device: device, requestedZoom: value)
                            continuation.resume(returning: Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier))
                        case .exposure(let bias):
                            guard bias.isFinite else { throw DetailCameraControlFailure.invalidValue }
                            guard let limited = exposureRange(device)?.clamped(bias) else {
                                throw DetailCameraControlFailure.unsupported
                            }
                            if device.exposureMode != .continuousAutoExposure { device.exposureMode = .continuousAutoExposure }
                            // A first-applied-buffer callback deliberately does not gate
                            // subsequent drag commands or the shutter. The receipt is the
                            // accepted target, not a claim that AE has physically settled.
                            device.setExposureTargetBias(Float(limited), completionHandler: nil)
                            continuation.resume(returning: limited)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { ticket.cancel() }
        try Task.checkCancellation()
        return applied
    }

    func focus(at point: DetailCameraFocusPoint) async throws -> DetailCameraCapabilities {
        try Task.checkCancellation()
        let ticket = controlEpoch.ticket()
        let receipt: DetailCameraCapabilities = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try ticket.checkCancellation()
                        guard pending.isEmpty else { throw DetailCameraControlFailure.operationInProgress }
                        let device = try exposureDevice()
                        guard let mode = tapFocusMode(device) else { throw DetailCameraControlFailure.unsupported }
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        try ticket.checkCancellation()
                        // Keep AF, metering and EV reset in one configuration change.
                        // Smooth AF intentionally slows the lens for movies; this is
                        // a still-photo interaction and uses the fast focus path.
                        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
                        device.focusPointOfInterest = CGPoint(x: point.x, y: point.y)
                        device.focusMode = mode
                        if device.isExposurePointOfInterestSupported,
                           device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposurePointOfInterest = CGPoint(x: point.x, y: point.y)
                            if device.exposureMode != .continuousAutoExposure { device.exposureMode = .continuousAutoExposure }
                        }
                        let reset = exposureRange(device)?.clamped(0)
                        if let reset { device.setExposureTargetBias(Float(reset), completionHandler: nil) }
                        continuation.resume(returning: deviceCapabilities(device, acceptedExposure: reset))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { ticket.cancel() }
        try Task.checkCancellation()
        return receipt
    }

    private func deviceCapabilities(_ device: AVCaptureDevice, acceptedExposure: Double? = nil) -> DetailCameraCapabilities {
        .init(exposure: exposureRange(device), zoom: zoomRange(device),
            exposureBias: acceptedExposure ?? Double(device.exposureTargetBias),
            zoomFactor: Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier),
            focusSupported: tapFocusMode(device) != nil,
            meteringSupported: device.isExposurePointOfInterestSupported
                && device.isExposureModeSupported(.continuousAutoExposure))
    }

    private func tapFocusMode(_ device: AVCaptureDevice) -> AVCaptureDevice.FocusMode? {
        CameraTapFocusMode.select(pointOfInterestSupported: device.isFocusPointOfInterestSupported,
            singleSupported: device.isFocusModeSupported(.autoFocus),
            continuousSupported: device.isFocusModeSupported(.continuousAutoFocus))
    }

    private func exposureDevice() throws -> AVCaptureDevice {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              session.isRunning, !session.isInterrupted,
              let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else {
            throw DetailCameraControlFailure.unavailable
        }
        return device
    }
    private func startDiagnosticSampling() {
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        guard diagnostics.enabled, session.isRunning else { return }
        diagnostics.record("session_running")
        ensureWhiteBalanceHold()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.session.isRunning || self.session.isInterrupted {
                self.whiteBalanceHold?.stop()
                self.whiteBalanceHold = nil
            } else {
                self.ensureWhiteBalanceHold()
                self.whiteBalanceHold?.observe()
            }
            self.diagnostics.recordDevice("device_sample",
                device: (self.session.inputs.first as? AVCaptureDeviceInput)?.device)
        }
        diagnosticTimer = timer
        timer.resume()
    }

    deinit { diagnosticTimer?.cancel() }

    private func ensureWhiteBalanceHold() {
        guard diagnostics.holdsWhiteBalanceOnInteraction, whiteBalanceHold == nil,
              session.isRunning, !session.isInterrupted,
              let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        whiteBalanceHold = DetailWhiteBalanceHold(device: device, queue: queue, diagnostics: diagnostics)
    }

    /// WB 준비 전후에도 같은 요청인지 확인해 대기 중 취소된 조작이 재실행되지 않게 한다.
    private func prepareWhiteBalanceHold(ticket: DetailCameraControlTicket) async throws {
        try Task.checkCancellation()
        try ticket.checkCancellation()
        guard diagnostics.holdsWhiteBalanceOnInteraction else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try ticket.checkCancellation()
                        guard session.isRunning, !session.isInterrupted else {
                            throw DetailCameraControlFailure.unavailable
                        }
                        guard pending.isEmpty else { throw DetailCameraControlFailure.operationInProgress }
                        ensureWhiteBalanceHold()
                        try ticket.checkCancellation()
                        guard let whiteBalanceHold else { continuation.resume(); return }
                        whiteBalanceHold.prepare { result in
                            do {
                                try ticket.checkCancellation()
                                continuation.resume(with: result)
                            } catch { continuation.resume(throwing: error) }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { ticket.cancel() }
    }

    private func exposureRange(_ device: AVCaptureDevice) -> DetailCameraControlRange? {
        guard device.isExposureModeSupported(.continuousAutoExposure) else { return nil }
        return .init(minimum: Double(device.minExposureTargetBias), maximum: Double(device.maxExposureTargetBias))
    }

    private func zoomRange(_ device: AVCaptureDevice) -> DetailCameraControlRange? {
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        guard multiplier.isFinite, multiplier > 0 else { return nil }
        return .init(minimum: max(0.5, Double(device.minAvailableVideoZoomFactor) * multiplier),
                     maximum: Double(device.maxAvailableVideoZoomFactor) * multiplier)
    }
}
