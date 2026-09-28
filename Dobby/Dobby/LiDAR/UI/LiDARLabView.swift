import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum DemoScenario: String, CaseIterable, Identifiable {
    case flat, tilted, noisy, missing
    var id: String { rawValue }
    var title: String {
        switch self { case .flat: "평면"; case .tilted: "기울기"; case .noisy: "잡음"; case .missing: "깊이 결손" }
    }
}

@MainActor
enum DemoSnapshotFactory {
    static func make(_ scenario: DemoScenario) -> (snapshot: CaptureSnapshot, landmarks: GarmentLandmarkSet, expected: Double) {
        let value = SyntheticFixtures.scene(tilted: scenario == .tilted, noisy: scenario == .noisy, missingDepth: scenario == .missing)
        let size = CGSize(width: value.frame.imageSize.width, height: value.frame.imageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor(red: 0.88, green: 0.91, blue: 0.90, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.65).cgColor)
            cg.setLineWidth(1)
            for x in stride(from: 0, through: Int(size.width), by: 40) {
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: Int(size.height)))
            }
            for y in stride(from: 0, through: Int(size.height), by: 40) {
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: Int(size.width), y: y))
            }
            cg.strokePath()
            let points = value.landmarks.points.map { CGPoint(x: $0.point.x * size.width, y: $0.point.y * size.height) }
            if points.count >= 2 {
                let a = points[0], b = points[1]
                let path = UIBezierPath(roundedRect: CGRect(x: min(a.x, b.x), y: a.y - 52, width: abs(b.x-a.x), height: 104), cornerRadius: 12)
                UIColor(red: 0.13, green: 0.29, blue: 0.27, alpha: 1).setFill(); path.fill()
                for index in 0...10 {
                    let x = a.x + (b.x-a.x) * CGFloat(index) / 10
                    cg.move(to: CGPoint(x: x, y: a.y - 42)); cg.addLine(to: CGPoint(x: x, y: a.y - 22))
                }
                cg.setLineWidth(2); cg.setStrokeColor(UIColor.white.cgColor); cg.strokePath()
            }
            let text = "50 cm · SYNTHETIC DEPTH"
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor.darkGray]
            (text as NSString).draw(at: CGPoint(x: 36, y: 35), withAttributes: attributes)
            ("\(scenario.title) — 센서 촬영 이미지가 아닙니다" as NSString).draw(at: CGPoint(x: 36, y: size.height - 65), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
        }
        return (.init(frame: value.frame, imageJPEG: image.jpegData(compressionQuality: 0.92) ?? Data()), value.landmarks, value.expectedMeters)
    }
}

extension View {
    func labCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}
