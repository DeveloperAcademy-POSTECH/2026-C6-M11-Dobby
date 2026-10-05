import QuartzCore
import UIKit

/// An identity barrier is independent of the pixels used to draw the outline.
/// The owner validates recognition/depth/freshness and calls clear immediately
/// when those facts are invalid. Orientation is a barrier, not a second rotation.
nonisolated struct GarmentSilhouetteRenderIdentity: Equatable, Sendable {
    var epoch: UUID
    var timestamp: TimeInterval
    var orientation: ImageOrientation
}

/// Display-only outline smoothing. The binary depth mask is never changed.
/// Geometry runs in one worker with one replaceable pending update; Core
/// Animation interpolates compatible paths between camera analysis results.
@MainActor
final class GarmentSilhouetteLayerRenderer {
    private weak var containerLayer: CALayer?
    private let layers = [CAShapeLayer(), CAShapeLayer()]
    private let gradientLayers = [GradientLayers(), GradientLayers()]
    private var activeLayerIndex = 0
    private var latest: Update?
    private var cachedIdentity: GarmentSilhouetteRenderIdentity?
    private var cachedContours: [[ImagePoint]] = []
    private var cachedMapping: Mapping?
    private var workerTask: Task<Void, Never>?
    private var activeJobID: UUID?
    private var pending: Update?
    private var revision: UInt64 = 0
    private var transitionID = UUID()
    private var isTornDown = false
    private(set) var hasVisibleSilhouette = false

    private struct Mapping: Equatable {
        var transform: CGAffineTransform
        var viewport: CGRect
    }

    private struct Update {
        var mask: GarmentMask
        var identity: GarmentSilhouetteRenderIdentity
        var mapping: Mapping
        var fillColor: CGColor?
        var strokeColor: CGColor?
        var reduceMotion: Bool
        var gradientEndColor: CGColor?
    }

    /// The parent owns visibility/crossfades; these masks share its exact path.
    /// Keeping them synchronized while hidden also permits a style-only update.
    private struct GradientLayers {
        let fill = CAGradientLayer()
        let stroke = CAGradientLayer()
        let fillMask = CAShapeLayer()
        let strokeMask = CAShapeLayer()

        var gradients: [CAGradientLayer] { [fill, stroke] }
        var masks: [CAShapeLayer] { [fillMask, strokeMask] }

        init() {
            fillMask.fillRule = .evenOdd
            fillMask.fillColor = UIColor.white.cgColor
            strokeMask.fillRule = .evenOdd
            strokeMask.fillColor = nil
            strokeMask.strokeColor = UIColor.white.cgColor
            strokeMask.lineWidth = 2
            strokeMask.lineJoin = .round
            strokeMask.lineCap = .round
            fill.mask = fillMask
            stroke.mask = strokeMask
            for gradient in gradients { gradient.isHidden = true }
            for mask in masks { mask.allowsEdgeAntialiasing = true }
        }
    }

    private nonisolated struct PreparedGeometry: Sendable {
        var contours: [[ImagePoint]]
        var canMorph: Bool
    }

    init(containerLayer: CALayer) {
        self.containerLayer = containerLayer
        for (index, layer) in layers.enumerated() {
            layer.fillRule = .evenOdd
            layer.lineWidth = 2
            layer.lineJoin = .round
            layer.lineCap = .round
            layer.opacity = 0
            layer.contentsScale = containerLayer.contentsScale
            layer.allowsEdgeAntialiasing = true
            layer.addSublayer(gradientLayers[index].fill)
            layer.addSublayer(gradientLayers[index].stroke)
            containerLayer.addSublayer(layer)
        }
    }

    deinit { workerTask?.cancel() }

