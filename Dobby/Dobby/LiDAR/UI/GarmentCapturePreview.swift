import SwiftUI
import UIKit

/// Explicit UI rehearsal. Never used as a fallback for a camera/model failure.
@MainActor
enum GarmentCapturePreview {
    static func measurement(partial: Bool = false) -> AutomaticMeasurement {
        let size = PixelSize(width: 800, height: 1000)
        let maskSize = PixelSize(width: 400, height: 500)
        let vertices = [ImagePoint(x: 0.27, y: 0.15), .init(x: 0.73, y: 0.15),
            .init(x: 0.78, y: 0.87), .init(x: 0.57, y: 0.87), .init(x: 0.50, y: 0.46),
            .init(x: 0.43, y: 0.87), .init(x: 0.22, y: 0.87)]
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
        let sessionID = UUID(), frameID = UUID()
        let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 850, fy: 850, cx: 400, cy: 500, referenceSize: size),
            depth: .init(size: maskSize, values: .init(repeating: 1, count: pixels.count),
                         confidence: .init(repeating: 2, count: pixels.count)), source: .synthetic, orientation: .up)
        let ids = ["waist_left", "waist_right", "hem_right_outer", "hem_right_inner", "crotch", "hem_left_inner", "hem_left_outer"]
        var points = zip(ids, vertices).map { GarmentLandmark(id: $0.0, point: $0.1, confidence: 1) }
        points.append(.init(id: "waist_center", point: .init(x: 0.5, y: 0.15), confidence: 1,
                            derivedFrom: ["waist_left", "waist_right"]))
        if partial { points.removeAll { $0.id == "hem_right_inner" } }
        let pairs: [(String, String, String)] = [
            ("waist_left", "waist_right", "허리 단면"), ("waist_center", "crotch", "밑위(직선)"),
            ("waist_left", "hem_left_outer", "왼쪽 총장(직선)"),
            ("hem_left_outer", "hem_left_inner", "왼쪽 밑단 단면"),
            ("crotch", "hem_left_inner", "왼쪽 인심(직선)"),
            ("waist_right", "hem_right_outer", "오른쪽 총장(직선)"),
            ("hem_right_outer", "hem_right_inner", "오른쪽 밑단 단면"),
            ("crotch", "hem_right_inner", "오른쪽 인심(직선)")]
        let definitions = pairs.map {
            MeasurementDefinition(id: "bottom." + [$0.0, $0.1].sorted().joined(separator: "."),
                                  title: $0.2, landmarkIDs: [$0.0, $0.1])
        }
        let landmarks = GarmentLandmarkSet(sessionID: sessionID, frameID: frameID, origin: .synthetic,
            modelVersion: "garment-ui-preview-v1", points: points, mask: mask)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        let output = AutomaticMeasurementOutput(runID: UUID(),
            snapshot: .init(frame: frame, imageJPEG: image.jpegData(compressionQuality: 0.95)!),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: nil, landmarksSeconds: nil, measurementSeconds: nil, totalSeconds: 0),
            startedAt: .now, finishedAt: .now)
        return AutomaticMeasurement(output: output,
            context: .init(category: .bottoms, specimenName: "화면 미리보기", deviceModel: "Synthetic UI preview"))
    }
}

struct GarmentSilhouetteOverlay: View {
    let mask: GarmentMask
    var orientation: ImageOrientation = .up

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for contour in GarmentSilhouetteGeometry.contours(from: mask) ?? [] {
                for (index, source) in contour.enumerated() {
                    let point = ImageCoordinateTransform.originalToDisplay(source, orientation: orientation)
                    let mapped = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                }
                path.closeSubpath()
            }
            context.fill(path, with: .color(GarmentCaptureStyle.recognition.opacity(0.24)), style: .init(eoFill: true))
            context.stroke(path, with: .color(GarmentCaptureStyle.recognition),
                           style: .init(lineWidth: 2, lineJoin: .round))
        }.allowsHitTesting(false)
    }
}
