import SwiftUI

/// Shared photograph shutter. Readiness belongs to each camera owner; the
/// same assets, touch region and motion are used by measurement and detail.
struct CameraShutterControl: View {
    var isEnabled: Bool
    var isCapturing: Bool
    var showsReadyState = true
    var action: () -> Void
    var forceReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesReducedMotion: Bool { reduceMotion || forceReduceMotion }
    private var isReady: Bool { isEnabled && showsReadyState && !isCapturing }

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
        .buttonStyle(CameraShutterPressStyle(reduceMotion: usesReducedMotion))
        .disabled(!isReady)
        .accessibilityLabel(isCapturing ? "사진 처리 중" : "사진 촬영")
        .accessibilityValue(isCapturing ? "촬영 중" : isReady ? "촬영 가능" : "카메라 준비 중")
    }
}

private struct CameraShutterPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
