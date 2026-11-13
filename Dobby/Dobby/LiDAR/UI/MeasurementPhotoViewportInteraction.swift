import SwiftUI
import UIKit

struct MeasurementPhotoPointTarget: Equatable {
    let id: String
    let center: CGPoint
}

/// Coordinates photo navigation and point editing from one touch stream. The
/// surface itself passes hits through so the SwiftUI point buttons retain taps
/// and accessibility actions.
struct MeasurementPhotoViewportInteraction: UIViewRepresentable {
    let viewport: MeasurementPhotoViewport
    let pointTargets: [MeasurementPhotoPointTarget]
    let excludedRects: [CGRect]
    let interactionID: UUID
    let isEnabled: Bool
    let onViewportGestureBegan: () -> Void
    let onViewportChange: (MeasurementPhotoViewport) -> Void
    let onPointDragBegan: (String) -> Void
    let onPointDragChanged: (String, CGSize) -> Void
    let onPointDragEnded: (String) -> Void
    let onPointDragCancelled: () -> Void

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.update(self)
        return surface
    }

    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.update(self)
    }

    static func dismantleUIView(_ uiView: Surface, coordinator: ()) {
        uiView.tearDown()
    }

    final class Surface: UIView {
        private let interaction = PhotoGestureRecognizer(target: nil, action: nil)
        private var isTornDown = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            interaction.coordinateView = self
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // The recognizer lives on a common ancestor, so this view never needs
        // to intercept a point button or introduce an accessibility element.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

        func update(_ configuration: MeasurementPhotoViewportInteraction) {
            guard !isTornDown else { return }
            interaction.update(configuration)
            synchronizeAttachment()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            interaction.updateBounds(bounds)
            synchronizeAttachment()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            synchronizeAttachment()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronizeAttachment()
        }

        private func synchronizeAttachment() {
            guard !isTornDown, window != nil, let ancestor = controllerViewAncestor() else {
                detach()
                return
            }
            interaction.updateBounds(bounds)
            guard interaction.view !== ancestor else { return }
            detach()
            ancestor.addGestureRecognizer(interaction)
        }

        private func controllerViewAncestor() -> UIView? {
            // Use the public responder chain rather than a window-wide
            // recognizer or assumptions about SwiftUI's private view classes.
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController,
                   let candidate = controller.viewIfLoaded,
                   isDescendant(of: candidate) {
                    return candidate
                }
                responder = current.next
            }
            return nil
        }

        private func detach() {
            guard let ancestor = interaction.view else { return }
            interaction.cancelSession()
            ancestor.removeGestureRecognizer(interaction)
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            interaction.cancelSession()
            detach()
            interaction.clearConfiguration()
        }
    }
}

