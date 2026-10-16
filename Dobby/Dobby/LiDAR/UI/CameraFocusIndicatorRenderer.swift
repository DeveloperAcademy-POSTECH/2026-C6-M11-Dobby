import UIKit

/// A noninteractive marker for an accepted focus request, not a claim of focus convergence.
@MainActor
final class CameraFocusIndicatorRenderer {
    private weak var container: UIView?
    private let shape = CAShapeLayer()
    private let accessibilityMarker = UIView()
    private var activeID: UUID?
    private var dismissedID: UUID?
    private var expiry: DispatchWorkItem?

    init(containerView: UIView) {
        container = containerView
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = UIColor.systemYellow.cgColor
        shape.lineWidth = 1.5
        shape.isHidden = true
        containerView.layer.addSublayer(shape)
        accessibilityMarker.isUserInteractionEnabled = false
        accessibilityMarker.isAccessibilityElement = true
        accessibilityMarker.accessibilityLabel = "초점 조절 위치"
        accessibilityMarker.accessibilityIdentifier = "cameraFocusIndicator"
        accessibilityMarker.isHidden = true
        containerView.addSubview(accessibilityMarker)
    }

    func update(point: CGPoint, requestID: UUID, reduceMotion: Bool) {
        guard requestID != dismissedID, let container,
              point.x.isFinite, point.y.isFinite, container.bounds.contains(point) else { return }
        let isNew = activeID != requestID
        if isNew {
            expiry?.cancel()
            activeID = requestID
            let work = DispatchWorkItem { [weak self] in
                guard self?.activeID == requestID else { return }
                self?.clear()
            }
            expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = UIBezierPath(roundedRect: CGRect(x: point.x - 32, y: point.y - 32,
                                                     width: 64, height: 64), cornerRadius: 3).cgPath
        shape.isHidden = false
        accessibilityMarker.frame = CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64)
        accessibilityMarker.isHidden = false
        CATransaction.commit()
        if reduceMotion { shape.removeAllAnimations() }
        else if isNew {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35; fade.toValue = 1; fade.duration = 0.15
            shape.add(fade, forKey: "focusFeedback")
        }
    }

    func clear() {
        expiry?.cancel(); expiry = nil
        dismissedID = activeID ?? dismissedID
        activeID = nil
        shape.removeAllAnimations()
        shape.isHidden = true
        accessibilityMarker.isHidden = true
    }

    func tearDown() {
        clear()
        shape.removeFromSuperlayer()
        accessibilityMarker.removeFromSuperview()
    }
}
