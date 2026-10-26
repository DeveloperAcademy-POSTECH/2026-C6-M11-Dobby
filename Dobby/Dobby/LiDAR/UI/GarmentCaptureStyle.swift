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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesReducedMotion: Bool { reduceMotion || forceReduceMotion }
    private var isReady: Bool { isEnabled && showsRecognizedState && !isCapturing }

    var body: some View {
        Button {
            guard isReady else { return }
            action()
        } label: {
            ZStack {
                Image("MeasurementShutterIdle")
                    .resizable().scaledToFit().frame(width: 92, height: 92)
                    .accessibilityHidden(true)
                // Animate only the original asset's 25pt center. The ring and
                // its 92pt touch region stay still while orange softly appears.
                Image("MeasurementShutterReady")
                    .resizable().scaledToFit().frame(width: 92, height: 92)
                    .mask { Circle().frame(width: 25, height: 25).offset(x: 0.5, y: 0.5) }
                    .scaleEffect(isReady ? 1 : 0.65)
                    .opacity(isReady ? 1 : 0)
                    .animation(usesReducedMotion || !isReady ? nil
                        : .spring(response: 0.24, dampingFraction: 0.85), value: isReady)
                    .accessibilityHidden(true)
                if isCapturing { ProgressView().tint(.white).transition(.opacity) }
            }.frame(width: 92, height: 92)
                .opacity(isEnabled || isCapturing ? 1 : 0.45)
                .animation(usesReducedMotion || !isEnabled ? nil : .easeInOut(duration: 0.20), value: isEnabled)
                .animation(usesReducedMotion ? nil : .easeOut(duration: 0.16), value: isCapturing)
                .contentShape(Circle())
        }
        .buttonStyle(GarmentShutterPressStyle(reduceMotion: usesReducedMotion))
        .disabled(!isReady)
        .accessibilityLabel(isCapturing ? "실측 계산 중" : "실측 사진 촬영")
        .accessibilityValue(isCapturing ? "촬영 중" : isReady ? "촬영 가능" : "옷 인식 대기")
        .accessibilityHint(isReady ? "주황색 점이 표시되어 촬영할 수 있습니다" : "옷 윤곽이 인식되어 주황색 점이 나타나면 촬영할 수 있습니다")
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