    /// transform maps raw normalized image coordinates into container points.
    /// ARKit callers pass displayTransform followed by the viewport scale.
    /// An optional endpoint enables a native transparent gradient. Fill and
    /// stroke keep their respective input alpha; no private blend filter is used.
    func update(mask: GarmentMask, identity: GarmentSilhouetteRenderIdentity,
                transform: CGAffineTransform, viewport: CGRect? = nil,
                fillColor: CGColor?, strokeColor: CGColor?, reduceMotion: Bool,
                gradientEndColor: CGColor? = nil) {
        guard !isTornDown, let containerLayer else { return }
        let viewport = viewport ?? containerLayer.bounds
        guard identity.timestamp.isFinite, identity.timestamp >= 0,
              [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
              viewport.origin.x.isFinite, viewport.origin.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { clear(); return }

        if let previous = latest?.identity {
            if previous.epoch != identity.epoch || previous.orientation != identity.orientation {
                clear()
            } else if identity.timestamp < previous.timestamp {
                return
            }
        }
        let update = Update(mask: mask, identity: identity,
                            mapping: .init(transform: transform, viewport: viewport),
                            fillColor: fillColor, strokeColor: strokeColor, reduceMotion: reduceMotion,
                            gradientEndColor: gradientEndColor)
        latest = update
        configureLayers(update)

        if hasVisibleSilhouette, cachedMapping != update.mapping || reduceMotion {
            // Accessibility changes cancel an active morph even when a newer
            // mask is still being prepared. Keep the accepted geometry until
            // that worker publishes its result.
            presentImmediately(cachedContours, update: update)
        }

        if cachedIdentity == identity {
            if cachedMapping != update.mapping || reduceMotion {
                // Layout/rotation mapping changes must follow the current view
                // immediately, rather than tweening from obsolete screen pixels.
                presentImmediately(cachedContours, update: update)
            }
            return
        }

        if workerTask != nil {
            // Never grow a backlog of masks; only the most recent update waits.
            pending = update
        } else {
            beginGeometry(update)
        }
    }

    /// Invalidations clear model and presentation paths synchronously. Cancelled
    /// geometry cannot republish an outline after loss of recognition or rotation.
    func clear() {
        revision &+= 1
        transitionID = UUID()
        latest = nil
        pending = nil
        cachedIdentity = nil
        cachedContours = []
        cachedMapping = nil
        workerTask?.cancel()
        hideLayers()
    }

    func tearDown() {
        guard !isTornDown else { return }
        clear()
        isTornDown = true
        for layer in layers { layer.removeFromSuperlayer() }
        containerLayer = nil
    }

    private func beginGeometry(_ update: Update) {
        let jobID = UUID()
        let jobRevision = revision
        let previous = cachedContours
        let identity = update.identity
        let mask = update.mask
        activeJobID = jobID
        workerTask = Task.detached(priority: .userInitiated) { [weak self] in
            let geometry: PreparedGeometry?
            if Task.isCancelled {
                geometry = nil
            } else if let contours = GarmentSilhouettePresentationGeometry.contours(from: mask), !Task.isCancelled {
                if let aligned = GarmentSilhouettePresentationGeometry.aligned(contours, to: previous) {
                    geometry = .init(contours: aligned, canMorph: true)
                } else {
                    geometry = .init(contours: contours, canMorph: false)
                }
            } else if !Task.isCancelled, let exact = GarmentSilhouetteGeometry.contours(from: mask),
                      exact.reduce(0, { $0 + $1.count }) <= 4_096 {
                // Keep every component/hole if smooth presentation is too
                // complex. Exact geometry is displayed without path morphing.
                geometry = .init(contours: exact, canMorph: false)
            } else {
                geometry = nil
            }
            let wasCancelled = Task.isCancelled
            await self?.finishGeometry(geometry, jobID: jobID, identity: identity,
                                       jobRevision: jobRevision, wasCancelled: wasCancelled)
        }
    }

    private func finishGeometry(_ geometry: PreparedGeometry?, jobID: UUID,
                                identity: GarmentSilhouetteRenderIdentity,
                                jobRevision: UInt64, wasCancelled: Bool) {
        guard activeJobID == jobID else { return }
        activeJobID = nil
        workerTask = nil
        if !isTornDown, !wasCancelled, jobRevision == revision,
           let update = latest, update.identity == identity {
            if let geometry, !geometry.contours.isEmpty {
                present(geometry, update: update)
            } else {
                hideLayers()
                cachedContours = []
                cachedIdentity = identity
                cachedMapping = update.mapping
            }
        }
        if !isTornDown, let pending {
            self.pending = nil
            if cachedIdentity != pending.identity { beginGeometry(pending) }
        }
    }

    private func configureLayers(_ update: Update) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in layers.enumerated() {
            layer.frame = update.mapping.viewport
            layer.contentsScale = containerLayer?.contentsScale ?? layer.contentsScale
            layer.fillColor = update.gradientEndColor == nil ? update.fillColor : nil
            layer.strokeColor = update.gradientEndColor == nil ? update.strokeColor : nil
            let gradient = gradientLayers[index]
            for child in gradient.gradients {
                child.frame = layer.bounds
                child.contentsScale = layer.contentsScale
            }
            for mask in gradient.masks {
                mask.frame = layer.bounds
                mask.contentsScale = layer.contentsScale
            }
            configureGradient(gradient.fill, startColor: update.fillColor, endColor: update.gradientEndColor)
            configureGradient(gradient.stroke, startColor: update.strokeColor, endColor: update.gradientEndColor)
            positionGradients(gradient, path: layer.path, bounds: layer.bounds)
        }
        CATransaction.commit()
    }

