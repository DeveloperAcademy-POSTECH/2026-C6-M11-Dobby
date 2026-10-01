import Foundation

extension GarmentLandmarkSet {
    /// A depth-backed derived point is drawn at its reprojected 3D location.
    /// An unresolved derivation has no trustworthy overlay position; the raw
    /// photo midpoint remains archived for provenance but is hidden here.
    nonisolated func replacingDerivedImagePoints(with result: GarmentMeasurementResult?) -> Self {
        var output = self
        let matching = result?.sessionID == sessionID && result?.frameID == frameID
        let resolved = matching ? (result?.values.flatMap(\.points) ?? []) : []
        for index in output.points.indices {
            let id = output.points[index].id
            guard effectiveDerivedSourceIDs(for: id) != nil else { continue }
            if let value = resolved.first(where: { $0.id == id && $0.quality.method == .spatialAverage }),
               value.imagePoint.isValid {
                output.points[index].point = value.imagePoint
            } else {
                output.points[index].isVisible = false
            }
        }
        return output
    }
}
