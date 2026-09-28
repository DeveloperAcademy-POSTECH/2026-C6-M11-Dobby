import UIKit

/// Image decoding, display geometry and device labels belong to presentation,
/// not to the saved measurement or the geometry model.
@MainActor
enum SnapshotPresentation {
    static func image(for snapshot: CaptureSnapshot) -> UIImage? {
        guard let cg = UIImage(data: snapshot.imageJPEG)?.cgImage else { return nil }
        let orientation: UIImage.Orientation
        switch snapshot.frame.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    static func aspectRatio(for snapshot: CaptureSnapshot) -> CGFloat {
        let size = snapshot.frame.imageSize
        guard size.isValid else { return 1 }
        let rotated = snapshot.frame.orientation == .right || snapshot.frame.orientation == .left
        return rotated ? CGFloat(size.height) / CGFloat(size.width) : CGFloat(size.width) / CGFloat(size.height)
    }

    static var deviceIdentifier: String {
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "Simulator: " + model }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
