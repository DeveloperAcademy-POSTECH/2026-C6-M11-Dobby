import ARKit
import SwiftUI

/// The panel displays provider capabilities; it never changes an ARKit camera directly.
struct CameraControlPanel: View {
    let capabilities: CameraControlCapabilities
    let state: CameraControlState
    var isEnabled = true
    var errorMessage: String? = nil
    var onExposure: (Double) -> Void
    var onResetExposure: () -> Void
    var onZoom: (CameraZoom) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach([CameraZoom.ultraWide, .standard, .double]) { zoom in
                    let supported = capabilities.availableZooms.contains(zoom)
                    Button { onZoom(zoom) } label: {
                        Text(zoom.label).font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.selectedZoom == zoom ? Color.black : .white)
                            .frame(width: 44, height: 44)
                            .background(state.selectedZoom == zoom ? Color.yellow : .white.opacity(0.12), in: Circle())
                            .contentShape(Circle())
                    }.buttonStyle(.plain)
                        .disabled(!isEnabled || !supported)
                        .opacity(supported ? 1 : 0.35)
                        .accessibilityLabel("\(zoom.label) 화각")
                        .accessibilityValue(supported ? (state.selectedZoom == zoom ? "선택됨" : "선택 안 됨") : "지원하지 않음")
                        .accessibilityHint(zoom == .ultraWide && !supported
                            ? "현재 LiDAR 촬영에서는 0.5배 화각을 지원하지 않아요"
                            : zoom == .double ? "촬영 미리보기를 두 배로 확대합니다" : "기본 촬영 화각입니다")
                        .accessibilityIdentifier("cameraZoom_\(zoom.rawValue)")
                }
            }
            if let range = capabilities.exposureRange, range.minimum < range.maximum {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        exposureValue
                        exposureSlider(range).frame(minWidth: 120)
                        resetExposure
                    }
                    VStack(spacing: 0) {
                        HStack { exposureValue; Spacer(minLength: 4); resetExposure }
                        exposureSlider(range)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cameraControlError")
            }
        }.frame(maxWidth: 380)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cameraControlPanel")
    }

    private var exposureValue: some View {
        Text(String(format: "EV %+.1f", state.exposureBias))
            .font(.caption.monospacedDigit()).foregroundStyle(.yellow)
            .fixedSize().accessibilityIdentifier("cameraExposureValue")
    }

    private func exposureSlider(_ range: CameraExposureRange) -> some View {
        Slider(value: Binding(get: { state.requestedExposureBias }, set: onExposure),
               in: range.minimum...range.maximum, step: 0.1)
            .tint(.yellow).disabled(!isEnabled)
            .accessibilityLabel("노출 보정")
            .accessibilityValue(String(format: "%+.1f EV", state.exposureBias))
            .accessibilityIdentifier("cameraExposureSlider")
    }

    private var resetExposure: some View {
        Button(action: onResetExposure) {
            Image(systemName: "arrow.counterclockwise").font(.subheadline)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!isEnabled)
            .accessibilityLabel("노출 보정 초기화")
            .accessibilityIdentifier("cameraExposureReset")
    }
}

/// Enlarge the actual preview bounds so taps still map through ARKit's display transform.
/// No AVCaptureDevice zoom changes or replacement RGB/depth streams are involved.
struct ZoomedCameraPreview: View {
    let session: ARSession
    let readiness: LiveCaptureReadiness
    @Binding var orientation: ImageOrientation
    var controlState: CameraControlState? = nil
    var focusEnabled = false
    var onFocus: ((ImagePoint) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let factor: CGFloat = controlState?.selectedZoom == .double ? 2 : 1
            CameraPreview(session: session, readiness: readiness, orientation: $orientation,
                controlState: controlState, focusEnabled: focusEnabled, onFocus: onFocus)
                .frame(width: geometry.size.width * factor, height: geometry.size.height * factor)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.clipped()
    }
}

/// An explicit synthetic preview uses this marker without claiming hardware autofocus.
struct SyntheticCameraFocusIndicator: View {
    let point: CGPoint

    var body: some View {
        RoundedRectangle(cornerRadius: 3).stroke(.yellow, lineWidth: 1.5)
            .frame(width: 64, height: 64).position(point)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("합성 미리보기 초점 조절 위치")
            .accessibilityIdentifier("cameraFocusIndicator")
    }
}
