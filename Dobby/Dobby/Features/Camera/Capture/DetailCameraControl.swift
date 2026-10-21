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
}
nonisolated enum DetailPhotoAspectRatio: String, CaseIterable, Sendable {
    case fourThree = "4:3", sixteenNine = "16:9", square = "1:1"
}
nonisolated enum DetailCameraControlRequest: Equatable, Sendable {
    case exposure(Double), zoom(Double)
}
nonisolated enum DetailCameraControlFailure: Error, Equatable, Sendable {
    case unsupported, invalidValue, unavailable, deviceFailure
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
