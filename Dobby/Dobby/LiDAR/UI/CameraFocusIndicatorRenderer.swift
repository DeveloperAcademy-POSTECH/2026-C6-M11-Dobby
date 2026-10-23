import UIKit

/// Focus feedback describes the requested position, never certified sharpness.
/// Exposure movement is drawn directly on this layer tree, independently of
/// SwiftUI updates and the garment-recognition frame cadence.
@MainActor
final class CameraFocusIndicatorRenderer {
    private weak var container: UIView?
    private let shape = CAShapeLayer()
    private let rail = CAShapeLayer()
    private let sun = UIImageView(image: UIImage(systemName: "sun.max.fill"))
    private let focusMarker = UIView()
    private let exposureMarker = CameraExposureAccessibilityMarker()
    private var activeID: UUID?
    private var dismissedID: UUID?
    private var expiry: DispatchWorkItem?
    private var dimming: DispatchWorkItem?
    private var adjusting = false
    private var viewport = CGRect.zero
    private var focusPoint = CGPoint.zero
    private var exposureBias = 0.0
    private var exposureRange: CameraExposureRange?

    // These are Dobby's motion values, not documented Camera-app constants.
    static let entranceScale: CGFloat = 1.4
    static let entranceDuration: TimeInterval = 0.22
    static let dimmingDelay: TimeInterval = 1.1
    static let dimmingDuration: TimeInterval = 0.28
    var isVisible: Bool { activeID != nil && !shape.isHidden }

    init(containerView: UIView) {
        container = containerView
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = UIColor.systemYellow.cgColor
        shape.lineWidth = 1.5
        shape.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        shape.isHidden = true
        containerView.layer.addSublayer(shape)
        rail.fillColor = UIColor.clear.cgColor
        rail.strokeColor = UIColor.systemYellow.withAlphaComponent(0.65).cgColor
        rail.lineWidth = 1
        rail.lineCap = .round
        rail.isHidden = true
        containerView.layer.addSublayer(rail)
        sun.tintColor = .systemYellow
        sun.contentMode = .scaleAspectFit
        sun.isUserInteractionEnabled = false
        sun.isAccessibilityElement = false
        sun.isHidden = true
        containerView.addSubview(sun)
        focusMarker.isUserInteractionEnabled = false
        focusMarker.isAccessibilityElement = true
        focusMarker.accessibilityIdentifier = "cameraFocusIndicator"
        focusMarker.accessibilityHint = "다른 곳을 누르면 초점을 옮기고 노출 보정을 초기화해요"
        focusMarker.isHidden = true
        containerView.addSubview(focusMarker)
        exposureMarker.isUserInteractionEnabled = false
        exposureMarker.isAccessibilityElement = true
        exposureMarker.accessibilityIdentifier = "cameraExposureControl"
        exposureMarker.accessibilityLabel = "노출 보정"
        exposureMarker.isHidden = true
        containerView.addSubview(exposureMarker)
    }

    func update(point: CGPoint, requestID: UUID, pointLabel: String = "초점 요청 위치",
                visibleViewport: CGRect? = nil, exposureBias: Double = 0,
                exposureRange: CameraExposureRange? = nil, onExposure: ((Double) -> Void)? = nil,
                reduceMotion: Bool) {
        guard requestID != dismissedID, let container else { return }
        let visible = (visibleViewport ?? container.bounds).intersection(container.bounds)
        guard point.x.isFinite, point.y.isFinite, !visible.isNull, !visible.isEmpty,
              point.x >= visible.minX, point.x <= visible.maxX,
              point.y >= visible.minY, point.y <= visible.maxY else { clear(); return }
        let isNew = activeID != requestID
        if isNew {
            expiry?.cancel(); dimming?.cancel()
            activeID = requestID
            restoreFeedbackOpacity()
            if !adjusting { scheduleExpiry(requestID: requestID) }
        }
        viewport = visible
        focusPoint = point
        self.exposureRange = exposureRange
        self.exposureBias = exposureRange?.clamp(exposureBias) ?? 0
        let rect = CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Local geometry keeps scale animation centered on the tapped point.
        // Accessibility and the sun's 44-point target never scale with it.
        shape.position = point
        shape.path = UIBezierPath(roundedRect: shape.bounds, cornerRadius: 2).cgPath
        shape.isHidden = false
        focusMarker.frame = rect
        focusMarker.accessibilityLabel = pointLabel
        focusMarker.accessibilityValue = "초점 조절 요청"
        focusMarker.isHidden = false
        exposureMarker.onExposure = onExposure
        drawExposure()
        CATransaction.commit()
        if reduceMotion {
            shape.removeAnimation(forKey: "focusEntrance")
        } else if isNew {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = Self.entranceScale
            scale.toValue = 1
            scale.duration = Self.entranceDuration
            scale.beginTime = shape.convertTime(CACurrentMediaTime(), from: nil)
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(scale, forKey: "focusEntrance")
        }
    }

