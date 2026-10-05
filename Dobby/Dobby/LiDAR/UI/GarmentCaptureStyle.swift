import SwiftUI

/// Shared camera surfaces, based on the three supplied Figma frames.
enum GarmentCaptureStyle {
    static let background = Color("CaptureBackground")
    static let accent = Color("CaptureAccent")
    static let recognition = Color("CaptureRecognition")
}

struct GarmentCaptureToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: Circle())
    }
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
                // Reuse the original Figma shutter already bundled by the
                // detail-camera feature. Its export includes shadow margins.
                Image("CameraShutter").resizable().frame(width: 152, height: 118)
                    .offset(x: 12, y: 7).frame(width: 92, height: 92)
                    .accessibilityHidden(true)
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
        .accessibilityHint(isEnabled ? "인식을 기다리지 않고 사진을 촬영한 뒤 옷 종류와 길이를 확인합니다" : "카메라가 준비되면 촬영할 수 있습니다")
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
