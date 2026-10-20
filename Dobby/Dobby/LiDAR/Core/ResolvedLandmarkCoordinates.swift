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
            let contour = output.points[index].contourRule != nil
            guard contour || effectiveDerivedSourceIDs(for: id) != nil else { continue }
            if let value = resolved.first(where: {
                $0.id == id && ((contour && $0.quality.method == .contourIntersection)
                    || (!contour && $0.quality.method == .spatialAverage)
                    || isRecoveredTopNeckCenter($0, landmark: output.points[index]))
            }),
               value.imagePoint.isValid {
                output.points[index].point = value.imagePoint
                output.points[index].isVisible = true
            } else {
                output.points[index].isVisible = false
            }
        }
        return output
    }

    /// New recovery keeps the 3D midpoint and verifies its depth-weighted image
    /// projection. Legacy centre-plane records retain their original 2D midpoint.
    /// Do not expose arbitrary direct samples as derived overlays.
    private nonisolated func isRecoveredTopNeckCenter(
        _ resolved: ResolvedLandmark, landmark: GarmentLandmark
    ) -> Bool {
        let sourceIDs = ["neck_left", "neck_right"]
        guard landmark.id == "neck_center", landmark.derivedFrom == sourceIDs,
              origin == .model, garmentKind == .top,
              modelVersion == AutomaticGarmentKind.legacyTopModelVersion,
              (landmark.origin ?? origin) == .model,
              landmark.isVisible, landmark.point.isValid,
              [.localPlane, .recoveredSpatialAverage].contains(resolved.quality.method),
              resolved.sourceLandmarkIDs == sourceIDs,
              resolved.quality.validSamples >= 3,
              resolved.quality.candidateSamples >= resolved.quality.validSamples,
              resolved.quality.planeResidualMeters.map({ $0.isFinite && $0 >= 0 }) == true,
              resolved.position.x.isFinite, resolved.position.y.isFinite,
              resolved.position.z.isFinite, resolved.position.z > 0,
              let mask, mask.size.isValid,
              mask.values.count == mask.size.width * mask.size.height else { return false }
        let x = Int(landmark.point.x * Double(mask.size.width))
        let y = Int(landmark.point.y * Double(mask.size.height))
        guard mask.values[y * mask.size.width + x] == 1 else { return false }
        let sources = sourceIDs.compactMap { id -> GarmentLandmark? in
            let matches = points.filter { $0.id == id }
            return matches.count == 1 ? matches[0] : nil
        }
        guard sources.count == 2, sources.allSatisfy({ source in
            source.derivedFrom == nil && source.point.isValid && source.isVisible
                && (source.origin ?? origin) == .model
                && source.confidence.map { $0.isFinite && (0...1).contains($0) } == true
        }) else { return false }
        let midpoint = ImagePoint(x: (sources[0].point.x + sources[1].point.x) / 2,
                                  y: (sources[0].point.y + sources[1].point.y) / 2)
        guard abs(landmark.point.x - midpoint.x) <= 1e-12,
              abs(landmark.point.y - midpoint.y) <= 1e-12 else { return false }
        if resolved.quality.method == .localPlane {
            return abs(resolved.imagePoint.x - midpoint.x) <= 1e-12
                && abs(resolved.imagePoint.y - midpoint.y) <= 1e-12
        }
        guard let positions = resolved.recoverySourcePositions, positions.count == 2,
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.z > 0 }),
              resolved.imagePoint.isValid else { return false }
        let totalDepth = positions[0].z + positions[1].z
        guard totalDepth.isFinite, totalDepth > 0 else { return false }
        let leftWeight = positions[0].z / totalDepth, rightWeight = positions[1].z / totalDepth
        let projected = ImagePoint(x: sources[0].point.x * leftWeight + sources[1].point.x * rightWeight,
                                   y: sources[0].point.y * leftWeight + sources[1].point.y * rightWeight)
        let position = Point3D(x: positions[0].x / 2 + positions[1].x / 2,
                               y: positions[0].y / 2 + positions[1].y / 2,
                               z: positions[0].z / 2 + positions[1].z / 2)
        return abs(resolved.imagePoint.x - projected.x) <= 1e-10
            && abs(resolved.imagePoint.y - projected.y) <= 1e-10
            && abs(resolved.position.x - position.x) <= 1e-10
            && abs(resolved.position.y - position.y) <= 1e-10
            && abs(resolved.position.z - position.z) <= 1e-10
    }
}