    func setExposureBias(_ value: Double) {
        guard isVisible, let value = exposureRange?.clamp(value) else { return }
        exposureBias = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawExposure()
        CATransaction.commit()
    }

    func beginAdjustment() {
        guard isVisible else { return }
        adjusting = true
        expiry?.cancel(); expiry = nil
        dimming?.cancel(); dimming = nil
        restoreFeedbackOpacity()
    }

    func endAdjustment() {
        adjusting = false
        guard let activeID else { return }
        scheduleExpiry(requestID: activeID)
    }

    private func drawExposure() {
        guard viewport.width >= 44, viewport.height >= 44,
              let range = exposureRange, range.minimum < range.maximum,
              exposureMarker.onExposure != nil,
              let handle = CameraPreviewGeometry.exposureHandleCenter(
                focusPoint: .init(x: Double(focusPoint.x), y: Double(focusPoint.y)),
                viewportOrigin: .init(x: Double(viewport.minX), y: Double(viewport.minY)),
                viewportWidth: Double(viewport.width), viewportHeight: Double(viewport.height)) else {
            rail.isHidden = true; sun.isHidden = true; exposureMarker.isHidden = true
            exposureMarker.configure(bias: 0, range: nil)
            return
        }
        let height = min(96, max(0, viewport.height - 44))
        let centerY = min(viewport.maxY - height / 2 - 22,
                          max(viewport.minY + height / 2 + 22, CGFloat(handle.y)))
        let x = min(viewport.maxX - 22, max(viewport.minX + 22, CGFloat(handle.x)))
        let top = centerY - height / 2
        let progress = (exposureBias - range.minimum) / (range.maximum - range.minimum)
        let y = top + (1 - CGFloat(progress)) * height
        let path = UIBezierPath()
        path.move(to: .init(x: x, y: top)); path.addLine(to: .init(x: x, y: top + height))
        rail.path = path.cgPath; rail.isHidden = false
        sun.frame = .init(x: x - 10, y: y - 10, width: 20, height: 20)
        sun.isHidden = false
        // The visible glyph is small; its accessible target remains 44 points.
        exposureMarker.frame = .init(x: x - 22, y: y - 22, width: 44, height: 44)
        exposureMarker.configure(bias: exposureBias, range: range)
        exposureMarker.isHidden = false
    }

    private func restoreFeedbackOpacity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shape, rail, sun.layer] {
            layer.removeAnimation(forKey: "focusDimming")
            layer.opacity = 1
        }
        CATransaction.commit()
    }

    private func scheduleExpiry(requestID: UUID) {
        expiry?.cancel(); dimming?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        let dim = DispatchWorkItem { [weak self] in
            guard let self, activeID == requestID, !adjusting, !UIAccessibility.isVoiceOverRunning else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [shape, rail, sun.layer] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = 0.55
                fade.duration = Self.dimmingDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.opacity = 0.55
                layer.add(fade, forKey: "focusDimming")
            }
            CATransaction.commit()
        }
        dimming = dim
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dimmingDelay, execute: dim)
        let work = DispatchWorkItem { [weak self] in
            guard self?.activeID == requestID, self?.adjusting == false,
                  !UIAccessibility.isVoiceOverRunning else { return }
            self?.clear()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func clear() {
        expiry?.cancel(); expiry = nil
        dimming?.cancel(); dimming = nil
        dismissedID = activeID ?? dismissedID
        activeID = nil; adjusting = false
        shape.removeAllAnimations(); rail.removeAllAnimations(); sun.layer.removeAllAnimations()
        shape.isHidden = true; rail.isHidden = true; sun.isHidden = true
        focusMarker.isHidden = true; exposureMarker.isHidden = true
        exposureMarker.onExposure = nil
        exposureMarker.configure(bias: 0, range: nil)
    }

    func tearDown() {
        clear()
        shape.removeFromSuperlayer(); rail.removeFromSuperlayer()
        sun.removeFromSuperview(); focusMarker.removeFromSuperview(); exposureMarker.removeFromSuperview()
    }
}

@MainActor
private final class CameraExposureAccessibilityMarker: UIView {
    var onExposure: ((Double) -> Void)?
    private var bias = 0.0
    private var range: CameraExposureRange?

