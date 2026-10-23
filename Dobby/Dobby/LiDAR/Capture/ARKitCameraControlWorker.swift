import AVFoundation
import Foundation
#if DEBUG
import os
#endif

nonisolated enum CameraHardwareControlError: LocalizedError, Sendable {
    case unavailable, busy, invalidInput, staleSession, superseded, lockNotSettled, configuration(String)
    case exposureConfiguration(String, CameraHardwareReceipt)
    case focusConfiguration(String, CameraHardwareReceipt)

    /// An earlier command may have been submitted before a later one failed. The
    /// caller must reconcile this receipt in the SAME failure UI transaction.
    var exposureFailureReceipt: CameraHardwareReceipt? {
        if case .exposureConfiguration(_, let receipt) = self { return receipt }
        return nil
    }
    var focusFailureReceipt: CameraHardwareReceipt? {
        if case .focusConfiguration(_, let receipt) = self { return receipt }
        return nil
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: "이 카메라에서 해당 설정을 지원하지 않아요."
        case .busy: "사진을 확보하는 동안에는 카메라 설정을 바꿀 수 없어요."
        case .invalidInput: "카메라 설정값을 확인해 주세요."
        case .staleSession: "카메라가 다시 시작되었어요. 다시 조절해 주세요."
        case .superseded: "더 최근의 카메라 설정 요청으로 바뀌었어요."
        case .lockNotSettled: "초점·노출 잠금을 확인하지 못했어요. 원하는 위치를 다시 길게 눌러 주세요. 촬영은 바로 할 수 있어요."
        case .configuration(let reason): "카메라 설정을 적용하지 못했어요. \(reason)"
        case .exposureConfiguration(let reason, _): reason
        case .focusConfiguration(let reason, _): reason
        }
    }
}

nonisolated struct CameraHardwareReceipt: Sendable {
    var revision: UInt64
    var focusPoint: ImagePoint?
    var exposureBias: Double
    var aeafStatus: CameraAEAFStatus = .unlocked
    var observation: CameraHardwareObservation? = nil
    var focusRequestID: UUID? = nil
}

/// The adapter and its test double are used only on the worker's serial queue.
/// A successful configuration is separate from an observed settled camera.
nonisolated protocol CameraHardwareDevice: AnyObject, Sendable {
    var capabilities: CameraControlCapabilities { get }
    func restoreAutomatic(exposureBias: Double) throws
    /// The optional bias is applied inside the same device configuration lock
    /// as the AF/AE point. Nil preserves EV for an explicit AE/AF lock.
    func focusAndMeter(at point: ImagePoint, lock: Bool, resetExposureBias: Double?) throws
    func applyExposureBias(_ bias: Double) throws
    /// Control modes only. Lens/ISO/duration getters may synchronously contact
    /// the capture service and do not belong on a continuous EV input path.
    func controlObservation() -> CameraHardwareObservation
    func observation() -> CameraHardwareObservation
}

/// Prefer one-shot autofocus for a tap, with continuous autofocus as a
/// supported fallback. A metering-only camera cannot accept a focus request.
nonisolated enum CameraTapFocusMode {
    static func select(pointOfInterestSupported: Bool, singleSupported: Bool,
                       continuousSupported: Bool) -> AVCaptureDevice.FocusMode? {
        guard pointOfInterestSupported else { return nil }
        if singleSupported { return .autoFocus }
        if continuousSupported { return .continuousAutoFocus }
        return nil
    }
}

