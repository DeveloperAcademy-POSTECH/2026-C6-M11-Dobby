import CoreGraphics
import MetalKit
import SwiftUI
import UIKit

/// Drive the GPU's photograph rectangle through the same SwiftUI interpolation
/// as the central focus/outline surface instead of jumping to the final ratio.
struct MultiCameraPreviewViewport: View, Animatable {
    let frames: MultiCameraFrameStore
    var photoRect: CGRect
    let orientation: ImageOrientation
    let zoom: CameraZoom
    let isActive: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(photoRect.minX, photoRect.minY), .init(photoRect.width, photoRect.height)) }
        set {
            photoRect = CGRect(x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second)
        }
    }

    var body: some View {
        MultiCameraPreview(frames: frames, photoRect: photoRect, orientation: orientation,
                           zoom: zoom, isActive: isActive)
            .transaction { $0.animation = nil }
    }
}

/// One GPU surface presents both synchronized cameras. The clear photograph's
/// field of view remains the coordinate system used by focus and measurement.
struct MultiCameraPreview: UIViewRepresentable {
    let frames: MultiCameraFrameStore
    let photoRect: CGRect
    let orientation: ImageOrientation
    let zoom: CameraZoom
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.delegate = context.coordinator
        context.coordinator.configure(device: view.device)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(frames: frames, photoRect: photoRect,
            orientation: orientation, zoom: zoom, isActive: isActive)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private var frames: MultiCameraFrameStore?
        private var photoRect = CGRect.zero
        private var orientation = ImageOrientation.right
        private var zoom = CameraZoom.standard
        private var isActive = false
        private var compositor: MultiCameraPreviewCompositor?

        func configure(device: (any MTLDevice)?) {
            compositor = device.map { MultiCameraPreviewCompositor(device: $0) }
        }

        func update(frames: MultiCameraFrameStore, photoRect: CGRect,
                    orientation: ImageOrientation, zoom: CameraZoom, isActive: Bool) {
            if self.frames !== frames || self.photoRect != photoRect
                || self.orientation != orientation || self.zoom != zoom || self.isActive != isActive {
                compositor?.invalidate()
            }
            self.frames = frames
            self.photoRect = photoRect
            self.orientation = orientation
            self.zoom = zoom
            self.isActive = isActive
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            compositor?.invalidate()
        }

        func draw(in view: MTKView) {
            // Pausing never substitutes a newer live frame. Once capture pins
            // its winning RGB/depth pair, render that exact pair once instead.
            guard let frame = isActive ? frames?.latest() : frames?.pinned(),
                  let geometry = MultiCameraPreviewGeometry.make(
                    imageSize: .init(width: CVPixelBufferGetWidth(frame.wideImage),
                                     height: CVPixelBufferGetHeight(frame.wideImage)),
                    photoRect: photoRect, orientation: orientation, zoom: zoom),
                  let compositor,
                  compositor.needsFrame(sessionID: frame.sessionID, timestamp: frame.timestamp,
                    canvasSize: view.bounds.size),
                  let drawable = view.currentDrawable else { return }
            compositor.render(frame: frame, geometry: geometry, canvasSize: view.bounds.size,
                              drawable: drawable)
        }

        func tearDown() {
            compositor?.invalidate()
            compositor = nil
            frames = nil
        }
    }
}

/// The central photo is aspect-filled from the complete rectified wide sensor.
/// Zoom is applied once here; captures separately crop their registered pair.
nonisolated enum MultiCameraPreviewGeometry {
    struct Mapping: Sendable, Equatable {
        let imageSize: PixelSize
        let photoRect: CGRect
        let sensorToCanvas: CGAffineTransform
        let canvasToSensor: CGAffineTransform
        /// Normalized raw sensor → normalized coordinates INSIDE photoRect.
        let photoTransform: CameraAffineTransform

        func sensorPoint(at canvasPoint: CGPoint) -> ImagePoint? {
            guard photoRect.contains(canvasPoint) else { return nil }
            let result = canvasPoint.applying(canvasToSensor)
            return Self.validPoint(result)
        }

        func rawWideCovers(_ canvasPoint: CGPoint) -> Bool {
            Self.validPoint(canvasPoint.applying(canvasToSensor)) != nil
        }

        private static func validPoint(_ point: CGPoint) -> ImagePoint? {
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
            return .init(x: point.x == 1 ? 1.0.nextDown : Double(point.x),
                         y: point.y == 1 ? 1.0.nextDown : Double(point.y))
        }
    }

    static func make(imageSize: PixelSize, photoRect: CGRect,
                     orientation: ImageOrientation, zoom: CameraZoom) -> Mapping? {
        guard imageSize.isValid,
              [photoRect.minX, photoRect.minY, photoRect.width, photoRect.height].allSatisfy(\.isFinite),
              photoRect.width > 0, photoRect.height > 0 else { return nil }
        let quarterTurn = orientation == .right || orientation == .left
        let orientedWidth = CGFloat(quarterTurn ? imageSize.height : imageSize.width)
        let orientedHeight = CGFloat(quarterTurn ? imageSize.width : imageSize.height)
        let zoomFactor: CGFloat = zoom == .double ? 2 : 1
        let scale = max(photoRect.width / orientedWidth, photoRect.height / orientedHeight) * zoomFactor
        let displayedWidth = orientedWidth * scale, displayedHeight = orientedHeight * scale
        let rotation: CGAffineTransform
        switch orientation {
        case .up: rotation = .identity
        case .right: rotation = .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        case .down: rotation = .init(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .left: rotation = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        }
        let transform = rotation
            .concatenating(.init(scaleX: displayedWidth, y: displayedHeight))
            .concatenating(.init(translationX: photoRect.midX - displayedWidth / 2,
                                 y: photoRect.midY - displayedHeight / 2))
        let normalized = transform
            .concatenating(.init(translationX: -photoRect.minX, y: -photoRect.minY))
            .concatenating(.init(scaleX: 1 / photoRect.width, y: 1 / photoRect.height))
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite), abs(transform.a * transform.d - transform.b * transform.c) > 1e-12 else { return nil }
        return .init(imageSize: imageSize, photoRect: photoRect,
            sensorToCanvas: transform, canvasToSensor: transform.inverted(),
            photoTransform: .init(a: normalized.a, b: normalized.b, c: normalized.c, d: normalized.d,
                                  tx: normalized.tx, ty: normalized.ty))
    }
}
