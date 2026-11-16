import SwiftUI

/// Shared camera surfaces, based on the three supplied Figma frames.
enum GarmentCaptureStyle {
    static let background = Color("CaptureBackground")
    static let accent = Color("CaptureAccent")
    static let recognition = Color("CaptureRecognition")
    static let guidance = Color("CaptureGuidance")
}

struct GarmentCaptureToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: Circle())
            .contentShape(.interaction, Rectangle())
    }
}

struct GarmentShutterButton: View {
    var isEnabled: Bool
    var isCapturing: Bool
    var showsRecognizedState = false
    var action: () -> Void
    var forceReduceMotion = false

    private var isReady: Bool { isEnabled && showsRecognizedState && !isCapturing }

    var body: some View {
        CameraShutterControl(isEnabled: isEnabled, isCapturing: isCapturing,
            showsReadyState: showsRecognizedState, action: action, forceReduceMotion: forceReduceMotion)
            .accessibilityLabel(isCapturing ? "실측 계산 중" : "실측 사진 촬영")
            .accessibilityValue(isCapturing ? "촬영 중" : isReady ? "촬영 가능" : "옷 인식 대기")
            .accessibilityHint(isReady ? "옷 윤곽을 인식했어요. 두 번 탭하면 실측 사진을 촬영합니다"
                : "촬영 안내에서 옷 인식 상태를 확인하고 옷 전체를 화면 안에 맞춰 주세요")
            .accessibilityIdentifier("captureGarment")
    }
}
