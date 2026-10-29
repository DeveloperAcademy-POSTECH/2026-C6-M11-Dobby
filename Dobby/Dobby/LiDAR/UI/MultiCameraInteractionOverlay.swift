import SwiftUI
import UIKit

/// Transparent controls/outline only. Camera pixels are drawn once, behind
/// this central photo window, by the synchronized calibrated RGB Metal renderer.
struct MultiCameraInteractionOverlay: UIViewRepresentable {
    let frames: MultiCameraFrameStore
    let readiness: LiveCaptureReadiness
    @Binding var orientation: ImageOrientation
    let imageSize: PixelSize
    let controlState: CameraControlState
    let capabilities: CameraControlCapabilities
    let focusEnabled: Bool
    let onFocus: (ImagePoint, UUID) -> Void
    let onExposure: (Double) -> Void
    let onExposureAdjustmentActive: (Bool) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        view.frames = frames
        view.readiness = readiness
        view.orientation = orientation
        view.imageSize = imageSize
        view.state = controlState
        view.capabilities = capabilities
        view.controlsEnabled = focusEnabled
        view.onFocus = onFocus
        view.onExposure = onExposure
        view.onExposureAdjustmentActive = onExposureAdjustmentActive
        view.onOrientation = { orientation = $0 }
        view.updateControls()
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.tearDown() }

    final class Surface: UIView {
        var frames: MultiCameraFrameStore?
        var readiness = LiveCaptureReadiness.waiting
        var orientation = ImageOrientation.right
        var imageSize = PixelSize(width: 1920, height: 1440)
        var state = CameraControlState()
        var capabilities = CameraControlCapabilities.unavailable
        var controlsEnabled = false
        var onFocus: ((ImagePoint, UUID) -> Void)?
        var onExposure: ((Double) -> Void)?
        var onExposureAdjustmentActive: ((Bool) -> Void)?
        var onOrientation: ((ImageOrientation) -> Void)?
        private let outlineContainer = CALayer()
        private let fallbackEpoch = UUID()
        private lazy var outline = GarmentSilhouetteLayerRenderer(containerLayer: outlineContainer)
        private lazy var focus = CameraFocusIndicatorRenderer(containerView: self)
        private lazy var interaction = CameraPreviewInteraction(view: self)
        private var previousSize: CGSize?
        private var previousSession: UUID?
        private var previousZoom: CameraZoom?
        private var previousOrientation: ImageOrientation?
        private var reduceMotionObserver: NSObjectProtocol?
        private var isTornDown = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            clipsToBounds = true
            isAccessibilityElement = false
            outlineContainer.masksToBounds = true
            layer.addSublayer(outlineContainer)
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateControls() } }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func updateControls() {
            guard !isTornDown, bounds.width > 0, bounds.height > 0,
                  let mapping = MultiCameraPreviewGeometry.make(imageSize: imageSize,
                    photoRect: bounds, orientation: orientation, zoom: state.selectedZoom) else {
                outline.clear(); focus.clear(); return
            }
            let changed = previousSize != bounds.size || previousSession != state.sessionID
                || previousZoom != state.selectedZoom || previousOrientation != orientation
            if changed {
                interaction.invalidateFocusFeedback()
                outline.clear()
                previousSize = bounds.size; previousSession = state.sessionID
                previousZoom = state.selectedZoom; previousOrientation = orientation
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outlineContainer.frame = bounds
            CATransaction.commit()
            interaction.enabled = controlsEnabled && capabilities.focusSupported
            interaction.capabilities = capabilities
            interaction.visibleViewport = bounds
            interaction.sensorPoint = { [weak self] point in
                guard let self else { return nil }
                return CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: Double(point.x), y: Double(point.y)),
                    viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height),
                    displayTransform: mapping.photoTransform)
            }
            interaction.onFocus = onFocus
            interaction.onExposure = onExposure
            interaction.onExposureAdjustmentActive = onExposureAdjustmentActive
            interaction.renderer = focus
            interaction.pointLabel = "초점 요청 위치"
            interaction.reduceMotion = UIAccessibility.isReduceMotionEnabled
            interaction.synchronize(state: state, viewportHeight: Double(bounds.height))
            if controlsEnabled, let feedback = interaction.focusFeedback(),
               let point = CameraPreviewGeometry.displayPoint(sensorPoint: feedback.point,
                    viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height),
                    displayTransform: mapping.photoTransform) {
                focus.update(point: CGPoint(x: point.x, y: point.y), requestID: feedback.requestID,
                    pointLabel: "초점 요청 위치", visibleViewport: bounds,
                    exposureBias: interaction.presentationExposureBias, exposureRange: capabilities.exposureRange,
                    onExposure: { [weak self] in self?.interaction.requestAccessibleExposure($0) },
                    reduceMotion: UIAccessibility.isReduceMotionEnabled)
            } else { focus.clear() }
            if let mask = readiness.silhouette, readiness.imageOrientation == orientation,
               let timestamp = frames?.latest()?.timestamp,
               timestamp >= readiness.timestamp, timestamp - readiness.timestamp <= 2 {
                let color = UIColor(named: "CaptureRecognition") ?? .systemMint
                outline.update(mask: mask,
                    identity: .init(epoch: readiness.analysisEpoch ?? fallbackEpoch,
                        timestamp: readiness.timestamp, orientation: orientation),
                    transform: mapping.sensorToCanvas, viewport: bounds,
                    fillColor: color.withAlphaComponent(0.40).cgColor, strokeColor: color.cgColor,
                    reduceMotion: UIAccessibility.isReduceMotionEnabled, gradientEndColor: UIColor.white.cgColor)
            } else { outline.clear() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let interface = window?.windowScene?.effectiveGeometry.interfaceOrientation {
                let value: ImageOrientation
                switch interface {
                case .portraitUpsideDown: value = .left
                case .landscapeLeft: value = .down
                case .landscapeRight: value = .up
                default: value = .right
                }
                if value != orientation {
                    interaction.invalidateFocusFeedback(); outline.clear()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !isTornDown, window != nil else { return }
                        onOrientation?(value)
                    }
                    return
                }
            }
            updateControls()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { interaction.invalidateFocusFeedback(); outline.clear() }
            else { setNeedsLayout() }
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            interaction.tearDown(); focus.tearDown(); outline.tearDown()
            if let reduceMotionObserver { NotificationCenter.default.removeObserver(reduceMotionObserver) }
            reduceMotionObserver = nil
            frames = nil; onFocus = nil; onExposure = nil
            onExposureAdjustmentActive = nil; onOrientation = nil
        }
    }
}
