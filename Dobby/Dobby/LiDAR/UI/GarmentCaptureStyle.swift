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
            .accessibilityHint(isReady ? "주황색 점이 표시되어 촬영할 수 있습니다"
                : "옷 윤곽이 인식되어 주황색 점이 나타나면 촬영할 수 있습니다")
            .accessibilityIdentifier("captureGarment")
    }
}