nonisolated private final class ARKitPrimaryCameraDevice: CameraHardwareDevice, @unchecked Sendable {
    private let device: AVCaptureDevice
    private struct Profile {
        var capabilities: CameraControlCapabilities
        var tapFocusMode: AVCaptureDevice.FocusMode?
        var pointFocusSupported: Bool
        var continuousFocusSupported: Bool
        var continuousExposureSupported: Bool
        var smoothFocusSupported: Bool
    }
    // A fresh adapter is created for each ARKit control connection. Capability
    // queries never sit in front of a tap or run while holding the device lock.
    private lazy var profile = makeProfile()
    init(_ device: AVCaptureDevice) { self.device = device }

    /// Installed on the same serial queue as configuration. The notification
    /// callback forwards an event only; it never reads or configures the device.
    func observeSubjectArea(_ onChange: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil
        ) { _ in onChange() }
    }

    var capabilities: CameraControlCapabilities { profile.capabilities }

    private func makeProfile() -> Profile {
        let pointFocusSupported = device.isFocusPointOfInterestSupported
        let singleFocusSupported = device.isFocusModeSupported(.autoFocus)
        let continuousFocusSupported = device.isFocusModeSupported(.continuousAutoFocus)
        let tapMode = CameraTapFocusMode.select(pointOfInterestSupported: pointFocusSupported,
            singleSupported: singleFocusSupported, continuousSupported: continuousFocusSupported)
        let continuousExposureSupported = device.isExposureModeSupported(.continuousAutoExposure)
        let meter = device.isExposurePointOfInterestSupported && continuousExposureSupported
        let capabilities = CameraControlCapabilities(focusSupported: tapMode != nil, meteringSupported: meter,
            aeafLockSupported: tapMode != nil && meter && singleFocusSupported
                && device.isFocusModeSupported(.locked)
                && device.isExposureModeSupported(.autoExpose) && device.isExposureModeSupported(.locked),
            exposureRange: continuousExposureSupported
                ? .init(minimum: Double(device.minExposureTargetBias), maximum: Double(device.maxExposureTargetBias)) : nil,
            availableZooms: [.standard])
        return Profile(capabilities: capabilities, tapFocusMode: tapMode,
            pointFocusSupported: pointFocusSupported, continuousFocusSupported: continuousFocusSupported,
            continuousExposureSupported: continuousExposureSupported,
            smoothFocusSupported: device.isSmoothAutoFocusSupported)
    }

    func restoreAutomatic(exposureBias: Double) throws {
        let profile = profile
        try configure {
            // Apple's smooth AF intentionally moves the lens more slowly for
            // movie recording. This still-photo/vision camera needs fast AF.
            if profile.smoothFocusSupported { device.isSmoothAutoFocusEnabled = false }
            if profile.continuousFocusSupported {
                if profile.pointFocusSupported { device.focusPointOfInterest = .init(x: 0.5, y: 0.5) }
                device.focusMode = .continuousAutoFocus
            }
            if profile.continuousExposureSupported {
                if profile.capabilities.meteringSupported { device.exposurePointOfInterest = .init(x: 0.5, y: 0.5) }
                device.exposureMode = .continuousAutoExposure
            }
            if let target = capabilities.exposureRange?.clamp(exposureBias) {
                device.setExposureTargetBias(Float(target), completionHandler: nil)
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    func focusAndMeter(at point: ImagePoint, lock: Bool, resetExposureBias: Double?) throws {
        let supported = capabilities
        guard point.isValid else { throw CameraHardwareControlError.invalidInput }
        guard supported.focusSupported, let focusMode = profile.tapFocusMode,
              !lock || supported.aeafLockSupported else {
            throw CameraHardwareControlError.unavailable
        }
        let resetTarget: Double?
        if let resetExposureBias {
            guard let target = supported.exposureRange?.clamp(resetExposureBias) else {
                throw CameraHardwareControlError.invalidInput
            }
            resetTarget = target
        } else { resetTarget = nil }
        try configure {
            // Both use the same uncropped sensor point, derived from ARKit's
            // display transform. No device zoom, format or stream is replaced.
            device.focusPointOfInterest = .init(x: point.x, y: point.y)
            device.focusMode = focusMode
            if supported.meteringSupported {
                device.exposurePointOfInterest = .init(x: point.x, y: point.y)
                // Both single-shot modes switch to .locked after adjustment.
                // A plain tap explicitly releases an earlier AE/AF lock.
                device.exposureMode = lock ? .autoExpose : .continuousAutoExposure
            }
            if let resetTarget {
                device.setExposureTargetBias(Float(resetTarget), completionHandler: nil)
            }
            device.isSubjectAreaChangeMonitoringEnabled = !lock
        }
    }

    func applyExposureBias(_ bias: Double) throws {
        guard let target = capabilities.exposureRange?.clamp(bias) else {
            throw CameraHardwareControlError.invalidInput
        }
        try configure {
            // AVFoundation applies target bias in .locked as well as continuous
            // AE. Changing to continuous here would silently undo AE/AF LOCK.
            guard device.exposureMode != .custom else { throw CameraHardwareControlError.unavailable }
            #if DEBUG
            if CameraExposureTrace.isEnabled {
                // Telemetry only: the first-applied-buffer callback never
                // gates controls, captures or later requests. Its device clock
                // is NOT assumed to match ARFrame timestamps or host uptime.
                device.setExposureTargetBias(Float(target)) { firstBufferTime in
                    CameraExposureTrace.applied(target: target, deviceTimestamp: CMTimeGetSeconds(firstBufferTime))
                }
            } else {
                device.setExposureTargetBias(Float(target), completionHandler: nil)
            }
            #else
            device.setExposureTargetBias(Float(target), completionHandler: nil)
            #endif
        }
    }

    func controlObservation() -> CameraHardwareObservation {
        let focus: CameraObservedFocusMode = switch device.focusMode {
        case .continuousAutoFocus: .continuous
        case .autoFocus: .single
        case .locked: .locked
        @unknown default: .unavailable
        }
        let exposure: CameraObservedExposureMode = switch device.exposureMode {
        case .continuousAutoExposure: .continuous
        case .autoExpose: .single
        case .locked: .locked
        case .custom: .custom
        @unknown default: .unavailable
        }
        return .init(observedAtUptime: ProcessInfo.processInfo.systemUptime,
            focusMode: focus, exposureMode: exposure,
            isAdjustingFocus: device.isAdjustingFocus, isAdjustingExposure: device.isAdjustingExposure,
            lensPosition: nil, exposureDurationSeconds: nil, iso: nil, exposureTargetBias: nil)
    }

    func observation() -> CameraHardwareObservation {
        func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
        var observation = controlObservation()
        observation.lensPosition = finite(Double(device.lensPosition))
        observation.exposureDurationSeconds = finite(CMTimeGetSeconds(device.exposureDuration))
        observation.iso = finite(Double(device.iso))
        observation.exposureTargetBias = finite(Double(device.exposureTargetBias))
        return observation
    }

    private func configure(_ operation: () throws -> Void) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try operation()
    }
}

/// Only the ARKit-owned primary device is configured. Queue barriers drain
/// commands, never autofocus/autoexposure convergence, before taking a photo.
nonisolated final class ARKitCameraControlWorker: @unchecked Sendable {
    private struct PendingFocus {
        var sessionID: UUID
        var point: ImagePoint
        var lock: Bool
        var requestID: UUID
        var completion: @Sendable (Result<CameraHardwareReceipt, Error>) -> Void
    }

    private struct PendingExposure {
        var sessionID: UUID
        var target: Double
        var completion: @Sendable (Result<CameraHardwareReceipt, Error>) -> Void
    }

    private let queue = DispatchQueue(label: "com.dobby.lidar.camera-controls", qos: .userInitiated)
    private let exposureCadence: TimeInterval
    private var sessionID: UUID?
    private var device: (any CameraHardwareDevice)?
    private var deviceCapabilities = CameraControlCapabilities.unavailable
    private var captureActive = false
    private var exposureAdjustmentActive = false
    private var receipt = CameraHardwareReceipt(revision: 0, focusPoint: nil, exposureBias: 0)
    private var lockRequestID: UUID?
    private var lastPublishedLockStatus: CameraAEAFStatus?
    private var subjectAreaObserver: NSObjectProtocol?
    private var observationHandler: (@Sendable (UUID, CameraHardwareReceipt, CameraHardwareControlError?) -> Void)?
    private var pendingFocus: PendingFocus?
    private var focusEpoch = UUID()
    private var focusTick: DispatchWorkItem?
    private var pendingExposure: PendingExposure?
    private var exposureEpoch = UUID()
    private var exposureTick: DispatchWorkItem?
    private var lastExposureCommandUptime: TimeInterval?
    private var lastExposureRequestUptime = -Double.infinity
    private var lastFocusRequestUptime = -Double.infinity

    init(exposureCadence: TimeInterval = 1.0 / 60) {
        self.exposureCadence = exposureCadence.isFinite
            ? max(1.0 / 60, exposureCadence) : 1.0 / 60
    }

    func activate(sessionID: UUID, device: AVCaptureDevice?, exposureBias: Double,
                  onObservation: (@Sendable (UUID, CameraHardwareReceipt, CameraHardwareControlError?) -> Void)? = nil) async -> CameraControlCapabilities {
        await activate(sessionID: sessionID, hardware: device.map(ARKitPrimaryCameraDevice.init),
                       exposureBias: exposureBias, onObservation: onObservation)
    }

    func activate(sessionID: UUID, hardware: (any CameraHardwareDevice)?, exposureBias: Double,
                  onObservation: (@Sendable (UUID, CameraHardwareReceipt, CameraHardwareControlError?) -> Void)? = nil) async -> CameraControlCapabilities {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.cancelPendingFocus(with: .staleSession)
                self.cancelPendingExposure(with: .staleSession)
                self.removeSubjectAreaObserver()
                self.sessionID = sessionID
                self.device = hardware
                self.deviceCapabilities = .unavailable
                self.captureActive = false
                self.exposureAdjustmentActive = false
                self.lockRequestID = nil
                self.lastPublishedLockStatus = nil
                self.observationHandler = onObservation
                self.receipt = .init(revision: 0, focusPoint: nil, exposureBias: 0)
                self.lastExposureCommandUptime = nil
                self.lastExposureRequestUptime = -.infinity
                self.lastFocusRequestUptime = -.infinity
                guard let hardware else { continuation.resume(returning: .unavailable); return }
                do {
                    let capabilities = hardware.capabilities
                    self.deviceCapabilities = capabilities
                    let target = capabilities.exposureRange?.clamp(exposureBias) ?? 0
                    try hardware.restoreAutomatic(exposureBias: target)
                    self.receipt.exposureBias = target
                    self.receipt.observation = hardware.controlObservation()
                    if let primary = hardware as? ARKitPrimaryCameraDevice {
                        self.subjectAreaObserver = primary.observeSubjectArea { [weak worker = self] in
                            worker?.subjectAreaChanged(sessionID: sessionID)
                        }
                    }
                    continuation.resume(returning: capabilities)
                } catch {
                    self.device = nil
                    self.deviceCapabilities = .unavailable
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func deactivate() {
        queue.async {
            self.cancelPendingFocus(with: .staleSession)
            self.cancelPendingExposure(with: .staleSession)
            self.sessionID = nil; self.device = nil; self.captureActive = false
            self.exposureAdjustmentActive = false
            self.deviceCapabilities = .unavailable
            self.lockRequestID = nil; self.observationHandler = nil
            self.lastPublishedLockStatus = nil
            self.removeSubjectAreaObserver()
        }
    }

    /// A plain focus tap may return to automatic tracking after a substantial
    /// scene change. An explicit AE/AF lock must survive the same notification.
    func subjectAreaChanged(sessionID: UUID) {
        queue.async {
            guard self.sessionID == sessionID, !self.captureActive, !self.exposureAdjustmentActive,
                  self.receipt.aeafStatus == .unlocked, self.pendingFocus == nil, self.pendingExposure == nil,
                  ProcessInfo.processInfo.systemUptime - max(self.lastFocusRequestUptime,
                    max(self.lastExposureRequestUptime, self.lastExposureCommandUptime ?? -.infinity)) >= 0.15,
                  let device = self.device else { return }
            // Delayed subject-area notifications cannot cancel an in-flight
            // tap AF or recenter while automatic exposure is still adjusting.
            let observation = device.controlObservation()
            guard !observation.isAdjustingFocus, !observation.isAdjustingExposure else { return }
            do {
                try device.restoreAutomatic(exposureBias: self.receipt.exposureBias)
                self.receipt.focusPoint = nil
                self.receipt.revision &+= 1
                self.refreshObservation()
                self.observationHandler?(sessionID, self.receipt, nil)
            } catch {
                self.observationHandler?(sessionID, self.receipt,
                    .configuration("대상이 바뀐 뒤 자동 초점으로 돌아가지 못했어요. 화면을 다시 눌러 주세요."))
            }
        }
    }

    private func removeSubjectAreaObserver() {
        if let subjectAreaObserver { NotificationCenter.default.removeObserver(subjectAreaObserver) }
        subjectAreaObserver = nil
    }

    func focus(at point: ImagePoint, sessionID: UUID, lock: Bool = false) async throws -> CameraHardwareReceipt {
        try await withCheckedThrowingContinuation { continuation in
            submitFocus(at: point, sessionID: sessionID, lock: lock) { continuation.resume(with: $0) }
        }
    }

    /// Plain taps share one replaceable slot. Yielding once lets taps admitted
    /// during a slow device operation replace obsolete targets. EV, explicit
    /// lock and shutter boundaries flush that slot before their own operation.
    func submitFocus(at point: ImagePoint, sessionID: UUID, lock: Bool = false, requestID: UUID = UUID(),
                     completion: @escaping @Sendable (Result<CameraHardwareReceipt, Error>) -> Void) {
        let request = PendingFocus(sessionID: sessionID, point: point, lock: lock,
            requestID: requestID, completion: completion)
        #if DEBUG
        let queuedAt = CameraExposureTrace.queueTimestamp()
        CameraExposureTrace.focusInput(point: point, requestID: requestID)
        #endif
        queue.async {
            #if DEBUG
            CameraExposureTrace.focusQueueArrival(requestID: requestID, queuedAt: queuedAt)
            #endif
            guard self.sessionID == sessionID else { completion(.failure(CameraHardwareControlError.staleSession)); return }
            guard !self.captureActive else { completion(.failure(CameraHardwareControlError.busy)); return }
            guard self.device != nil, self.deviceCapabilities.focusSupported else {
                completion(.failure(CameraHardwareControlError.unavailable)); return
            }
            guard point.isValid else { completion(.failure(CameraHardwareControlError.invalidInput)); return }
            if lock {
                self.flushPendingFocus()
                self.flushPendingExposure()
                self.applyFocus(request)
            } else {
                // A new plain tap resets EV in the SAME configuration as AF.
                // Do not first apply an obsolete, unsubmitted drag target.
                self.cancelPendingExposure(with: .superseded)
                self.exposureAdjustmentActive = false
                let superseded = self.pendingFocus
                self.pendingFocus = request
                superseded?.completion(.failure(CameraHardwareControlError.superseded))
                self.scheduleFocusTick()
            }
        }
    }

    private func scheduleFocusTick() {
        guard let pendingFocus, focusTick == nil else { return }
        let identifier = pendingFocus.sessionID, epoch = focusEpoch
        let work = DispatchWorkItem { [weak worker = self] in
            guard let worker, worker.sessionID == identifier, worker.focusEpoch == epoch else { return }
            worker.focusTick = nil
            guard let request = worker.pendingFocus else { return }
            worker.pendingFocus = nil
            worker.applyFocus(request)
        }
        focusTick = work
        queue.async(execute: work)
    }

    private func flushPendingFocus() {
        guard let request = pendingFocus else { return }
        invalidateFocusScheduling()
        pendingFocus = nil
        applyFocus(request)
    }

    private func cancelPendingFocus(with error: CameraHardwareControlError) {
        invalidateFocusScheduling()
        let request = pendingFocus
        pendingFocus = nil
        request?.completion(.failure(error))
    }

    private func invalidateFocusScheduling() {
        focusTick?.cancel(); focusTick = nil
        focusEpoch = UUID()
    }

    private func applyFocus(_ request: PendingFocus) {
        guard sessionID == request.sessionID else { request.completion(.failure(CameraHardwareControlError.staleSession)); return }
        guard !captureActive else { request.completion(.failure(CameraHardwareControlError.busy)); return }
        guard let device else { request.completion(.failure(CameraHardwareControlError.unavailable)); return }
        do {
            let neutralBias = request.lock ? nil : deviceCapabilities.exposureRange?.clamp(0)
            try submitFocusToDevice(request, neutralBias: neutralBias, device: device)
            lastFocusRequestUptime = ProcessInfo.processInfo.systemUptime
            if let neutralBias {
                receipt.exposureBias = neutralBias
                lastExposureCommandUptime = lastFocusRequestUptime
            }
            receipt.focusPoint = request.point
            receipt.focusRequestID = request.requestID
            receipt.aeafStatus = request.lock ? .locking : .unlocked
            receipt.revision &+= 1
            lockRequestID = request.lock ? UUID() : nil
            lastPublishedLockStatus = nil
            // Accepted AF is a submitted command, not a settled lens. Normal
            // taps must not block the next input on synchronous mode getters.
            if request.lock { refreshObservation() }
            else { receipt.observation = nil }
            #if DEBUG
            CameraExposureTrace.focusReceipt(requestID: request.requestID, revision: receipt.revision)
            #endif
            request.completion(.success(receipt))
            if request.lock, let lockRequestID {
                observeLock(sessionID: request.sessionID, requestID: lockRequestID, remaining: 25)
            }
        } catch {
            if request.lock { refreshObservation() }
            else { receipt.observation = nil }
            request.completion(.failure(CameraHardwareControlError.focusConfiguration(error.localizedDescription, receipt)))
        }
    }

    private func submitFocusToDevice(_ request: PendingFocus, neutralBias: Double?, device: any CameraHardwareDevice) throws {
        #if DEBUG
        let interval = CameraExposureTrace.beginFocusSubmit(requestID: request.requestID, revision: receipt.revision &+ 1)
        defer { CameraExposureTrace.endFocusSubmit(interval) }
        #endif
        try device.focusAndMeter(at: request.point, lock: request.lock, resetExposureBias: neutralBias)
    }

    func submitExposure(_ bias: Double, sessionID: UUID,
                        completion: @escaping @Sendable (Result<CameraHardwareReceipt, Error>) -> Void) {
        #if DEBUG
        let queuedAt = CameraExposureTrace.queueTimestamp()
        #endif
        queue.async {
            #if DEBUG
            CameraExposureTrace.queueArrival(target: bias, queuedAt: queuedAt)
            #endif
            guard self.sessionID == sessionID else { completion(.failure(CameraHardwareControlError.staleSession)); return }
            guard !self.captureActive else { completion(.failure(CameraHardwareControlError.busy)); return }
            guard self.device != nil else { completion(.failure(CameraHardwareControlError.unavailable)); return }
            guard let target = self.deviceCapabilities.exposureRange?.clamp(bias) else {
                completion(.failure(CameraHardwareControlError.invalidInput)); return
            }
            self.flushPendingFocus()
            let now = ProcessInfo.processInfo.systemUptime
            self.lastExposureRequestUptime = now
            if let superseded = self.pendingExposure {
                // Only the latest admitted target retains a completion. Input
                // closures may queue during a synchronous device operation;
                // the next delivery yields so those closures can coalesce.
                superseded.completion(.failure(CameraHardwareControlError.superseded))
            }
            self.pendingExposure = .init(sessionID: sessionID, target: target, completion: completion)
            if target == self.receipt.exposureBias {
                self.invalidateExposureScheduling()
                self.finishPendingExposure()
                return
            }
            self.scheduleExposureTick()
        }
    }

    /// Enqueue the gesture boundary synchronously with EV inputs. A stationary
    /// finger still owns its metering point; ending applies the final target
    /// without waiting for another cadence tick or for sensor AE to settle.
    func setExposureAdjustmentActive(_ active: Bool, sessionID: UUID) {
        queue.async {
            guard self.sessionID == sessionID, !self.captureActive,
                  self.exposureAdjustmentActive != active else { return }
            self.flushPendingFocus()
            self.exposureAdjustmentActive = active
            if !active { self.flushPendingExposure() }
        }
    }

    func exposure(_ bias: Double, sessionID: UUID) async throws -> CameraHardwareReceipt {
        try await withCheckedThrowingContinuation { continuation in
            submitExposure(bias, sessionID: sessionID) { continuation.resume(with: $0) }
        }
    }

    func beginCapture(sessionID: UUID) async throws -> CameraHardwareReceipt {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.sessionID == sessionID else {
                    continuation.resume(throwing: CameraHardwareControlError.staleSession); return
                }
                // A shutter is a command barrier, not an exposure-settling
                // barrier. Accept the latest requested AF/EV immediately.
                self.flushPendingFocus()
                self.flushPendingExposure()
                self.exposureAdjustmentActive = false
                self.captureActive = true
                self.refreshObservation(full: true)
                continuation.resume(returning: self.receipt)
            }
        }
    }

    func endCapture(sessionID: UUID) {
        queue.async { if self.sessionID == sessionID { self.captureActive = false } }
    }

    private func scheduleExposureTick() {
        guard let pendingExposure, exposureTick == nil else { return }
        let identifier = pendingExposure.sessionID
        let epoch = exposureEpoch
        let now = ProcessInfo.processInfo.systemUptime
        let delay = lastExposureCommandUptime.map { max(0, $0 + exposureCadence - now) } ?? 0
        let work = DispatchWorkItem { [weak worker = self] in
            guard let worker, worker.sessionID == identifier, worker.exposureEpoch == epoch else { return }
            worker.exposureTick = nil
            worker.applyLatestExposure()
        }
        exposureTick = work
        if delay == 0 {
            // No timer or sensor-settling wait after idle. Yield once so inputs
            // queued during a slow setter replace obsolete targets before the
            // next hardware operation. Focus/capture barriers still flush now.
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func applyLatestExposure() {
        guard var pending = pendingExposure, sessionID == pending.sessionID, !captureActive,
              let device else { return }
        guard let target = deviceCapabilities.exposureRange?.clamp(pending.target) else {
            failPendingExposure(CameraHardwareControlError.unavailable); return
        }
        pending.target = target
        pendingExposure = pending
        if target == receipt.exposureBias {
            finishPendingExposure()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        do {
            try submitExposureToDevice(target, device: device)
            receipt.exposureBias = target
            receipt.revision &+= 1
            lastExposureCommandUptime = now
            refreshExposureObservation()
            finishPendingExposure()
        } catch { failPendingExposure(error) }
    }

    private func finishPendingExposure() {
        let completed = pendingExposure
        pendingExposure = nil
        completed?.completion(.success(receipt))
    }

    /// Flush before focus or shutter without waiting for AE. Cancel the one
    /// pending delivery so it cannot run after capture or a session change.
    private func flushPendingExposure() {
        guard let pending = pendingExposure else { return }
        invalidateExposureScheduling()
        guard let device, let target = deviceCapabilities.exposureRange?.clamp(pending.target) else {
            failPendingExposure(CameraHardwareControlError.unavailable); return
        }
        do {
            try submitExposureToDevice(target, device: device)
            receipt.exposureBias = target
            receipt.revision &+= 1
            lastExposureCommandUptime = ProcessInfo.processInfo.systemUptime
            refreshExposureObservation()
            finishPendingExposure()
        } catch { failPendingExposure(error) }
    }

    private func failPendingExposure(_ error: Error) {
        refreshExposureObservation()
        let failure = CameraHardwareControlError.exposureConfiguration(error.localizedDescription, receipt)
        cancelPendingExposure(with: failure)
    }

    private func cancelPendingExposure(with error: CameraHardwareControlError) {
        invalidateExposureScheduling()
        let pending = pendingExposure
        pendingExposure = nil
        pending?.completion(.failure(error))
    }

    private func invalidateExposureScheduling() {
        exposureTick?.cancel(); exposureTick = nil
        exposureEpoch = UUID()
    }

    private func submitExposureToDevice(_ target: Double, device: any CameraHardwareDevice) throws {
        #if DEBUG
        let interval = CameraExposureTrace.beginDeviceSubmit(target: target, revision: receipt.revision &+ 1)
        defer { CameraExposureTrace.endDeviceSubmit(interval) }
        #endif
        try device.applyExposureBias(target)
    }

    private func refreshExposureObservation() {
        if receipt.aeafStatus == .unlocked {
            // Even the mode/adjusting getters may contact the capture service.
            // EV input only needs a command receipt. Drop an older observation
            // instead of synchronously polling or re-dating its sensor facts.
            receipt.observation = nil
        } else {
            // Preserve independently observed AE/AF lock semantics. Normal tap
            // exposure does not enter this path; a shutter still reads full data.
            refreshObservation()
        }
    }

    private func refreshObservation(full: Bool = false) {
        // Partial observations deliberately clear the expensive fields; old
        // values must not acquire a fresh timestamp and pretend to be current.
        receipt.observation = full ? device?.observation() : device?.controlObservation()
        if receipt.aeafStatus == .locking, receipt.observation?.hasObservedAEAFLock == true {
            receipt.aeafStatus = .locked
        }
        if receipt.aeafStatus == .locked, !hasObservedLockModesWithoutFocusAdjustment {
            // A camera/ARKit override cannot keep presenting an old confirmed lock.
            // Intentional target-bias changes may adjust exposure while BOTH
            // modes remain locked; that does not release an already held lock.
            receipt.aeafStatus = .locking
        }
    }

    private var hasObservedLockModesWithoutFocusAdjustment: Bool {
        guard let observation = receipt.observation else { return false }
        return observation.focusMode == .locked && observation.exposureMode == .locked && !observation.isAdjustingFocus
    }

    private func observeLock(sessionID: UUID, requestID: UUID, remaining: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            guard self.sessionID == sessionID, self.lockRequestID == requestID, self.device != nil else { return }
            self.refreshObservation()
            // Keep observing a real lock without forcing the whole SwiftUI
            // preview to redraw for an uptime-only change every 100 ms.
            if self.lastPublishedLockStatus != self.receipt.aeafStatus {
                self.lastPublishedLockStatus = self.receipt.aeafStatus
                self.observationHandler?(sessionID, self.receipt, nil)
            }
            if self.receipt.aeafStatus == .locked {
                self.observeLock(sessionID: sessionID, requestID: requestID, remaining: 25)
            } else if self.exposureIsRecentlyRequested, self.hasObservedLockModesWithoutFocusAdjustment,
                      self.receipt.observation?.isAdjustingExposure == true {
                // Initial confirmation still requires a settled observation,
                // but deliberate EV changes must not consume its lock timeout.
                self.observeLock(sessionID: sessionID, requestID: requestID, remaining: remaining)
            } else if remaining > 0 {
                self.observeLock(sessionID: sessionID, requestID: requestID, remaining: remaining - 1)
            } else {
                self.receipt.aeafStatus = .failed
                self.lastPublishedLockStatus = .failed
                self.observationHandler?(sessionID, self.receipt, .lockNotSettled)
            }
        }
    }

    private var exposureIsRecentlyRequested: Bool {
        pendingExposure != nil || ProcessInfo.processInfo.systemUptime
            - max(lastExposureRequestUptime, lastExposureCommandUptime ?? -.infinity) < 0.15
    }


}

#if DEBUG
/// Optional Instruments diagnostics. These events contain numeric controls and
/// timing only. First-applied-buffer device time is not assumed to share a
/// clock with ARFrame timestamps or host uptime; no event gates configuration.
nonisolated enum CameraExposureTrace {
    private static let signposter = OSSignposter(subsystem: "com.dobby.lidar", category: .pointsOfInterest)
    static var isEnabled: Bool { signposter.isEnabled }

    // All focus timings use host/signpost time. A receipt means a submitted
    // configuration, never that the optical lens has reached a sharp image.
    static func focusInput(point: ImagePoint, requestID: UUID) {
        guard isEnabled else { return }
        signposter.emitEvent("FocusInput", "request=\(requestID.uuidString, privacy: .public) x=\(point.x, privacy: .public) y=\(point.y, privacy: .public)")
    }

    static func focusQueueArrival(requestID: UUID, queuedAt: TimeInterval?) {
        guard isEnabled, let queuedAt else { return }
        let waitMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - queuedAt) * 1_000
        signposter.emitEvent("FocusQueue", "request=\(requestID.uuidString, privacy: .public) wait_ms=\(waitMilliseconds, privacy: .public)")
    }

    static func beginFocusSubmit(requestID: UUID, revision: UInt64) -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
        return signposter.beginInterval("FocusDeviceSubmit", id: signposter.makeSignpostID(),
            "request=\(requestID.uuidString, privacy: .public) revision=\(revision, privacy: .public)")
    }

    static func endFocusSubmit(_ interval: OSSignpostIntervalState?) {
        guard let interval else { return }
        signposter.endInterval("FocusDeviceSubmit", interval)
    }

    static func focusReceipt(requestID: UUID, revision: UInt64) {
        guard isEnabled else { return }
        signposter.emitEvent("FocusReceipt", "request=\(requestID.uuidString, privacy: .public) revision=\(revision, privacy: .public)")
    }

    static func input(_ target: Double) {
        guard isEnabled else { return }
        signposter.emitEvent("ExposureInput", "target_ev=\(target, privacy: .public)")
    }

    static func receipt(revision: UInt64, bias: Double) {
        guard isEnabled else { return }
        signposter.emitEvent("ExposureReceipt", "revision=\(revision, privacy: .public) accepted_ev=\(bias, privacy: .public)")
    }

    static func frame(timestamp: TimeInterval, exposureDuration: Double, exposureOffset: Double) {
        guard isEnabled else { return }
        signposter.emitEvent("ExposureFrame", "frame_time=\(timestamp, privacy: .public) duration_s=\(exposureDuration, privacy: .public) offset_ev=\(exposureOffset, privacy: .public)")
    }

    static func applied(target: Double, deviceTimestamp: Double) {
        guard isEnabled else { return }
        signposter.emitEvent("ExposureApplied", "target_ev=\(target, privacy: .public) device_time=\(deviceTimestamp, privacy: .public)")
    }

    static func queueTimestamp() -> TimeInterval? {
        isEnabled ? ProcessInfo.processInfo.systemUptime : nil
    }

    static func queueArrival(target: Double, queuedAt: TimeInterval?) {
        guard isEnabled, let queuedAt else { return }
        let waitMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - queuedAt) * 1_000
        signposter.emitEvent("ExposureQueue", "target_ev=\(target, privacy: .public) wait_ms=\(waitMilliseconds, privacy: .public)")
    }

    static func beginDeviceSubmit(target: Double, revision: UInt64) -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
        return signposter.beginInterval("ExposureDeviceSubmit", id: signposter.makeSignpostID(),
            "target_ev=\(target, privacy: .public) revision=\(revision, privacy: .public)")
    }

    static func endDeviceSubmit(_ interval: OSSignpostIntervalState?) {
        guard let interval else { return }
        signposter.endInterval("ExposureDeviceSubmit", interval)
    }
}
#endif
