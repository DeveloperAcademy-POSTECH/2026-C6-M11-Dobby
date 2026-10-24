import ARKit
import SwiftUI
import UIKit

/// Camera errors stay below the preview; exposure belongs beside the focus box.
struct CameraControlPanel: View {
    var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cameraControlError")
            }
        }.frame(maxWidth: 380)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cameraControlPanel")
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
    var capabilities = CameraControlCapabilities.unavailable
    var onFocus: ((ImagePoint, UUID) -> Void)? = nil
    var onExposure: ((Double) -> Void)? = nil
    var onExposureAdjustmentActive: ((Bool) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let factor: CGFloat = controlState?.selectedZoom == .double ? 2 : 1
            CameraPreview(session: session, readiness: readiness, orientation: $orientation,
                controlState: controlState, focusEnabled: focusEnabled, capabilities: capabilities,
                onFocus: onFocus, onExposure: onExposure,
                onExposureAdjustmentActive: onExposureAdjustmentActive, visibleViewportSize: geometry.size)
                .frame(width: geometry.size.width * factor, height: geometry.size.height * factor)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.clipped()
    }
}

/// The fixture shares real recognizers and feedback drawing, but sends no
/// commands to AVCaptureDevice and cannot establish physical autofocus.
struct SyntheticCameraControlSurface: UIViewRepresentable {
    let state: CameraControlState
    let capabilities: CameraControlCapabilities
    let transform: CameraAffineTransform
    let isEnabled: Bool
    let focusVisible: Bool
    let onFocus: (ImagePoint, UUID) -> Void
    let onExposure: (Double) -> Void
    let onExposureAdjustmentActive: (Bool) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.state = state
        view.capabilities = capabilities
        view.transformMapping = transform
        view.controlsEnabled = isEnabled
        view.focusVisible = focusVisible
        view.onFocus = onFocus
        view.onExposure = onExposure
        view.onExposureAdjustmentActive = onExposureAdjustmentActive
        view.updateControls()
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.tearDown() }

    final class Surface: UIView {
        var state = CameraControlState()
        var capabilities = CameraControlCapabilities.unavailable
        var transformMapping = CameraAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        var controlsEnabled = false
        var focusVisible = false
        var onFocus: ((ImagePoint, UUID) -> Void)?
        var onExposure: ((Double) -> Void)?
        var onExposureAdjustmentActive: ((Bool) -> Void)?
        private lazy var renderer = CameraFocusIndicatorRenderer(containerView: self)
        private lazy var interaction = CameraPreviewInteraction(view: self)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func updateControls() {
            interaction.enabled = controlsEnabled && capabilities.focusSupported
            interaction.capabilities = capabilities
            interaction.visibleViewport = bounds
            interaction.sensorPoint = { [weak self] location in
                guard let self else { return nil }
                return CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: Double(location.x), y: Double(location.y)),
                    viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height), displayTransform: transformMapping)
            }
            interaction.onFocus = onFocus
            interaction.onExposure = onExposure
            interaction.onExposureAdjustmentActive = onExposureAdjustmentActive
            interaction.renderer = renderer
            interaction.pointLabel = "합성 미리보기 초점 요청 위치"
            interaction.reduceMotion = UIAccessibility.isReduceMotionEnabled
            interaction.synchronize(state: state, viewportHeight: Double(bounds.height))
            guard controlsEnabled, let feedback = interaction.focusFeedback(),
                  let displayed = CameraPreviewGeometry.displayPoint(sensorPoint: feedback.point,
                    viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height),
                    displayTransform: transformMapping) else {
                interaction.cancelAdjustment(); renderer.clear(); return
            }
            renderer.update(point: .init(x: displayed.x, y: displayed.y), requestID: feedback.requestID,
                pointLabel: "합성 미리보기 초점 요청 위치",
                exposureBias: interaction.presentationExposureBias, exposureRange: capabilities.exposureRange,
                onExposure: { [weak self] in self?.interaction.requestAccessibleExposure($0) },
                reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }
        override func layoutSubviews() { super.layoutSubviews(); updateControls() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { interaction.invalidateFocusFeedback() }
        }
        func tearDown() { interaction.tearDown(); renderer.tearDown() }
    }
}
