// Created by mason on 10/21/26.
import Observation

/// UI와 독립적인 촬영 옵션 Model. 실제 제어기 또는 목을 주입한다.
@MainActor @Observable
final class DetailCameraOptions {
    private(set) var capabilities = DetailCameraCapabilities()
    private(set) var requested: DetailCameraControlRequest?
    private(set) var appliedExposure: Double?
    private(set) var appliedZoom: Double?
    private(set) var failure: DetailCameraControlFailure?
    // Task 실행 전 대기 구간도 포함해 이전 옵션으로 촬영되는 틈을 막는다.
    var isApplying: Bool { isExecuting || !queuedControls.isEmpty }
    private var isExecuting = false
    // 프리뷰와 저장 크롭이 공유하는 사용자 선택. 세션 재시작에도 유지한다.
    var photoAspectRatio: DetailPhotoAspectRatio = .fourThree
    @ObservationIgnored private let controller: any DetailCameraControlling
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var queuedControls: [DetailCameraControlRequest] = []

    init(controller: any DetailCameraControlling = UnavailableDetailCameraControls()) {
        self.controller = controller
    }

    /// Opt-in synchronization for a camera with other exposure controls, such
    /// as the measurement preview's tap and vertical drag. Detail capture does
    /// not call this API and retains its existing controller-owned behavior.
    func synchronizeExternalState(capabilities: DetailCameraCapabilities,
                                  invalidatePendingRequests: Bool = false) {
        if invalidatePendingRequests { invalidate() }
        if self.capabilities != capabilities { self.capabilities = capabilities }
        let exposure = capabilities.exposureBias.flatMap { bias -> Double? in
            capabilities.exposure?.clamped(bias) == bias ? bias : nil
        }
        let zoom = capabilities.zoomFactor.flatMap { factor -> Double? in
            factor > 0 && capabilities.zoom?.clamped(factor) == factor ? factor : nil
        }
        if appliedExposure != exposure { appliedExposure = exposure }
        if appliedZoom != zoom { appliedZoom = zoom }
    }

    /// Only the measurement camera opts in. Cancel before a newer preview tap
    /// or pan is submitted, keeping accepted state and ratio until the camera
    /// publishes its receipt. An idle pan frame causes no observable writes.
    func invalidatePendingRequestsForExternalIntent() {
        guard isApplying else { return }
        invalidateControlRequests()
    }

    private func invalidateControlRequests() {
        controlTask?.cancel()
        controlTask = nil
        queuedControls.removeAll()
        revision += 1
        requested = nil
        failure = nil
        isExecuting = false
    }

    func invalidate() {
        invalidateControlRequests()
        capabilities = .init()
        appliedExposure = nil
        appliedZoom = nil
    }
    func refreshCapabilities() async {
        invalidate()
        let token = revision
        do {
            let result = try await controller.capabilities()
            guard revision == token, !Task.isCancelled else { return }
            capabilities = result
            if let bias = result.exposureBias, result.exposure?.clamped(bias) == bias {
                appliedExposure = bias
            }
            if let factor = result.zoomFactor, factor > 0, result.zoom?.clamped(factor) == factor {
                appliedZoom = factor
            }
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            failure = (error as? DetailCameraControlFailure) ?? .deviceFailure
        }
    }
    func apply(_ request: DetailCameraControlRequest) async {
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
        switch request {
        case .exposure: limitedRequest = .exposure(limited)
        case .zoom: limitedRequest = .zoom(limited)
        }
        revision += 1
        let token = revision
        requested = request
        failure = nil
        isExecuting = true
        defer { if revision == token { isExecuting = false } }
        do {
            let applied = try await controller.apply(limitedRequest)
            guard revision == token, !Task.isCancelled else { return }
            guard applied.isFinite, (range.minimum...range.maximum).contains(applied) else {
                failure = .deviceFailure; return
            }
            switch request {
            case .exposure: appliedExposure = applied
            case .zoom: appliedZoom = applied
            }
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            failure = (error as? DetailCameraControlFailure) ?? .deviceFailure
        }
    }
    func resetExposure() async { await apply(.exposure(0)) }

    /// 드래그 중에는 최신 값만 대기시킨다. 패널을 닫아도 마지막 요청은 적용한다.
    func requestExposure(_ value: Double) {
        guard let limited = capabilities.exposure?.clamped(value) else { return }
        enqueue(.exposure(limited))
    }
    func requestZoom(_ value: Double) {
        guard value > 0, let limited = capabilities.zoom?.clamped(value) else { return }
        enqueue(.zoom(limited))
    }
    private func enqueue(_ request: DetailCameraControlRequest) {
        // 노출과 줌은 각각 마지막 요청을 보존해 메뉴 전환 중 서로 덮어쓰지 않는다.
        queuedControls.removeAll {
            switch ($0, request) {
            case (.exposure, .exposure), (.zoom, .zoom): true
            default: false
            }
        }
        queuedControls.append(request)
        guard controlTask == nil else { return }
        controlTask = Task {
            while !Task.isCancelled, !queuedControls.isEmpty {
                let next = queuedControls.removeFirst()
                await apply(next)
            }
            if !Task.isCancelled { controlTask = nil }
        }
    }
}
