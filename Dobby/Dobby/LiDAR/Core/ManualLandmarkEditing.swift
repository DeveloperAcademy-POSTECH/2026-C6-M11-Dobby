import Foundation

extension GarmentLandmarkSet {
    /// Explicitly confirms one original-image point by hand. Because origin belongs to
    /// the whole set, switching a model result to manual must first unconfirm every
    /// other model point; otherwise their model confidence would silently be bypassed.
    /// Returns false without changing the set for invalid coordinates or identifiers.
    @discardableResult
    nonisolated mutating func placeManualLandmark(at index: Int, point: ImagePoint) -> Bool {
        let identifiers = points.map(\.id)
        guard points.indices.contains(index), point.isValid,
              identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(identifiers).count == identifiers.count else { return false }

        if origin == .model {
            for other in points.indices {
                points[other].isVisible = false
                points[other].confidence = nil
            }
        }

        points[index].point = point
        points[index].isVisible = true
        points[index].confidence = nil
        origin = .manual
        modelVersion = nil
        return true
    }
}
