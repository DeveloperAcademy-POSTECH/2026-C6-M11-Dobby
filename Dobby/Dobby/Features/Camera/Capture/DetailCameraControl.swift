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
    var focusSupported = false
    var meteringSupported = false
}

/// AVCaptureVideoPreviewLayer가 반환한 센서 기준 지점. 표시용 좌표와 혼용하지 않는다.
nonisolated struct DetailCameraFocusPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        self.x = x
        self.y = y
    }
}

/// 버튼만 0.5x·1x·2x를 왕복한다. 핀치가 사용하는 기기 최대 배율과 분리한다.
nonisolated struct DetailZoomStops {
    private var descending = false
    mutating func next(from value: Double, range: DetailCameraControlRange) -> Double {
        let minimum = range.clamped(0.5) ?? value
        let maximum = range.clamped(2) ?? value
        // 높은 핀치 배율에서는 첫 탭으로 버튼의 상한에 복귀한 뒤 내려간다.
        if value > maximum + 0.001 { descending = true; return maximum }
        if value >= maximum - 0.001 { descending = true }
        if value <= minimum + 0.001 { descending = false }
        let target = descending ? (value > 1.001 ? 1 : minimum)
            : (value < 0.999 ? 1 : maximum)
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
    /// 제어기가 수락한 실제 설정값이다. AF/AE 수렴이나 첫 영상 프레임 반영을 보장하지 않는다.
    func apply(_ request: DetailCameraControlRequest) async throws -> Double
}
nonisolated protocol DetailCameraFocusing: Sendable {
    /// AF/AE 지점을 설정하고 EV를 0으로 초기화한다. 반환은 설정 접수이며 선명도 보증이 아니다.
    func focus(at point: DetailCameraFocusPoint) async throws -> DetailCameraCapabilities
}
nonisolated struct UnavailableDetailCameraControls: DetailCameraControlling, DetailCameraFocusing {
    func capabilities() async throws -> DetailCameraCapabilities { .init() }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        throw DetailCameraControlFailure.unsupported
    }
    func focus(at point: DetailCameraFocusPoint) async throws -> DetailCameraCapabilities {
        throw DetailCameraControlFailure.unsupported
    }
}
