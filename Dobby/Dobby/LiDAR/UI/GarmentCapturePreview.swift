import SwiftUI
import UIKit

/// Explicit UI rehearsal. Never used as a fallback for a camera/model failure.
@MainActor
enum GarmentCapturePreview {
    static func measurement(partial: Bool = false, bothSidesPartial: Bool = false, missingTopLength: Bool = false,
                            kind: AutomaticGarmentKind = .bottoms) -> AutomaticMeasurement {
        // The photographed garment is an opt-in design fixture, not model or
        // sensor evidence. Its points, mask, calibration and 1 m depth are synthetic.
        let referenceImage = kind == .top && ProcessInfo.processInfo.arguments.contains("--garment-preview-design-reference")
            ? designReferenceImage() : nil
        let isDesignReference = referenceImage != nil
        let size = isDesignReference ? PixelSize(width: 804, height: 1120) : PixelSize(width: 800, height: 1000)
        // The display contour extractor accepts at most 512 pixels per axis.
        // Keep the reference mask bounded without changing its synthetic depth.
        let maskSize = isDesignReference ? PixelSize(width: 201, height: 280) : PixelSize(width: 400, height: 500)
        let depthSize = isDesignReference ? PixelSize(width: 402, height: 560) : maskSize
        let bottomVertices = [ImagePoint(x: 0.27, y: 0.15), .init(x: 0.73, y: 0.15),
            .init(x: 0.78, y: 0.87), .init(x: 0.57, y: 0.87), .init(x: 0.50, y: 0.46),
            .init(x: 0.43, y: 0.87), .init(x: 0.22, y: 0.87)]
        let topVertices = isDesignReference
            ? [ImagePoint(x: 0.448, y: 0.205), .init(x: 0.418, y: 0.246), .init(x: 0.132, y: 0.296),
               .init(x: 0, y: 0.44), .init(x: 0.06, y: 0.56), .init(x: 0.182, y: 0.652),
               .init(x: 0.24, y: 0.64), .init(x: 0.30, y: 0.75), .init(x: 0.50, y: 0.76),
               .init(x: 0.719, y: 0.757),
               .init(x: 0.78, y: 0.64), .init(x: 0.84, y: 0.64), .init(x: 0.95, y: 0.55),
               .init(x: 1, y: 0.45), .init(x: 0.876, y: 0.288), .init(x: 0.590, y: 0.248),
               .init(x: 0.537, y: 0.205)]
            : [ImagePoint(x: 0.41, y: 0.16), .init(x: 0.30, y: 0.23),
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
        let image = referenceImage ?? UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { renderer in
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
            imageSize: size, intrinsics: .init(fx: 850, fy: 850,
                cx: Double(size.width) / 2, cy: Double(size.height) / 2, referenceSize: size),
            depth: .init(size: depthSize, values: .init(repeating: 1, count: depthSize.width * depthSize.height),
                         confidence: .init(repeating: 2, count: depthSize.width * depthSize.height)),
            source: .synthetic, orientation: .up)
        let bottomIDs = ["waist_left", "waist_right", "hem_right_outer", "hem_right_inner", "crotch", "hem_left_inner", "hem_left_outer"]
        let topIDs = ["neck_left", "neck_right", "shoulder_left", "shoulder_right", "armpit_left", "armpit_right",
                      "sleeve_end_left", "sleeve_end_right", "hem_left", "hem_center", "hem_right"]
        let topPoints = isDesignReference
            ? [ImagePoint(x: 0.453, y: 0.213), .init(x: 0.537, y: 0.213),
               .init(x: 0.142, y: 0.302), .init(x: 0.856, y: 0.302),
               .init(x: 0.229, y: 0.434), .init(x: 0.789, y: 0.434),
               .init(x: 0.182, y: 0.652), .init(x: 0.84, y: 0.64),
               .init(x: 0.30, y: 0.75), .init(x: 0.50, y: 0.76), .init(x: 0.719, y: 0.757)]
            : [ImagePoint(x: 0.41, y: 0.16), .init(x: 0.59, y: 0.16),
            .init(x: 0.30, y: 0.23), .init(x: 0.70, y: 0.23), .init(x: 0.32, y: 0.43), .init(x: 0.68, y: 0.43),
            .init(x: 0.10, y: 0.47), .init(x: 0.90, y: 0.47), .init(x: 0.32, y: 0.84),
            .init(x: 0.50, y: 0.86), .init(x: 0.68, y: 0.84)]
        let ids = kind == .top ? topIDs : bottomIDs
        var points = zip(ids, kind == .top ? topPoints : bottomVertices)
            .map { GarmentLandmark(id: $0.0, point: $0.1, confidence: 1) }
        if kind == .top {
            points.append(.init(id: "neck_center",
                                point: .init(x: (topPoints[0].x + topPoints[1].x) / 2,
                                             y: (topPoints[0].y + topPoints[1].y) / 2), confidence: 1,
                                derivedFrom: ["neck_left", "neck_right"]))
        } else {
            points.append(.init(id: "waist_center", point: .init(x: 0.5, y: 0.15), confidence: 1,
                                derivedFrom: ["waist_left", "waist_right"]))
        }
        if partial { points.removeAll { $0.id == (kind == .top ? "sleeve_end_right" : "hem_right_inner") } }
        if missingTopLength && kind == .top {
            // Opt-in regression fixture: an omitted neck channel prevents the
            // decoder's midpoint while the other garment dimensions survive.
            points.removeAll { ["neck_left", "neck_center"].contains($0.id) }
        }
        if bothSidesPartial {
            let missingIDs: Set<String> = kind == .top
                ? ["sleeve_end_left", "sleeve_end_right"] : ["hem_left_outer", "hem_right_outer"]
            points.removeAll { missingIDs.contains($0.id) }
        }
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
        // Version-1 synthetic rehearsals retain their original neck midpoint;
        // they are not evidence for the new contour/representative-plane path.
        let definitions = kind == .top ? TopLandmarkSchema.legacyMeasurementDefinitions : bottomDefinitions
        let landmarks = GarmentLandmarkSet(sessionID: sessionID, frameID: frameID, origin: .synthetic,
            modelVersion: isDesignReference ? "garment-ui-design-reference-synthetic-v1"
                : kind == .top ? "garment-ui-top-preview-v1" : "garment-ui-preview-v1", points: points, mask: mask,
            garmentKind: kind)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        let output = AutomaticMeasurementOutput(runID: UUID(),
            snapshot: .init(frame: frame, imageJPEG: image.jpegData(compressionQuality: 0.95)!),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: nil, landmarksSeconds: nil, measurementSeconds: nil, totalSeconds: 0),
            startedAt: .now, finishedAt: .now)
        return AutomaticMeasurement(output: output,
            context: .init(category: kind.category,
                specimenName: isDesignReference ? "디자인 사진 비교 · 합성 깊이 1m" : "화면 미리보기",
                deviceModel: "Synthetic UI preview"))
    }

