// Created by mason on 10/21/26.
import Foundation
import Observation

/// UI와 독립적인 촬영 옵션 Model. 실제 제어기 또는 목을 주입한다.
@MainActor @Observable
final class DetailCameraOptions {
    private(set) var capabilities = DetailCameraCapabilities()
    private(set) var requested: DetailCameraControlRequest?
    private(set) var appliedExposure: Double?
    private(set) var appliedZoom: Double?
    private(set) var failure: DetailCameraControlFailure?
    // Queue admission immediately blocks capture, before its Task starts.
    var isApplying: Bool { isExecuting || isExecutingFocus || !queuedIntents.isEmpty }
    var isApplyingZoom: Bool {
        if case .zoom? = executingControl { return true }
        return hasQueuedZoom
    }
    private var isExecuting = false
    private var isExecutingFocus = false
    private var executingControl: DetailCameraControlRequest?
    private var hasQueuedZoom = false
    var photoAspectRatio: DetailPhotoAspectRatio = .fourThree

    private var previewFocusPoint: ImagePoint?
    private var previewFocusRequestID: UUID?
    private var previewFocusStatus: CameraFocusStatus = .idle
    private var previewSessionID: UUID?
    private var previewSettingsRevision: UInt64 = 0
    private var previewExposureRevision: UInt64 = 0
    private var requestedPreviewExposure = 0.0
    @ObservationIgnored private var pendingExposureRevision: UInt64?
    @ObservationIgnored private var acceptedExposureRevision: UInt64 = 0
    @ObservationIgnored private var lastKnownZoom: Double?
    @ObservationIgnored private let controller: any DetailCameraControlling
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var focusGeneration: UInt64 = 0
    @ObservationIgnored private var focusOperationID: UUID?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var controlTaskID: UUID?
    @ObservationIgnored private var queuedIntents: [Intent] = []

    private enum Intent {
        case control(DetailCameraControlRequest, exposureRevision: UInt64?)
        case focus(DetailCameraFocusPoint, requestID: UUID, generation: UInt64, exposureRevision: UInt64)
    }

    var previewControlCapabilities: CameraControlCapabilities {
        .init(focusSupported: capabilities.focusSupported && controller is any DetailCameraFocusing,
            meteringSupported: capabilities.meteringSupported,
            aeafLockSupported: false,
            exposureRange: capabilities.exposure.flatMap {
                CameraExposureRange(minimum: $0.minimum, maximum: $0.maximum)
            }, availableZooms: CameraZoom.allCases.filter {
                capabilities.zoom?.clamped($0.rawValue) == $0.rawValue
            })
    }

    var previewControlState: CameraControlState {
        .init(focusPoint: previewFocusPoint, focusRequestID: previewFocusRequestID,
            focusStatus: previewFocusStatus, exposureBias: appliedExposure ?? 0,
            requestedExposureBias: requestedPreviewExposure,
            requestedExposureRevision: previewExposureRevision,
            selectedZoom: appliedZoom.flatMap(CameraZoom.init(rawValue:)) ?? .standard,
            settingsRevision: previewSettingsRevision, sessionID: previewSessionID)
    }

    init(controller: any DetailCameraControlling = UnavailableDetailCameraControls()) {
        self.controller = controller
    }

    /// Measurement keeps its existing controller-owned receipt synchronization.
    /// Preview interaction does not create a competing AVCaptureSession.
    func synchronizeExternalState(capabilities: DetailCameraCapabilities,
                                  invalidatePendingRequests: Bool = false) {
        if invalidatePendingRequests { invalidate() }
        if self.capabilities != capabilities { self.capabilities = capabilities }
        let exposure = validExposure(in: capabilities)
        if appliedExposure != exposure { appliedExposure = exposure }
        if pendingExposureRevision == nil { requestedPreviewExposure = exposure ?? 0 }
        setAppliedZoom(validZoom(in: capabilities))
    }

    func invalidatePendingRequestsForExternalIntent() {
        guard isApplying else { return }
        invalidateControlRequests()
    }

    private func invalidateControlRequests() {
        controlTask?.cancel()
        controlTask = nil
        controlTaskID = nil
        queuedIntents.removeAll()
        hasQueuedZoom = false
        revision += 1
        focusGeneration &+= 1
        focusOperationID = nil
        requested = nil
        failure = nil
        isExecuting = false
        isExecutingFocus = false
        executingControl = nil
        if let pendingExposureRevision { rollbackExposureIntent(pendingExposureRevision) }
    }