    func configure(bias: Double, range: CameraExposureRange?) {
        self.bias = bias
        self.range = range
        accessibilityTraits = range != nil && onExposure != nil ? [.adjustable] : []
        accessibilityHint = "위아래로 쓸어 밝기를 조절해요. 새 위치를 누르면 초기화해요"
        accessibilityValue = String(format: "EV %+.1f", bias)
    }
    override func accessibilityIncrement() { adjust(by: 0.1) }
    override func accessibilityDecrement() { adjust(by: -0.1) }
    private func adjust(by step: Double) {
        guard !isHidden, let target = range?.clamp(bias + step), target != bias, let onExposure else { return }
        bias = target
        accessibilityValue = String(format: "EV %+.1f", target)
        onExposure(target)
    }
}

/// UIKit owns the complete gesture, local feedback and the final value. No
/// recognition result or SwiftUI render is needed to move the exposure handle.
@MainActor
final class CameraPreviewInteraction: NSObject, UIGestureRecognizerDelegate {
    weak var view: UIView?
    weak var renderer: CameraFocusIndicatorRenderer?
    var enabled = false { didSet { if !enabled { invalidateFocusFeedback() } } }
    var capabilities = CameraControlCapabilities.unavailable {
        didSet { if oldValue.exposureRange != capabilities.exposureRange { cancelAdjustment() } }
    }
    var visibleViewport: CGRect? {
        didSet { if oldValue != visibleViewport { invalidateFocusFeedback() } }
    }
    var sensorPoint: ((CGPoint) -> ImagePoint?)?
    var onFocus: ((ImagePoint, UUID) -> Void)?
    var onExposure: ((Double) -> Void)?
    var onExposureAdjustmentActive: ((Bool) -> Void)?
    var pointLabel = "초점 요청 위치"
    var reduceMotion = false
    private struct LocalFocus {
        let point: ImagePoint
        let requestID: UUID
        var acknowledged = false
    }
    private var localFocus: LocalFocus?
    private var retiredFocusIDs: [UUID] = []
    private(set) var presentationExposureBias = 0.0
    private(set) var isAdjustingExposure = false
    private var state: CameraControlState?
    private var viewportHeight = 0.0
    private var exposureStart = 0.0
    private var lastBounds = CGRect.zero
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))

    init(view: UIView) {
        self.view = view
        super.init()
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        // A pan can never finish as a fresh focus tap that would reset EV.
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(pan)
    }

    func synchronize(state: CameraControlState?, viewportHeight: Double) {
        let sessionChanged = self.state?.sessionID != state?.sessionID
        let boundsChanged = view?.bounds != lastBounds
        if sessionChanged || boundsChanged {
            invalidateFocusFeedback()
            if let bounds = view?.bounds { lastBounds = bounds }
        }
        let previousState = self.state
        let isOlderFocus: Bool
        if var local = localFocus {
            if state?.focusRequestID == local.requestID {
                local.acknowledged = true
                localFocus = local
                isOlderFocus = false
                if state?.focusStatus != .requested && state?.focusStatus != .accepted {
                    invalidateFocusFeedback()
                }
            } else if !local.acknowledged || state?.focusRequestID.map(retiredFocusIDs.contains) == true {
                // A queued nil/old-focus SwiftUI update cannot erase a tap
                // that UIKit has already displayed and submitted.
                isOlderFocus = true
            } else {
                invalidateFocusFeedback()
                isOlderFocus = false
            }
        } else {
            isOlderFocus = state?.focusRequestID.map(retiredFocusIDs.contains) == true
        }
        self.state = state
        self.viewportHeight = viewportHeight
        guard !isOlderFocus, !isAdjustingExposure else { return }
        if sessionChanged || previousState?.focusRequestID != state?.focusRequestID
            || previousState?.requestedExposureBias != state?.requestedExposureBias
            || previousState?.requestedExposureRevision != state?.requestedExposureRevision {
            presentationExposureBias = capabilities.exposureRange?.clamp(state?.requestedExposureBias ?? 0) ?? 0
        }
    }

    struct FocusFeedback {
        let point: ImagePoint
        let requestID: UUID
    }

    func focusFeedback() -> FocusFeedback? {
        if let localFocus { return .init(point: localFocus.point, requestID: localFocus.requestID) }
        guard let state, state.focusStatus == .requested || state.focusStatus == .accepted,
              let point = state.focusPoint, let requestID = state.focusRequestID,
              !retiredFocusIDs.contains(requestID) else { return nil }
        return .init(point: point, requestID: requestID)
    }

    private func retire(_ requestID: UUID?) {
        guard let requestID, !retiredFocusIDs.contains(requestID) else { return }
        retiredFocusIDs.append(requestID)
        if retiredFocusIDs.count > 16 { retiredFocusIDs.removeFirst(retiredFocusIDs.count - 16) }
    }

    func invalidateFocusFeedback() {
        cancelAdjustment()
        retire(localFocus?.requestID)
        retire(state?.focusRequestID)
        localFocus = nil
        renderer?.clear()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view else { return }
        focus(at: recognizer.location(in: view))
    }

    func focus(at location: CGPoint) {
        guard enabled, capabilities.focusSupported, validLocation(location),
              let point = sensorPoint?(location), point.isValid, let onFocus else { return }
        cancelAdjustment()
        retire(localFocus?.requestID)
        retire(state?.focusRequestID)
        let requestID = UUID()
        localFocus = .init(point: point, requestID: requestID)
        presentationExposureBias = capabilities.exposureRange?.clamp(0) ?? 0
        // Draw before calling the provider. Neither its queue nor SwiftUI is
        // part of the latency between a recognized tap and visual feedback.
        renderer?.update(point: location, requestID: requestID, pointLabel: pointLabel,
            visibleViewport: visibleViewport, exposureBias: presentationExposureBias,
            exposureRange: capabilities.exposureRange,
            onExposure: { [weak self] in self?.requestAccessibleExposure($0) }, reduceMotion: reduceMotion)
        onFocus(point, requestID)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return enabled }
        guard let view else { return false }
        let velocity = pan.velocity(in: view)
        return exposureCanBegin(at: pan.location(in: view)) && abs(velocity.y) > abs(velocity.x)
    }

    private func exposureCanBegin(at location: CGPoint) -> Bool {
        enabled && validLocation(location) && renderer?.isVisible == true
            && focusFeedback() != nil
            && capabilities.exposureRange.map { $0.minimum < $0.maximum } == true
            && onExposure != nil && viewportHeight.isFinite && viewportHeight > 0
    }

    @discardableResult
    func beginExposure(at location: CGPoint) -> Bool {
        guard exposureCanBegin(at: location) else { return false }
        exposureStart = presentationExposureBias
        isAdjustingExposure = true
        renderer?.beginAdjustment()
        onExposureAdjustmentActive?(true)
        return true
    }

    func changeExposure(translationY: Double) {
        guard isAdjustingExposure, let range = capabilities.exposureRange,
              let target = CameraExposureGesture.bias(start: exposureStart, translationY: translationY,
                viewportHeight: viewportHeight, range: range) else { return }
        presentationExposureBias = target
        renderer?.setExposureBias(target)
        onExposure?(target)
    }

    func endExposure(translationY: Double) {
        guard isAdjustingExposure else { return }
        // Include the final finger position before the provider flushes its
        // latest value; never recompute from a late hardware receipt.
        changeExposure(translationY: translationY)
        finishAdjustment()
    }

    func requestAccessibleExposure(_ bias: Double) {
        guard enabled, renderer?.isVisible == true, let target = capabilities.exposureRange?.clamp(bias),
              onExposure != nil else { return }
        renderer?.beginAdjustment()
        onExposureAdjustmentActive?(true)
        presentationExposureBias = target
        renderer?.setExposureBias(target)
        onExposure?(target)
        onExposureAdjustmentActive?(false)
        renderer?.endAdjustment()
    }

    func cancelAdjustment() {
        guard isAdjustingExposure else { return }
        finishAdjustment()
        // Cancel UIKit's active pan too, so a changed event after rotation or
        // capture cannot submit another value for the previous viewport.
        pan.isEnabled = false; pan.isEnabled = true
    }

    private func finishAdjustment() {
        isAdjustingExposure = false
        onExposureAdjustmentActive?(false)
        renderer?.endAdjustment()
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        switch recognizer.state {
        case .began:
            if beginExposure(at: recognizer.location(in: view)) {
                changeExposure(translationY: Double(recognizer.translation(in: view).y))
            }
        case .changed: changeExposure(translationY: Double(recognizer.translation(in: view).y))
        case .ended: endExposure(translationY: Double(recognizer.translation(in: view).y))
        case .cancelled, .failed: cancelAdjustment()
        default: break
        }
    }

    private func validLocation(_ location: CGPoint) -> Bool {
        guard let view, location.x.isFinite, location.y.isFinite else { return false }
        let viewport = (visibleViewport ?? view.bounds).intersection(view.bounds)
        return !viewport.isNull && !viewport.isEmpty && location.x >= viewport.minX && location.x <= viewport.maxX
            && location.y >= viewport.minY && location.y <= viewport.maxY
    }

    func tearDown() {
        invalidateFocusFeedback()
        view?.removeGestureRecognizer(tap); view?.removeGestureRecognizer(pan)
        sensorPoint = nil; onFocus = nil; onExposure = nil; onExposureAdjustmentActive = nil
        renderer = nil
    }
}
