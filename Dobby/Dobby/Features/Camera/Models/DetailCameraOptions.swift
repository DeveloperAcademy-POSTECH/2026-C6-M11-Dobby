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
    private(set) var isApplying = false
    // nil은 기존 원본 저장 유지. 비율 UI와 프리뷰를 함께 연결할 때 지정한다.
    var photoAspectRatio: DetailPhotoAspectRatio?
    @ObservationIgnored private let controller: any DetailCameraControlling
    @ObservationIgnored private var revision = 0

    init(controller: any DetailCameraControlling = UnavailableDetailCameraControls()) {
        self.controller = controller
    }
    func invalidate() {
        revision += 1
        capabilities = .init()
        requested = nil
        appliedExposure = nil
        appliedZoom = nil
        failure = nil
        isApplying = false
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
        isApplying = true
        defer { if revision == token { isApplying = false } }
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
}
