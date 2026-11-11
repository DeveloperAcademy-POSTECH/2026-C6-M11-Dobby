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
                // Render exactly one asset: layering their translucent outlines
                // would brighten the ring when the shutter becomes ready.
                Image(isReady ? "MeasurementShutterReady" : "MeasurementShutterIdle")
                    .resizable().scaledToFit().frame(width: 98, height: 98)
                    .accessibilityHidden(true)
                if isCapturing { ProgressView().tint(.white).transition(.opacity) }
            }.frame(width: 98, height: 98)
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
