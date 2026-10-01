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
    var forceReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesReducedMotion: Bool { reduceMotion || forceReduceMotion }

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
                if isCapturing { ProgressView().tint(.white).transition(.opacity) }
            }.frame(width: 92, height: 92)
                .opacity(isEnabled || isCapturing ? 1 : 0.45)
                .animation(usesReducedMotion || !isEnabled ? nil : .easeInOut(duration: 0.20), value: isEnabled)
                .animation(usesReducedMotion ? nil : .easeOut(duration: 0.16), value: isCapturing)
                .contentShape(Circle())
        }
        .buttonStyle(GarmentShutterPressStyle(reduceMotion: usesReducedMotion))
        .disabled(!isEnabled || isCapturing)
        .accessibilityLabel(isCapturing ? "실측 계산 중" : "실측 사진 촬영")
        .accessibilityHint(isEnabled ? "사진을 촬영하고 옷 종류와 길이를 확인합니다" : "카메라와 깊이가 준비되면 촬영할 수 있습니다")
        .accessibilityIdentifier("captureGarment")
    }
}

private struct GarmentShutterPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
