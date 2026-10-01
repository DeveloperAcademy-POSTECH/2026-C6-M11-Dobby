import SwiftUI
import UIKit

/// Explicit UI rehearsal. Never used as a fallback for a camera/model failure.
@MainActor
enum GarmentCapturePreview {
    static func measurement(partial: Bool = false, kind: AutomaticGarmentKind = .bottoms) -> AutomaticMeasurement {
        let size = PixelSize(width: 800, height: 1000)
        let maskSize = PixelSize(width: 400, height: 500)
        let bottomVertices = [ImagePoint(x: 0.27, y: 0.15), .init(x: 0.73, y: 0.15),
            .init(x: 0.78, y: 0.87), .init(x: 0.57, y: 0.87), .init(x: 0.50, y: 0.46),
            .init(x: 0.43, y: 0.87), .init(x: 0.22, y: 0.87)]
        let topVertices = [ImagePoint(x: 0.41, y: 0.16), .init(x: 0.30, y: 0.23),
            .init(x: 0.075, y: 0.42), .init(x: 0.13, y: 0.52), .init(x: 0.32, y: 0.43),
            .init(x: 0.32, y: 0.84), .init(x: 0.50, y: 0.86), .init(x: 0.68, y: 0.84),
            .init(x: 0.68, y: 0.43), .init(x: 0.87, y: 0.52), .init(x: 0.925, y: 0.42),
            .init(x: 0.70, y: 0.23), .init(x: 0.59, y: 0.16), .init(x: 0.50, y: 0.21)]
        let vertices = kind == .top ? topVertices : bottomVertices
        let shape = UIBezierPath()
        for (index, p) in vertices.enumerated() {
            let point = CGPoint(x: p.x * Double(size.width), y: p.y * Double(size.height))
            if index == 0 { shape.move(to: point) } else { shape.addLine(to: point) }
        }
        shape.close()
        var pixels = [UInt8](repeating: 0, count: maskSize.width * maskSize.height)
        for y in 0..<maskSize.height {
            for x in 0..<maskSize.width {
                let p = CGPoint(x: (Double(x) + 0.5) * Double(size.width) / Double(maskSize.width),
                                y: (Double(y) + 0.5) * Double(size.height) / Double(maskSize.height))
                pixels[y * maskSize.width + x] = shape.contains(p) ? 1 : 0
            }
        }
        let mask = GarmentMask(size: maskSize, values: pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { renderer in
            UIColor(red: 0.46, green: 0.45, blue: 0.42, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            UIColor(red: 0.16, green: 0.23, blue: 0.31, alpha: 1).setFill()
            shape.fill()
            UIColor.white.withAlphaComponent(0.2).setStroke()
            shape.lineWidth = 3
            shape.stroke()
            if kind == .bottoms {
                let waistband = UIBezierPath()
                waistband.move(to: CGPoint(x: 218, y: 174))
                waistband.addLine(to: CGPoint(x: 582, y: 174))
                waistband.lineWidth = 2
                waistband.stroke()
                let seam = UIBezierPath()
                seam.move(to: CGPoint(x: 400, y: 174))
                seam.addLine(to: CGPoint(x: 400, y: 425))
                seam.lineWidth = 2
                seam.stroke()
            }
        }
        let sessionID = UUID(), frameID = UUID()
        let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 850, fy: 850, cx: 400, cy: 500, referenceSize: size),
            depth: .init(size: maskSize, values: .init(repeating: 1, count: pixels.count),
                         confidence: .init(repeating: 2, count: pixels.count)), source: .synthetic, orientation: .up)
        let bottomIDs = ["waist_left", "waist_right", "hem_right_outer", "hem_right_inner", "crotch", "hem_left_inner", "hem_left_outer"]
        let topIDs = ["neck_left", "neck_right", "shoulder_left", "shoulder_right", "armpit_left", "armpit_right",
                      "sleeve_end_left", "sleeve_end_right", "hem_left", "hem_center", "hem_right"]
        let topPoints = [ImagePoint(x: 0.41, y: 0.16), .init(x: 0.59, y: 0.16),
            .init(x: 0.30, y: 0.23), .init(x: 0.70, y: 0.23), .init(x: 0.32, y: 0.43), .init(x: 0.68, y: 0.43),
            .init(x: 0.10, y: 0.47), .init(x: 0.90, y: 0.47), .init(x: 0.32, y: 0.84),
            .init(x: 0.50, y: 0.86), .init(x: 0.68, y: 0.84)]
        let ids = kind == .top ? topIDs : bottomIDs
        var points = zip(ids, kind == .top ? topPoints : bottomVertices)
            .map { GarmentLandmark(id: $0.0, point: $0.1, confidence: 1) }
        if kind == .top {
            points.append(.init(id: "neck_center", point: .init(x: 0.5, y: 0.16), confidence: 1,
                                derivedFrom: ["neck_left", "neck_right"]))
        } else {
            points.append(.init(id: "waist_center", point: .init(x: 0.5, y: 0.15), confidence: 1,
                                derivedFrom: ["waist_left", "waist_right"]))
        }
        if partial { points.removeAll { $0.id == (kind == .top ? "sleeve_end_right" : "hem_right_inner") } }
        let pairs: [(String, String, String)] = [
            ("waist_left", "waist_right", "허리 단면"), ("waist_center", "crotch", "밑위(직선)"),
            ("waist_left", "hem_left_outer", "왼쪽 총장(직선)"),
            ("hem_left_outer", "hem_left_inner", "왼쪽 밑단 단면"),
            ("crotch", "hem_left_inner", "왼쪽 인심(직선)"),
            ("waist_right", "hem_right_outer", "오른쪽 총장(직선)"),
            ("hem_right_outer", "hem_right_inner", "오른쪽 밑단 단면"),
            ("crotch", "hem_right_inner", "오른쪽 인심(직선)")]
        let bottomDefinitions = pairs.map {
            MeasurementDefinition(id: "bottom." + [$0.0, $0.1].sorted().joined(separator: "."),
                                  title: $0.2, landmarkIDs: [$0.0, $0.1])
        }
        let definitions = kind == .top ? TopLandmarkSchema.canonicalMeasurementDefinitions : bottomDefinitions
        let landmarks = GarmentLandmarkSet(sessionID: sessionID, frameID: frameID, origin: .synthetic,
            modelVersion: kind == .top ? "garment-ui-top-preview-v1" : "garment-ui-preview-v1", points: points, mask: mask)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        let output = AutomaticMeasurementOutput(runID: UUID(),
            snapshot: .init(frame: frame, imageJPEG: image.jpegData(compressionQuality: 0.95)!),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: nil, landmarksSeconds: nil, measurementSeconds: nil, totalSeconds: 0),
            startedAt: .now, finishedAt: .now)
        return AutomaticMeasurement(output: output,
            context: .init(category: kind.category, specimenName: "화면 미리보기", deviceModel: "Synthetic UI preview"))
    }
}

