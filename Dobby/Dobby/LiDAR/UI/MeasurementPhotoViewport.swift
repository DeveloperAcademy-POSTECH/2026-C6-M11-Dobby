import CoreGraphics
import Foundation

/// Display-only transform shared by the photo and its measurement overlays.
/// Photo coordinates remain unchanged: screen = photo * scale + offset.
nonisolated struct MeasurementPhotoViewport: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let maximumScale: CGFloat = 4

    var isZoomed: Bool { finiteState.scale > 1 }

    func screenPoint(for photoPoint: CGPoint) -> CGPoint {
        guard Self.isFinite(photoPoint) else { return .zero }
        let state = finiteState
        let point = CGPoint(x: photoPoint.x * state.scale + state.offset.width,
                            y: photoPoint.y * state.scale + state.offset.height)
        return Self.isFinite(point) ? point : photoPoint
    }

    /// Convert a touch back to photo coordinates exactly once before editing.
    func photoPoint(for screenPoint: CGPoint) -> CGPoint {
        guard Self.isFinite(screenPoint) else { return .zero }
        let state = finiteState
        let point = CGPoint(x: (screenPoint.x - state.offset.width) / state.scale,
                            y: (screenPoint.y - state.offset.height) / state.scale)
        return Self.isFinite(point) ? point : screenPoint
    }

    func screenRect(for photoRect: CGRect) -> CGRect {
        guard Self.isFinite(photoRect) else { return .zero }
        let rect = photoRect.applying(transform)
        return Self.isFinite(rect) ? rect : photoRect
    }

    func photoRect(for screenRect: CGRect) -> CGRect {
        guard Self.isFinite(screenRect) else { return .zero }
        let rect = screenRect.applying(transform.inverted())
        return Self.isFinite(rect) ? rect : screenRect
    }

    func clamped(to size: CGSize) -> Self {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .init() }
        var state = finiteState
        // Keep every edge covered, including when a layout change shrinks the viewport.
        state.offset.width = min(0, max(size.width * (1 - state.scale), state.offset.width))
        state.offset.height = min(0, max(size.height * (1 - state.scale), state.offset.height))
        return state
    }

    func applyingPan(_ translation: CGSize, in size: CGSize) -> Self {
        let state = clamped(to: size)
        guard translation.width.isFinite, translation.height.isFinite else { return state }
        let offset = CGSize(width: state.offset.width + translation.width,
                            height: state.offset.height + translation.height)
        guard offset.width.isFinite, offset.height.isFinite else { return state }
        return Self(scale: state.scale, offset: offset).clamped(to: size)
    }

    func applyingPinch(magnification: CGFloat, from start: CGPoint,
                       to current: CGPoint, in size: CGSize) -> Self {
        let state = clamped(to: size)
        guard magnification.isFinite, magnification > 0,
              Self.isFinite(start), Self.isFinite(current) else { return state }
        let scale = min(Self.maximumScale, max(1, state.scale * magnification))
        // Preserve the photo point beneath the starting centroid while both fingers move.
        // Clamping may move that anchor only when a photo edge reaches the viewport.
        let anchor = state.photoPoint(for: start)
        let offset = CGSize(width: current.x - anchor.x * scale,
                            height: current.y - anchor.y * scale)
        guard offset.width.isFinite, offset.height.isFinite else { return state }
        return Self(scale: scale, offset: offset).clamped(to: size)
    }

    private var finiteState: Self {
        guard scale.isFinite, offset.width.isFinite, offset.height.isFinite else { return .init() }
        return Self(scale: min(Self.maximumScale, max(1, scale)), offset: offset)
    }

    private var transform: CGAffineTransform {
        let state = finiteState
        return CGAffineTransform(a: state.scale, b: 0, c: 0, d: state.scale,
                                 tx: state.offset.width, ty: state.offset.height)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
    }
}