    func clearPreviewFocus(cancelPendingRequests: Bool = false) {
        if cancelPendingRequests { invalidateControlRequests() }
        previewFocusPoint = nil
        previewFocusRequestID = nil
        previewFocusStatus = .idle
    }

    func invalidate() {
        invalidateControlRequests()
        clearPreviewFocus()
        capabilities = .init()
        appliedExposure = nil
        appliedZoom = nil
        requestedPreviewExposure = 0
        previewSessionID = nil
    }

    func refreshCapabilities() async {
        invalidate()
        let token = revision
        do {
            let result = try await controller.capabilities()
            guard revision == token, !Task.isCancelled else { return }
            capabilities = result
            appliedExposure = validExposure(in: result)
            requestedPreviewExposure = appliedExposure ?? 0
            setAppliedZoom(validZoom(in: result))
            previewSessionID = UUID()
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            failure = (error as? DetailCameraControlFailure) ?? .deviceFailure
        }
    }

    func apply(_ request: DetailCameraControlRequest) async {
        await apply(request, exposureIntent: nil)
    }

    private func apply(_ request: DetailCameraControlRequest, exposureIntent: UInt64?) async {
        let range: DetailCameraControlRange?
        let value: Double
        switch request {
        case .exposure(let bias): range = capabilities.exposure; value = bias
        case .zoom(let factor): range = capabilities.zoom; value = factor
        }
        guard value.isFinite else { failure = .invalidValue; return }
        if case .zoom = request, value <= 0 { failure = .invalidValue; return }
        guard let range else { failure = .unsupported; return }
        guard let limited = range.clamped(value) else { failure = .invalidValue; return }
        if case .zoom = request, limited <= 0 { failure = .unsupported; return }
        let limitedRequest: DetailCameraControlRequest
        let exposureToken: UInt64?
        switch request {
        case .exposure:
            limitedRequest = .exposure(limited)
            exposureToken = exposureIntent ?? recordExposureIntent(limited)
        case .zoom:
            limitedRequest = .zoom(limited)
            exposureToken = nil
        }
        revision += 1
        let token = revision
        requested = request
        failure = nil
        isExecuting = true
        executingControl = request
        defer {
            if revision == token {
                isExecuting = false
                executingControl = nil
                if Task.isCancelled, let exposureToken { rollbackExposureIntent(exposureToken) }
            }
        }
        do {
            let applied = try await controller.apply(limitedRequest)
            guard revision == token, !Task.isCancelled else { return }
            guard applied.isFinite, (range.minimum...range.maximum).contains(applied) else {
                failure = .deviceFailure
                if let exposureToken { rollbackExposureIntent(exposureToken) }
                return
            }
            switch request {
            case .exposure:
                if let exposureToken { acceptExposure(applied, intent: exposureToken) }
            case .zoom: setAppliedZoom(applied)
            }
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            failure = (error as? DetailCameraControlFailure) ?? .deviceFailure
            if let exposureToken { rollbackExposureIntent(exposureToken) }
        }
    }

    func resetExposure() async { await apply(.exposure(0)) }

    func requestFocus(at point: ImagePoint, requestID: UUID) {
        guard point.isValid, let sensorPoint = DetailCameraFocusPoint(x: point.x, y: point.y) else { return }
        invalidateControlRequests()
        previewFocusPoint = point
        previewFocusRequestID = requestID
        guard capabilities.focusSupported, controller is any DetailCameraFocusing else {
            previewFocusStatus = .unavailable
            return
        }
        previewFocusStatus = .requested
        focusOperationID = requestID
        let exposureToken = recordExposureIntent(capabilities.exposure?.clamped(0) ?? 0)
        queuedIntents.append(.focus(sensorPoint, requestID: requestID,
            generation: focusGeneration, exposureRevision: exposureToken))
        drainQueue()
    }

