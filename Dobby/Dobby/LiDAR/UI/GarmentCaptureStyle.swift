import SwiftUI

/// Shared camera surfaces, based on the three supplied Figma frames.
enum GarmentCaptureStyle {
    static let background = Color("CaptureBackground")
    static let accent = Color("CaptureAccent")
    static let recognition = Color("CaptureRecognition")
}

struct GarmentShutterButton: View {
    var isEnabled: Bool
    var isCapturing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(0.12).gradient)
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                Circle().stroke(.white.opacity(0.22), lineWidth: 0.7).padding(8)
                Circle().stroke(.white.opacity(0.15), lineWidth: 0.7).padding(16)
                Circle().fill(GarmentCaptureStyle.accent.gradient)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.7), radius: 3, y: 2)
                    .padding(31)
                if isCapturing { ProgressView().tint(.white) }
            }.frame(width: 92, height: 92)
                .opacity(isEnabled || isCapturing ? 1 : 0.45)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isCapturing)
        .accessibilityLabel(isCapturing ? "실측 계산 중" : "실측 사진 촬영")
        .accessibilityHint(isEnabled ? "인식한 옷을 촬영하고 길이를 계산합니다" : "옷 인식과 깊이 준비 후 촬영할 수 있습니다")
        .accessibilityIdentifier("captureGarment")
    }
}
