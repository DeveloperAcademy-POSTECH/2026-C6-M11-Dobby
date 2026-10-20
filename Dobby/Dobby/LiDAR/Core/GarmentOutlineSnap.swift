import Foundation

/// A bounded calculation-input adjustment, distinct from an explicit user edit.
nonisolated struct GarmentAutomaticLandmarkAdjustment: Codable, Sendable, Equatable {
    var landmarkID: String
    var originalPoint: ImagePoint
    var adjustedPoint: ImagePoint
    var distancePixels: Double
    var limitPixels: Double
    var method: String = "mask-nearest-3pct-v1"
}

nonisolated struct GarmentOutlineSnapResult: Sendable {
    var points: [GarmentLandmark]
    var adjustments: [GarmentAutomaticLandmarkAdjustment]
}

/// Only call AFTER raw candidate/subject validation. Never expands the depth
/// mask, repairs rejected candidates or marks an automatic move as `.manual`.
nonisolated enum GarmentOutlineSnap {
    static func apply(points: [GarmentLandmark], mask: GarmentMask,
                      imageSize: PixelSize) throws -> GarmentOutlineSnapResult {
        guard imageSize.isValid, mask.size.isValid,
              mask.values.count <= 4_194_304,
              mask.values.count == mask.size.width * mask.size.height,
              mask.size.width * imageSize.height == mask.size.height * imageSize.width,
              mask.values.allSatisfy({ $0 <= 1 }) else { throw GarmentMaskAssociationError.invalidMask }
        var minX = mask.size.width, minY = mask.size.height, maxX = -1, maxY = -1
        for index in mask.values.indices where mask.values[index] == 1 {
            let x = index % mask.size.width, y = index / mask.size.width
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY else { throw GarmentMaskAssociationError.noForeground }
        // All distances share mask pixel units. Convert only the recorded
        // distance to the original RGB units, so rectangular images stay metric.
        let diagonal = hypot(Double(maxX - minX + 1), Double(maxY - minY + 1))
        let limit = diagonal * 0.03
        let imageScale = Double(imageSize.width) / Double(mask.size.width)
        var output = points
        var adjustments: [GarmentAutomaticLandmarkAdjustment] = []
        var changedIDs: Set<String> = []
        for index in output.indices {
            let landmark = points[index]
            guard landmark.derivedFrom == nil, landmark.contourRule == nil,
                  landmark.origin != .manual, landmark.isVisible, landmark.point.isValid else { continue }
            let px = landmark.point.x * Double(mask.size.width)
            let py = landmark.point.y * Double(mask.size.height)
            let containingX = Int(floor(px)), containingY = Int(floor(py))
            // A point already inside is preserved bit-for-bit, even near edges.
            if mask.values[containingY * mask.size.width + containingX] == 1 { continue }
            let lowX = max(0, Int(ceil(px - limit - 0.5)))
            let highX = min(mask.size.width - 1, Int(floor(px + limit - 0.5)))
            let lowY = max(0, Int(ceil(py - limit - 0.5)))
            let highY = min(mask.size.height - 1, Int(floor(py + limit - 0.5)))
            guard lowX <= highX, lowY <= highY else { continue }
            var best: (x: Int, y: Int, distance: Double)?
            for y in lowY...highY { for x in lowX...highX where mask.values[y * mask.size.width + x] == 1 {
                let distance = hypot(Double(x) + 0.5 - px, Double(y) + 0.5 - py)
                if distance <= limit, best == nil || distance < best!.distance {
                    best = (x, y, distance)
                }
            } }
            guard let best else { continue }
            let adjusted = ImagePoint(x: (Double(best.x) + 0.5) / Double(mask.size.width),
                                      y: (Double(best.y) + 0.5) / Double(mask.size.height))
            output[index].point = adjusted
            changedIDs.insert(landmark.id)
            adjustments.append(.init(landmarkID: landmark.id, originalPoint: landmark.point,
                adjustedPoint: adjusted, distancePixels: best.distance * imageScale, limitPixels: limit * imageScale))
        }
        // Refresh only the 2D display hint of genuine model averages. The engine
        // still resolves these in 3D and preserves the original confidence/origin.
        var pending = Set(output.indices.filter { output[$0].derivedFrom != nil })
        let byID = Dictionary(grouping: output.indices, by: { output[$0].id })
        for _ in 0..<min(64, pending.count) {
            var completed: [Int] = []
            for index in pending {
                guard let ids = output[index].derivedFrom, ids.count >= 2,
                      ids.allSatisfy({ byID[$0]?.count == 1 }),
                      ids.allSatisfy({ !pending.contains(byID[$0]![0]) }) else { continue }
                if ids.contains(where: changedIDs.contains) {
                    let parents = ids.map { output[byID[$0]![0]] }
                    let count = Double(parents.count)
                    output[index].point = .init(x: parents.reduce(0) { $0 + $1.point.x / count },
                                               y: parents.reduce(0) { $0 + $1.point.y / count })
                    changedIDs.insert(output[index].id)
                }
                completed.append(index)
            }
            if completed.isEmpty { break }
            pending.subtract(completed)
        }
        return .init(points: output, adjustments: adjustments)
    }
}