/// The rehearsal and the live camera use the same contour presentation renderer.
/// Its display geometry never replaces the archived binary measurement mask.
struct GarmentSilhouetteOverlay: UIViewRepresentable {
    let mask: GarmentMask
    var orientation: ImageOrientation = .up
    var sourceID: UUID? = nil
    var forceReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> GarmentSilhouettePresentationView {
        GarmentSilhouettePresentationView(frame: .zero)
    }

    func updateUIView(_ view: GarmentSilhouettePresentationView, context: Context) {
        view.update(mask: mask, orientation: orientation, sourceID: sourceID,
                    reduceMotion: reduceMotion || forceReduceMotion)
    }

    static func dismantleUIView(_ view: GarmentSilhouettePresentationView, coordinator: ()) {
        view.tearDown()
    }
}

final class GarmentSilhouettePresentationView: UIView {
    private lazy var renderer = GarmentSilhouetteLayerRenderer(containerLayer: layer)
    private var garmentMask: GarmentMask?
    private var identity = GarmentSilhouetteRenderIdentity(epoch: UUID(), timestamp: 0, orientation: .up)
    private var sourceID: UUID?
    private var reduceMotion = false
    private var isTornDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mask: GarmentMask, orientation: ImageOrientation, sourceID: UUID?, reduceMotion: Bool) {
        guard !isTornDown else { return }
        if identity.orientation != orientation || self.sourceID != sourceID {
            // Another camera/photo domain or rotation removes the old contour
            // immediately. Mask updates within that domain can morph smoothly.
            identity = .init(epoch: UUID(), timestamp: 0, orientation: orientation)
            self.sourceID = sourceID
            self.garmentMask = mask
        } else if self.garmentMask != mask {
            identity = .init(epoch: identity.epoch, timestamp: identity.timestamp + 1, orientation: orientation)
            self.garmentMask = mask
        }
        self.reduceMotion = reduceMotion
        render()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { renderer.clear() }
        else { render() }
    }

    func tearDown() {
        isTornDown = true
        renderer.tearDown()
    }

    private func render() {
        guard !isTornDown, window != nil, let mask = garmentMask, bounds.width > 0, bounds.height > 0 else { return }
        let color = UIColor(GarmentCaptureStyle.recognition).resolvedColor(with: traitCollection)
        renderer.update(mask: mask, identity: identity,
            transform: displayTransform, viewport: bounds,
            fillColor: color.withAlphaComponent(0.20).cgColor, strokeColor: color.cgColor,
            reduceMotion: reduceMotion)
    }

    private var displayTransform: CGAffineTransform {
        let rotation: CGAffineTransform
        switch identity.orientation {
        case .up: rotation = .identity
        case .right: rotation = .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        case .down: rotation = .init(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .left: rotation = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        }
        return rotation.concatenating(.init(scaleX: bounds.width, y: bounds.height))
            .concatenating(.init(translationX: bounds.minX, y: bounds.minY))
    }
}