    /// Keep the bundled source intact. Match the design's centered object-cover
    /// crop at runtime, then render RGB at the synthetic frame's calibrated size.
    private static func designReferenceImage() -> UIImage? {
        guard let url = Bundle.main.url(forResource: "garment", withExtension: "png"),
              let source = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let target = CGSize(width: 804, height: 1120)
        let aspect = target.width / target.height
        let sourceSize = CGSize(width: source.width, height: source.height)
        let cropWidth = min(sourceSize.width, sourceSize.height * aspect)
        let cropHeight = min(sourceSize.height, sourceSize.width / aspect)
        let cropRect = CGRect(x: (sourceSize.width - cropWidth) / 2,
            y: (sourceSize.height - cropHeight) / 2, width: cropWidth, height: cropHeight).integral
        guard let crop = source.cropping(to: cropRect) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = max(target.width / CGFloat(crop.width), target.height / CGFloat(crop.height))
        let drawnSize = CGSize(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale)
        let drawnRect = CGRect(x: (target.width - drawnSize.width) / 2,
            y: (target.height - drawnSize.height) / 2, width: drawnSize.width, height: drawnSize.height)
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: crop).draw(in: drawnRect)
        }
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
            fillColor: color.withAlphaComponent(0.40).cgColor, strokeColor: color.cgColor,
            reduceMotion: reduceMotion, gradientEndColor: UIColor.white.cgColor)
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