private final class PhotoGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private enum Mode {
        case pendingPoint(id: String, origin: CGPoint)
        case pointDrag(id: String, origin: CGPoint)
        case pendingPan(origin: CGPoint, viewport: MeasurementPhotoViewport)
        case pan(origin: CGPoint, viewport: MeasurementPhotoViewport)
        case pinch(first: UITouch, second: UITouch, distance: CGFloat,
                   midpoint: CGPoint, viewport: MeasurementPhotoViewport)
        case ignored
    }

    weak var coordinateView: UIView?
    private var configuration: MeasurementPhotoViewportInteraction?
    private var knownBounds = CGRect.zero
    private var sessionBounds = CGRect.zero
    private var sessionID = UUID()
    private var trackedTouches: [UITouch] = []
    // Admission callbacks for two new fingers can both arrive before UIKit
    // delivers touchesBegan. Keep those approved touches until delivery/end.
    private var admittedTouches: [UITouch] = []
    private var mode: Mode?
    private var latestViewport: MeasurementPhotoViewport?
    private var usedMultipleTouches = false
    private var viewportGestureHasBegun = false
    private let dragThreshold: CGFloat = 2
    private let pointHitRadius: CGFloat = 28

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ value: MeasurementPhotoViewportInteraction) {
        let invalidatesSession = configuration.map {
            $0.interactionID != value.interactionID || ($0.isEnabled && !value.isEnabled)
        } ?? false
        configuration = value
        if invalidatesSession { cancelSession() }
        isEnabled = value.isEnabled
    }

    func updateBounds(_ bounds: CGRect) {
        if bounds != knownBounds {
            knownBounds = bounds
            cancelSession()
        }
    }

    func clearConfiguration() {
        configuration = nil
        coordinateView = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard state == .possible || state == .began || state == .changed,
              configuration?.isEnabled == true, let coordinateView,
              coordinateView.window != nil,
              coordinateView.bounds.width > 0, coordinateView.bounds.height > 0 else { return false }
        let location = touch.location(in: coordinateView)
        let isAdmitted = location.x.isFinite && location.y.isFinite
            && coordinateView.bounds.contains(location)
            && !(configuration?.excludedRects.contains { $0.contains(location) } ?? true)
        guard isAdmitted else {
            // Reject the outside/control touch itself so it remains available
            // to its original view, but discard any photo point preview.
            if !trackedTouches.isEmpty || !admittedTouches.isEmpty { cancelSession() }
            return false
        }
        if !admittedTouches.contains(where: { $0 === touch }) {
            admittedTouches.append(touch)
        }
        return true
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A SwiftUI button may begin tracking a press before a second finger
        // arrives. Keep observing that stream so a pinch can cancel its point
        // preview; a simple tap still fails this recognizer on touch-up.
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible || state == .began || state == .changed,
              let configuration, configuration.isEnabled, let coordinateView else { return }
        if trackedTouches.isEmpty {
            sessionID = UUID()
            sessionBounds = coordinateView.bounds
            latestViewport = configuration.viewport
            usedMultipleTouches = false
            viewportGestureHasBegun = false
        }
        for touch in touches where !trackedTouches.contains(where: { $0 === touch }) {
            trackedTouches.append(touch)
        }
        guard validSession(), !cancelForUnadmittedActiveTouches(in: event) else { return }
        if trackedTouches.count >= 2 {
            usedMultipleTouches = true
            beginPinch()
        } else if let first = trackedTouches.first {
            let origin = first.location(in: coordinateView)
            if let target = nearestPoint(to: origin, in: configuration.pointTargets) {
                mode = .pendingPoint(id: target.id, origin: origin)
            } else if configuration.viewport.isZoomed {
                mode = .pendingPan(origin: origin, viewport: configuration.viewport)
            } else {
                mode = .ignored
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard validSession(), !cancelForUnadmittedActiveTouches(in: event) else { return }
        updateCurrentMode()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard validSession(), !cancelForUnadmittedActiveTouches(in: event) else { return }
        // Include the final finger position before deciding whether this was a
        // completed one-finger edit or a navigation stream.
        updateCurrentMode()
        let token = sessionID
        let completedPoint: String?
        if case let .pointDrag(id, _) = mode, !usedMultipleTouches {
            completedPoint = id
        } else {
            completedPoint = nil
        }
        trackedTouches.removeAll { tracked in touches.contains(where: { $0 === tracked }) }
        admittedTouches.removeAll { admitted in touches.contains(where: { $0 === admitted }) }

        if trackedTouches.isEmpty {
            mode = nil
            if let completedPoint, token == sessionID, configuration?.isEnabled == true {
                configuration?.onPointDragEnded(completedPoint)
            }
            if state == .began || state == .changed { state = .ended }
            else if state == .possible { state = .failed }
        } else if trackedTouches.count >= 2 {
            beginPinch()
        } else if usedMultipleTouches, let touch = trackedTouches.first,
                  let coordinateView, let latestViewport {
            // A finger left over from a pinch can only navigate. It can never
            // become a new point edit or commit the cancelled point preview.
            mode = latestViewport.isZoomed
                ? .pan(origin: touch.location(in: coordinateView), viewport: latestViewport)
                : .ignored
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        cancelSession()
    }

    override func reset() {
        let cancelledPoint = activePointID
        mode = nil
        trackedTouches.removeAll()
        admittedTouches.removeAll()
        latestViewport = nil
        usedMultipleTouches = false
        viewportGestureHasBegun = false
        sessionID = UUID()
        super.reset()
        if cancelledPoint != nil { configuration?.onPointDragCancelled() }
    }

    func cancelSession() {
        let cancelledPoint = activePointID
        let hadTouches = !trackedTouches.isEmpty || !admittedTouches.isEmpty
        mode = nil
        trackedTouches.removeAll()
        admittedTouches.removeAll()
        latestViewport = nil
        usedMultipleTouches = false
        viewportGestureHasBegun = false
        sessionID = UUID()
        if state == .began || state == .changed { state = .cancelled }
        else if state == .possible, hadTouches { state = .failed }
        if cancelledPoint != nil { configuration?.onPointDragCancelled() }
    }

    private var activePointID: String? {
        if case let .pointDrag(id, _) = mode { return id }
        return nil
    }

    private func validSession() -> Bool {
        guard configuration?.isEnabled == true, let coordinateView,
              coordinateView.window != nil, coordinateView.bounds == sessionBounds,
              sessionBounds.width > 0, sessionBounds.height > 0 else {
            cancelSession()
            return false
        }
        return !trackedTouches.isEmpty
    }

    private func cancelForUnadmittedActiveTouches(in event: UIEvent) -> Bool {
        let hasOutsideFinger = event.allTouches?.contains { touch in
            let isActive: Bool
            switch touch.phase {
            case .began, .moved, .stationary: isActive = true
            default: isActive = false
            }
            return isActive
                && !trackedTouches.contains(where: { $0 === touch })
                && !admittedTouches.contains(where: { $0 === touch })
        } ?? false
        guard hasOutsideFinger else { return false }
        cancelSession()
        return true
    }

    private func nearestPoint(to location: CGPoint,
                              in targets: [MeasurementPhotoPointTarget]) -> MeasurementPhotoPointTarget? {
        targets.compactMap { target -> (MeasurementPhotoPointTarget, CGFloat)? in
            let distance = hypot(target.center.x - location.x, target.center.y - location.y)
            guard distance.isFinite, distance <= pointHitRadius else { return nil }
            return (target, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    private func beginPinch() {
        guard trackedTouches.count >= 2, let coordinateView,
              let viewport = latestViewport ?? configuration?.viewport else { return }
        let first = trackedTouches[0]
        let second = trackedTouches[1]
        let geometry = pinchGeometry(first: first, second: second, in: coordinateView)
        let cancelledPoint = activePointID
        mode = .pinch(first: first, second: second, distance: max(geometry.distance, 1),
                      midpoint: geometry.midpoint, viewport: viewport)
        guard recognize() else { return }
        let token = sessionID
        if cancelledPoint != nil { configuration?.onPointDragCancelled() }
        guard token == sessionID else { return }
        beginViewportGestureIfNeeded()
    }

    private func updateCurrentMode() {
        guard let coordinateView, let touch = trackedTouches.first, let mode else { return }
        let location = touch.location(in: coordinateView)
        let token = sessionID
        switch mode {
        case let .pendingPoint(id, origin):
            guard !usedMultipleTouches, trackedTouches.count == 1,
                  distance(from: origin, to: location) >= dragThreshold else { return }
            self.mode = .pointDrag(id: id, origin: origin)
            guard recognize() else { return }
            configuration?.onPointDragBegan(id)
            guard token == sessionID else { return }
            configuration?.onPointDragChanged(id, translation(from: origin, to: location))
        case let .pointDrag(id, origin):
            guard !usedMultipleTouches, trackedTouches.count == 1 else { return }
            guard recognize() else { return }
            configuration?.onPointDragChanged(id, translation(from: origin, to: location))
        case let .pendingPan(origin, viewport):
            guard distance(from: origin, to: location) >= dragThreshold else { return }
            self.mode = .pan(origin: origin, viewport: viewport)
            guard recognize() else { return }
            beginViewportGestureIfNeeded()
            guard token == sessionID else { return }
            publish(viewport.applyingPan(translation(from: origin, to: location),
                                        in: sessionBounds.size))
        case let .pan(origin, viewport):
            guard recognize() else { return }
            publish(viewport.applyingPan(translation(from: origin, to: location),
                                        in: sessionBounds.size))
        case let .pinch(first, second, initialDistance, initialMidpoint, viewport):
            let geometry = pinchGeometry(first: first, second: second, in: coordinateView)
            guard recognize() else { return }
            publish(viewport.applyingPinch(magnification: geometry.distance / initialDistance,
                                          from: initialMidpoint, to: geometry.midpoint,
                                          in: sessionBounds.size))
        case .ignored:
            break
        }
    }

    private func beginViewportGestureIfNeeded() {
        guard !viewportGestureHasBegun else { return }
        viewportGestureHasBegun = true
        configuration?.onViewportGestureBegan()
    }

    private func publish(_ viewport: MeasurementPhotoViewport) {
        latestViewport = viewport
        configuration?.onViewportChange(viewport)
    }

    private func recognize() -> Bool {
        if state == .possible { state = .began }
        else if state == .began || state == .changed { state = .changed }
        return state == .began || state == .changed
    }

    private func pinchGeometry(first: UITouch, second: UITouch,
                               in view: UIView) -> (midpoint: CGPoint, distance: CGFloat) {
        let a = first.location(in: view)
        let b = second.location(in: view)
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), distance(from: a, to: b))
    }

    private func translation(from origin: CGPoint, to location: CGPoint) -> CGSize {
        CGSize(width: location.x - origin.x, height: location.y - origin.y)
    }

    private func distance(from origin: CGPoint, to location: CGPoint) -> CGFloat {
        hypot(location.x - origin.x, location.y - origin.y)
    }
}
