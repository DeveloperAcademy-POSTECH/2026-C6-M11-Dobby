import Foundation

/// Disposable photo handles, never calculation or archive inputs. Unavailable
/// observations remain unavailable until the user explicitly places a point.
nonisolated struct GarmentEditingPointPresentation {
    var landmarks: GarmentLandmarkSet
    var pendingIDs: Set<String>

    static func make(displayed: GarmentLandmarkSet, source: GarmentLandmarkSet,
                     snapshot: CaptureSnapshot, crop: PhotoDisplayCrop? = nil) -> Self {
        var result = displayed
        var pending = Set<String>()
        let upright = source.recognitionDiagnostics?.selectedPoseOrientation ?? snapshot.frame.orientation
        let raw = source.recognitionDiagnostics?.rawPoints ?? []
        func anchor(_ id: String) -> ImagePoint? {
            guard let point = (source.points + raw).first(where: {
                $0.id == id && $0.isVisible && $0.point.isValid && $0.contourRule == nil
            }) else { return nil }
            return ImageCoordinateTransform.originalToDisplay(point.point, orientation: upright)
        }
        func midpoint(_ a: String, _ b: String) -> ImagePoint? {
            guard let a = anchor(a), let b = anchor(b) else { return nil }
            return .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        if let mask = source.mask, let box = try? OuterwearComparisonGeometry.garmentBounds(mask: mask) {
            let corners = [(box.x, box.y), (box.x + box.width, box.y),
                           (box.x, box.y + box.height), (box.x + box.width, box.y + box.height)]
                .map { ImageCoordinateTransform.originalToDisplay(.init(x: $0.0, y: $0.1), orientation: upright) }
            let x = corners.map(\.x).min()!, y = corners.map(\.y).min()!
            bounds = .init(x: x, y: y, width: corners.map(\.x).max()! - x, height: corners.map(\.y).max()! - y)
        }
        func hint(_ id: String, index: Int) -> ImagePoint {
            let position: ImagePoint
            switch id {
            case "top_length_start", "front_length_start", "neck_center":
                position = midpoint("neck_left", "neck_right") ?? midpoint("shoulder_left", "shoulder_right")
                    ?? .init(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height * 0.25)
            case "hem_center":
                position = midpoint("hem_left", "hem_right")
                    ?? .init(x: midpoint("armpit_left", "armpit_right")?.x ?? bounds.x + bounds.width / 2,
                             y: bounds.y + bounds.height * 0.92)
            default:
                // Layout hints only. These ratios are never measured or saved.
                let ratios: [String: (Double, Double)] = [
                    "neck_left": (0.42, 0.25), "neck_right": (0.58, 0.25),
                    "shoulder_left": (0.3, 0.3), "shoulder_right": (0.7, 0.3),
                    "armpit_left": (0.32, 0.5), "armpit_right": (0.68, 0.5),
                    "sleeve_end_left": (0.08, 0.68), "sleeve_end_right": (0.92, 0.68),
                    "hem_left": (0.32, 0.92), "hem_right": (0.68, 0.92)]
                let ratio = ratios[id] ?? (index.isMultiple(of: 2) ? 0.35 : 0.65, 0.2 + 0.1 * Double(index % 7))
                position = .init(x: bounds.x + ratio.0 * bounds.width, y: bounds.y + ratio.1 * bounds.height)
            }
            return ImageCoordinateTransform.displayToOriginal(position, orientation: upright)
        }
        let requestedCrop = crop ?? snapshot.presentationCrop ?? .full
        let viewport = requestedCrop.isValid ? requestedCrop : .full
        func onScreen(_ point: ImagePoint) -> ImagePoint {
            let p = ImageCoordinateTransform.originalToDisplay(point, orientation: snapshot.frame.orientation)
            let visible = ImagePoint(x: min(viewport.x + viewport.width * 0.98, max(viewport.x + viewport.width * 0.02, p.x)),
                y: min(viewport.y + viewport.height * 0.98, max(viewport.y + viewport.height * 0.02, p.y)))
            return ImageCoordinateTransform.displayToOriginal(visible, orientation: snapshot.frame.orientation)
        }
        for index in result.points.indices {
            let point = result.points[index]
            guard !point.isVisible || !point.point.isValid else { continue }
            pending.insert(point.id)
            // A rejected AI position is more useful than a generic hint. A null
            // remote slot's (0.5,0.5) sentinel is not an observed coordinate.
            let candidate = raw.first { $0.id == point.id && $0.isVisible && $0.point.isValid }?.point
            result.points[index].point = onScreen(candidate ?? hint(point.id, index: index))
            result.points[index].isVisible = true
        }
        return .init(landmarks: result, pendingIDs: pending)
    }
}
