// Created by mason on 11/1/26.
import AVFoundation
import OSLog

/// 생성 시 전달된 driver 큐에서만 접근한다. 실험 완료 전에는 광각 진단 옵션으로만 사용.
nonisolated final class DetailWhiteBalanceHold: @unchecked Sendable {
    private let queue: DispatchQueue
    private let diagnostics: DetailCameraDiagnostics
    private let device: AVCaptureDevice
    private var policy = DetailWhiteBalanceHoldPolicy()
    private var waiters: [@Sendable (Result<Void, Error>) -> Void] = []
    private let logger = Logger(subsystem: "com.dobby.camera", category: "ColorDiagnostics")
    private var previousMode: AVCaptureDevice.WhiteBalanceMode?
    private var available = false
    var state: String { policy.state.rawValue }

    init(device: AVCaptureDevice, queue: DispatchQueue, diagnostics: DetailCameraDiagnostics) {
        self.device = device; self.queue = queue; self.diagnostics = diagnostics
        policy.reset(at: ProcessInfo.processInfo.systemUptime)
        guard !device.isVirtualDevice, device.deviceType == .builtInWideAngleCamera,
              device.isWhiteBalanceModeSupported(.locked),
              device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            previousMode = device.whiteBalanceMode
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            available = true
            diagnostics.record("wb_hold_automatic")
        } catch { diagnostics.record("wb_hold_setup_failed") }
    }

    func observe() {
        guard available else { return }
        if policy.state == .held, device.whiteBalanceMode != .locked {
            policy.reset(at: ProcessInfo.processInfo.systemUptime)
            diagnostics.record("wb_hold_lost")
        }
        let gains = device.deviceWhiteBalanceGains
        policy.observe(at: ProcessInfo.processInfo.systemUptime,
            zoom: Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier),
            adjusting: device.isAdjustingWhiteBalance, gains: [gains.redGain, gains.greenGain, gains.blueGain])
    }

    func prepare(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard available else { completion(.success(())); return }
        if policy.state == .locking { waiters.append(completion); return }
        observe()
        guard let revision = policy.requestLock(at: ProcessInfo.processInfo.systemUptime) else {
            diagnostics.record("wb_hold_interaction", fields: ["state": state])
            completion(.success(())); return
        }
        waiters.append(completion)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            diagnostics.recordDevice("wb_hold_requested", device: device)
            device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    guard self.available, self.policy.revision == revision, self.policy.state == .locking else { return }
                    guard self.device.whiteBalanceMode == .locked else { self.fallback(); return }
                    guard self.policy.confirm(revision: revision) else { return }
                    self.diagnostics.recordDevice("wb_hold_ready", device: self.device)
                    self.logger.notice("CameraColorDiagnostics WB HELD - interaction baseline applied")
                    self.finish(.success(()))
                }
            }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.policy.revision == revision, self.policy.state == .locking else { return }
                self.fallback()
            }
        } catch { fallback() }
    }

    func stop() {
        available = false
        policy.reset(at: ProcessInfo.processInfo.systemUptime)
        restore(previousMode)
        diagnostics.record("wb_hold_stopped")
        finish(.failure(CancellationError()))
    }

    private func fallback() {
        policy.reset(at: ProcessInfo.processInfo.systemUptime)
        restore(.continuousAutoWhiteBalance)
        diagnostics.record("wb_hold_fallback_to_auto")
        finish(.success(()))
    }

    private func restore(_ mode: AVCaptureDevice.WhiteBalanceMode?) {
        guard let mode else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isWhiteBalanceModeSupported(mode) { device.whiteBalanceMode = mode }
        } catch { diagnostics.record("wb_hold_restore_failed") }
    }

    private func finish(_ result: Result<Void, Error>) {
        let callbacks = waiters; waiters.removeAll()
        callbacks.forEach { $0(result) }
    }
}
