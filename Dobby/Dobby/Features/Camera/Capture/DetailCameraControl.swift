// Created by mason on 10/21/26.
import Foundation

/// Mason 상세 촬영 내부 경계. 실측 카메라의 제어 계약과 독립적이다.
nonisolated struct DetailCameraControlRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double
    init?(minimum: Double, maximum: Double) {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        self.minimum = minimum
        self.maximum = maximum
    }
    func clamped(_ value: Double) -> Double? {
        value.isFinite ? min(max(value, minimum), maximum) : nil
    }
}

nonisolated struct DetailCameraCapabilities: Equatable, Sendable {
    var exposure: DetailCameraControlRange?
    var zoom: DetailCameraControlRange?
    var exposureBias: Double?
    var zoomFactor: Double?
}

/// 표시 배율 기준 왕복 순환. 초광각이 없는 기기는 0.5x를 건너뛴다.
nonisolated struct DetailZoomStops {
    private var descending = false
    mutating func next(from value: Double, range: DetailCameraControlRange) -> Double {
        if value >= range.maximum - 0.001 { descending = true }
        if value <= range.minimum + 0.001 { descending = false }
        let target = descending ? (value > 1.001 ? 1 : range.minimum)
            : (value < 0.999 ? 1 : range.maximum)
        return range.clamped(target) ?? value
    }
}
nonisolated enum DetailPhotoAspectRatio: String, CaseIterable, Sendable {
    case fourThree = "4:3", sixteenNine = "16:9", square = "1:1"

    func previewRatio(isLandscape: Bool) -> Double {
        let ratio: Double
        switch self {
        case .fourThree: ratio = 4.0 / 3
        case .sixteenNine: ratio = 16.0 / 9
        case .square: ratio = 1
        }
        return isLandscape ? ratio : 1 / ratio
    }
}
nonisolated enum DetailCameraControlRequest: Equatable, Sendable {
    case exposure(Double), zoom(Double)
}
nonisolated enum DetailCameraControlFailure: Error, Equatable, Sendable {
    case unsupported, invalidValue, unavailable, deviceFailure, operationInProgress
}
nonisolated protocol DetailCameraControlling: Sendable {
    func capabilities() async throws -> DetailCameraCapabilities
    /// 반환값은 요청값이 아닌 제어기가 확인한 실제 적용값이다.
    func apply(_ request: DetailCameraControlRequest) async throws -> Double
}
nonisolated struct UnavailableDetailCameraControls: DetailCameraControlling {
    func capabilities() async throws -> DetailCameraCapabilities { .init() }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        throw DetailCameraControlFailure.unsupported
    }
}
