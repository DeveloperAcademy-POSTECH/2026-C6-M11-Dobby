import UIKit
import ImageIO

/// Image decoding, display geometry and device labels belong to presentation,
/// not to the saved measurement or the geometry model.
@MainActor
enum SnapshotPresentation {
    /// Decode a bounded presentation image off the UI actor. The saved JPEG and
    /// normalized landmark/depth coordinates retain their original resolution.
    static func thumbnail(for snapshot: CaptureSnapshot, maximumDimension: Int = 2048) async -> UIImage? {
        let data = snapshot.imageJPEG
        let limit = min(4096, max(256, maximumDimension))
        let decoded = await Task.detached(priority: .userInitiated) { () -> SnapshotDecodedImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: limit,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return SnapshotDecodedImage(image: image)
        }.value
        guard !Task.isCancelled, let decoded else { return nil }
        return UIImage(cgImage: decoded.image, scale: 1, orientation: uiOrientation(snapshot.frame.orientation))
    }

    static func image(for snapshot: CaptureSnapshot) -> UIImage? {
        guard let cg = UIImage(data: snapshot.imageJPEG)?.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: uiOrientation(snapshot.frame.orientation))
    }

    private static func uiOrientation(_ value: ImageOrientation) -> UIImage.Orientation {
        switch value {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    static func aspectRatio(for snapshot: CaptureSnapshot) -> CGFloat {
        let size = snapshot.frame.imageSize
        guard size.isValid else { return 1 }
        let rotated = snapshot.frame.orientation == .right || snapshot.frame.orientation == .left
        return rotated ? CGFloat(size.height) / CGFloat(size.width) : CGFloat(size.width) / CGFloat(size.height)
    }

    static func resultAspectRatio(for snapshot: CaptureSnapshot) -> CGFloat {
        let crop = snapshot.presentationCrop.flatMap { $0.isValid ? $0 : nil } ?? .full
        return aspectRatio(for: snapshot) * CGFloat(crop.width / crop.height)
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

/// CGImage is immutable and this privately owned decoded image only crosses
/// from the decoding task to the presentation actor.
private nonisolated struct SnapshotDecodedImage: @unchecked Sendable {
    let image: CGImage
}