    private func configureGradient(_ gradient: CAGradientLayer, startColor: CGColor?, endColor: CGColor?) {
        guard let startColor, let endColor = endColor?.copy(alpha: startColor.alpha) else {
            gradient.isHidden = true
            gradient.colors = nil
            return
        }
        gradient.colors = [startColor, endColor]
        gradient.locations = [0, 1]
        gradient.isHidden = false
    }

    private func positionGradients(_ gradient: GradientLayers, path: CGPath?, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let box = path?.boundingBoxOfPath ?? bounds
        guard !box.isEmpty, !box.isInfinite, !box.isNull else { return }
        let start = CGPoint(x: (box.minX + box.width * 0.30 - bounds.minX) / bounds.width,
            y: (box.minY + box.height * 0.13 - bounds.minY) / bounds.height)
        let end = CGPoint(x: (box.minX + box.width * 0.75 - bounds.minX) / bounds.width,
            y: (box.minY + box.height * 0.92 - bounds.minY) / bounds.height)
        for child in gradient.gradients {
            child.startPoint = start
            child.endPoint = end
        }
    }

    /// All callers set paths with implicit actions disabled, just as for the
    /// original parent shape. Explicit path morphs are installed on all three.
    private func setPath(_ path: CGPath?, on layer: CAShapeLayer) {
        layer.path = path
        guard let index = layers.firstIndex(where: { $0 === layer }) else { return }
        let gradient = gradientLayers[index]
        for mask in gradient.masks { mask.path = path }
        positionGradients(gradient, path: path, bounds: layer.bounds)
    }

    private func removeAnimations(from layer: CAShapeLayer) {
        layer.removeAllAnimations()
        guard let index = layers.firstIndex(where: { $0 === layer }) else { return }
        for mask in gradientLayers[index].masks { mask.removeAllAnimations() }
        for child in gradientLayers[index].gradients { child.removeAllAnimations() }
    }

    private func path(for contours: [[ImagePoint]], mapping: Mapping) -> CGPath {
        let path = CGMutablePath()
        for contour in contours {
            for (index, point) in contour.enumerated() {
                let containerPoint = CGPoint(x: point.x, y: point.y).applying(mapping.transform)
                let localPoint = CGPoint(x: containerPoint.x - mapping.viewport.minX,
                                         y: containerPoint.y - mapping.viewport.minY)
                if index == 0 { path.move(to: localPoint) }
                else { path.addLine(to: localPoint) }
            }
            path.closeSubpath()
        }
        return path
    }

