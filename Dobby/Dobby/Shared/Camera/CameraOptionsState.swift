// Created by mason on 10/28/26.
import Foundation

/// 화면은 값과 콜백만 받는다. 카메라 수명·실제 장치 적용은 호출 화면이 소유한다.
struct CameraOptionsState {
    var exposureRange: ClosedRange<Double>?
    var appliedExposure: Double?
    var isApplying = false
    var hasExposureFailure = false
    var selectedAspectRatio = "4:3"
    var aspectRatios: [String] = []
}