    private func applyFocus(_ point: DetailCameraFocusPoint, requestID: UUID,
                            generation: UInt64, exposureIntent: UInt64) async {
        guard focusGeneration == generation, focusOperationID == requestID,
              let focusing = controller as? any DetailCameraFocusing else { return }
        isExecutingFocus = true
        defer {
            if focusGeneration == generation {
                isExecutingFocus = false
                focusOperationID = nil
            }
        }
        do {
            let receipt = try await focusing.focus(at: point)
            guard focusGeneration == generation, focusOperationID == requestID,
                  !Task.isCancelled else { return }
            if let exposure = validExposure(in: receipt) {
                acceptExposure(exposure, intent: exposureIntent)
            } else { rollbackExposureIntent(exposureIntent) }
            // A newer EV receipt may already have arrived through a direct
            // panel request. Do not replace it with this older focus reset.
            var current = receipt
            current.exposureBias = appliedExposure
            current.zoomFactor = appliedZoom
            capabilities = current
            if previewFocusRequestID == requestID { previewFocusStatus = .accepted }
        } catch {
            guard focusGeneration == generation, focusOperationID == requestID,
                  !Task.isCancelled else { return }
            let focusFailure = (error as? DetailCameraControlFailure) ?? .deviceFailure
            if previewFocusRequestID == requestID {
                previewFocusStatus = focusFailure == .unsupported || focusFailure == .unavailable ? .unavailable : .failed
            }
            rollbackExposureIntent(exposureIntent)
            // Focus failure is carried only by focusStatus; the More panel's
            // exposure error describes exposure requests, not focus attempts.
        }
    }

    /// During a drag, retain the most recent EV immediately, independently of
    /// the currently executing focus or exposure receipt.
    func requestExposure(_ value: Double) {
        guard let limited = capabilities.exposure?.clamped(value) else { return }
        enqueue(.exposure(limited), exposureIntent: recordExposureIntent(limited))
    }
    func requestZoom(_ value: Double) {
        guard value > 0, let limited = capabilities.zoom?.clamped(value) else { return }
        enqueue(.zoom(limited), exposureIntent: nil)
    }

    private func enqueue(_ request: DetailCameraControlRequest, exposureIntent: UInt64?) {
        queuedIntents.removeAll {
            guard case .control(let queued, _) = $0 else { return false }
            return switch (queued, request) {
            case (.exposure, .exposure), (.zoom, .zoom): true
            default: false
            }
        }
        queuedIntents.append(.control(request, exposureRevision: exposureIntent))
        updateQueuedZoom()
        drainQueue()
    }

    private func drainQueue() {
        guard controlTask == nil else { return }
        let taskID = UUID()
        controlTaskID = taskID
        controlTask = Task {
            while !Task.isCancelled, !queuedIntents.isEmpty {
                let next = queuedIntents.removeFirst()
                updateQueuedZoom()
                switch next {
                case .control(let request, let exposureRevision):
                    await apply(request, exposureIntent: exposureRevision)
                case .focus(let point, let requestID, let generation, let exposureRevision):
                    await applyFocus(point, requestID: requestID, generation: generation, exposureIntent: exposureRevision)
                }
            }
            guard controlTaskID == taskID else { return }
            controlTask = nil
            controlTaskID = nil
        }
    }

    private func updateQueuedZoom() {
        hasQueuedZoom = queuedIntents.contains {
            if case .control(.zoom, _) = $0 { return true }
            return false
        }
    }

    private func recordExposureIntent(_ target: Double) -> UInt64 {
        previewExposureRevision &+= 1
        pendingExposureRevision = previewExposureRevision
        requestedPreviewExposure = target
        return previewExposureRevision
    }

    private func acceptExposure(_ value: Double, intent: UInt64) {
        if intent >= acceptedExposureRevision {
            acceptedExposureRevision = intent
            appliedExposure = value
        }
        if pendingExposureRevision == intent {
            pendingExposureRevision = nil
            requestedPreviewExposure = value
        }
    }

    private func rollbackExposureIntent(_ intent: UInt64) {
        guard pendingExposureRevision == intent else { return }
        pendingExposureRevision = nil
        requestedPreviewExposure = appliedExposure ?? 0
        previewExposureRevision &+= 1
    }

    private func setAppliedZoom(_ value: Double?) {
        if let value, value != lastKnownZoom {
            lastKnownZoom = value
            previewSettingsRevision &+= 1
        }
        if appliedZoom != value { appliedZoom = value }
    }

    private func validExposure(in state: DetailCameraCapabilities) -> Double? {
        state.exposureBias.flatMap { state.exposure?.clamped($0) == $0 ? $0 : nil }
    }

    private func validZoom(in state: DetailCameraCapabilities) -> Double? {
        state.zoomFactor.flatMap { $0 > 0 && state.zoom?.clamped($0) == $0 ? $0 : nil }
    }
}
