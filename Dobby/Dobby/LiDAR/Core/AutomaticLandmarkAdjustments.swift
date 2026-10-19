import Foundation

nonisolated extension GarmentLandmarkSet {
    /// Updates display/provenance metadata only. The engine still resolves every
    /// contributor in 3D; this 2D average is never sampled as a depth coordinate.
    func refreshingDerivations(affectedBy directIDs: Set<String>) -> Self {
        var output = self
        let byID = Dictionary(grouping: points.indices, by: { points[$0].id })
        var affected = directIDs
        var completed: Set<String> = []
        func refresh(_ id: String, visiting: inout Set<String>) -> Bool {
            if completed.contains(id) { return affected.contains(id) }
            guard !visiting.contains(id), visiting.count < 64,
                  let indices = byID[id], indices.count == 1, let index = indices.first else { return false }
            guard let sources = calculationSourceIDs(for: id) else {
                completed.insert(id)
                return affected.contains(id)
            }
            guard (2...64).contains(sources.count), Set(sources).count == sources.count else { return false }
            visiting.insert(id)
            var changed = false
            for source in sources { changed = refresh(source, visiting: &visiting) || changed }
            visiting.remove(id)
            guard sources.allSatisfy({ byID[$0]?.count == 1 }) else { return false }
            if changed {
                let parents = sources.compactMap { byID[$0]?.first }.map { output.points[$0] }
                if output.points[index].contourRule != nil {
                    // The intersection will be recomputed on the same plane.
                    // Do not average the parent's image coordinates or replace
                    // an explicit manual override (whose rule has been cleared).
                    output.points[index].isVisible = false
                    output.points[index].confidence = nil
                    output.points[index].origin = .manual
                    affected.insert(id)
                    completed.insert(id)
                    return true
                }
                let count = Double(parents.count)
                output.points[index].point = .init(x: parents.reduce(0) { $0 + $1.point.x / count },
                                                  y: parents.reduce(0) { $0 + $1.point.y / count })
                output.points[index].isVisible = parents.allSatisfy { $0.isVisible && $0.point.isValid }
                output.points[index].confidence = nil
                output.points[index].origin = .manual
                affected.insert(id)
            }
            completed.insert(id)
            return changed
        }
        for point in points {
            var visiting: Set<String> = []
            _ = refresh(point.id, visiting: &visiting)
        }
        return output
    }
}