    private func presentImmediately(_ contours: [[ImagePoint]], update: Update) {
        transitionID = UUID()
        hideLayers()
        guard !contours.isEmpty else { return }
        let layer = layers[activeLayerIndex]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setPath(path(for: contours, mapping: update.mapping), on: layer)
        layer.opacity = 1
        CATransaction.commit()
        cachedMapping = update.mapping
        hasVisibleSilhouette = true
    }

    private func present(_ geometry: PreparedGeometry, update: Update) {
        let target = path(for: geometry.contours, mapping: update.mapping)
        let active = layers[activeLayerIndex]
        let sameMapping = cachedMapping == update.mapping
        let canMorph = geometry.canMorph && hasVisibleSilhouette && sameMapping && !update.reduceMotion
            && layers[1 - activeLayerIndex].path == nil
            && active.animation(forKey: "silhouette.path") == nil
        if canMorph {
            // Interruption uses the crossfade branch below. A path already
            // between targets has not been certified against this new contour.
            let displayed = active.presentation()?.path ?? active.path
            active.removeAnimation(forKey: "silhouette.path")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setPath(target, on: active)
            active.opacity = 1
            CATransaction.commit()
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = displayed
            animation.toValue = target
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            active.add(animation, forKey: "silhouette.path")
            for mask in gradientLayers[activeLayerIndex].masks {
                mask.add(animation, forKey: "silhouette.path")
            }
        } else if hasVisibleSilhouette, !sameMapping {
            // A bounds change remaps current geometry without an artificial pan.
            presentImmediately(geometry.contours, update: update)
        } else {
            crossfade(to: target, update: update)
        }
        cachedContours = geometry.contours
        cachedIdentity = update.identity
        cachedMapping = update.mapping
        hasVisibleSilhouette = true
    }

    private func crossfade(to path: CGPath, update: Update) {
        let outgoing = layers[activeLayerIndex]
        let incomingIndex = 1 - activeLayerIndex
        let incoming = layers[incomingIndex]
        let displayedPath = outgoing.presentation()?.path ?? outgoing.path
        let displayedOpacity = outgoing.presentation()?.opacity ?? outgoing.opacity
        // A rapid third shape can interrupt a two-layer fade. Reuse the fading
        // layer's current alpha when replacing its path, rather than dropping
        // that contribution and flashing the whole overlay dimmer.
        let incomingDisplayedPath = incoming.presentation()?.path ?? incoming.path
        let incomingOpacity = incomingDisplayedPath == nil ? 0 : (incoming.presentation()?.opacity ?? incoming.opacity)
        let token = UUID()
        let jobRevision = revision
        transitionID = token

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimations(from: outgoing)
        removeAnimations(from: incoming)
        setPath(displayedPath, on: outgoing)
        outgoing.opacity = 0
        setPath(path, on: incoming)
        incoming.opacity = 1
        CATransaction.setCompletionBlock { [weak self, weak outgoing] in
            Task { @MainActor [weak self, weak outgoing] in
                guard let self, transitionID == token, revision == jobRevision,
                      layers[activeLayerIndex] !== outgoing else { return }
                if let outgoing {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    removeAnimations(from: outgoing)
                    setPath(nil, on: outgoing)
                    CATransaction.commit()
                }
            }
        }

        let duration = update.reduceMotion ? 0.10 : 0.16
        if displayedPath != nil, displayedOpacity > 0 {
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = displayedOpacity
            fadeOut.toValue = 0
            fadeOut.duration = duration
            fadeOut.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing.add(fadeOut, forKey: "silhouette.opacity")
        }
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = incomingOpacity
        fadeIn.toValue = 1
        fadeIn.duration = duration
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        incoming.add(fadeIn, forKey: "silhouette.opacity")
        CATransaction.commit()
        activeLayerIndex = incomingIndex
    }

    private func hideLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            removeAnimations(from: layer)
            setPath(nil, on: layer)
            layer.opacity = 0
        }
        CATransaction.commit()
        hasVisibleSilhouette = false
    }
}
