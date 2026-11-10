import SwiftUI
import UIKit

/// Receives already-rendered marker positions, never garment/source coordinates.
/// The window centre is expressed in the photo view's coordinate space, so a
/// toolbar, split-screen window, crop, or display zoom cannot change the rule.
nonisolated enum MeasurementMagnifierPlacement {
    /// Figma specifies the outer frame, including its inside-drawn border.
    /// Photo zoom and available space change placement, never this point size.
    static let size = CGSize(width: 85, height: 120)

    static func rect(photoSize: CGSize, point: CGPoint, windowCenter: CGPoint) -> CGRect {
        guard [photoSize.width, photoSize.height, point.x, point.y,
               windowCenter.x, windowCenter.y].allSatisfy(\.isFinite),
              photoSize.width > 0, photoSize.height > 0 else { return .zero }
        let width = size.width, height = size.height
        let insetX = min(20, max(0, photoSize.width - width) / 2)
        let insetY = min(20, max(0, photoSize.height - height) / 2)
        // Points exactly on an axis belong to its right/bottom half.
        let x = point.x < windowCenter.x ? max(0, photoSize.width - insetX - width) : insetX
        let y = point.y < windowCenter.y ? max(0, photoSize.height - insetY - height) : insetY
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Measure the handle itself after SwiftUI positions/transforms it. This also
/// works when the independent photo-zoom feature enlarges and pans the image.
nonisolated struct MeasurementPointScreenCentersKey: PreferenceKey {
    static var defaultValue: [String: CGPoint] { [:] }
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Use this view's own window rather than the first scene or the device screen:
/// the app can be in another window, landscape, or iPad multitasking.
struct MeasurementPhotoWindowCenterReader: UIViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> WindowCenterView {
        let view = WindowCenterView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: WindowCenterView, context: Context) {
        view.onChange = onChange
        view.publishAfterLayout()
    }

    static func dismantleUIView(_ view: WindowCenterView, coordinator: ()) {
        view.onChange = nil
    }

    final class WindowCenterView: UIView {
        var onChange: ((CGPoint?) -> Void)?
        private var publicationPending = false
        private var lastCenter: CGPoint?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishAfterLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishAfterLayout()
        }

        func publishAfterLayout() {
            guard !publicationPending else { return }
            publicationPending = true
            // UIKit may request layout during a SwiftUI update. Defer the state
            // publication and coalesce it; do not publish from updateUIView.
            Task { @MainActor [weak self] in
                guard let self else { return }
                publicationPending = false
                let center = window.map { window in
                    self.convert(CGPoint(x: window.bounds.midX, y: window.bounds.midY), from: window)
                }
                guard center != lastCenter else { return }
                lastCenter = center
                onChange?(center)
            }
        }
    }
}
