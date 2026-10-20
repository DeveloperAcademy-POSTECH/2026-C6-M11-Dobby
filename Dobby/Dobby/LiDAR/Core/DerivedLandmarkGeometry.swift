import Foundation

nonisolated extension GarmentLandmarkSet {
    /// Dependencies include contour rules without changing derivedFrom's 3D-average meaning.
    func calculationSourceIDs(for id: String) -> [String]? {
        let matches = points.filter { $0.id == id }
        guard matches.count == 1, let point = matches.first else { return nil }
        return point.contourRule?.sourceLandmarkIDs ?? effectiveDerivedSourceIDs(for: id)
    }

    /// Returns the declared 3D derivation, including invalid empty arrays so the
    /// measurement engine can reject them instead of sampling a display hint.
    func effectiveDerivedSourceIDs(for id: String) -> [String]? {
        let matches = points.filter { $0.id == id }
        guard matches.count == 1, let landmark = matches.first else { return nil }
        if let declared = landmark.derivedFrom { return declared }
        // Older bottom-model records stored a 2D waist midpoint. Their exact
        // model identity lets replay repair that known geometry without changing
        // arbitrary/manual points that happen to share the same ID.
        if origin == .model, modelVersion == "bottom7-976144d4d652", id == "waist_center" {
            return ["waist_left", "waist_right"]
        }
        return nil
    }
}
