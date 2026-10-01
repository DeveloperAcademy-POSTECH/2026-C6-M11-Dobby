import Foundation

nonisolated enum GarmentMaskAssociationError: Error, LocalizedError, Sendable, Equatable {
    case invalidMask, noForeground, multipleForegrounds, unmatchedGarment

    var errorDescription: String? {
        switch self {
        case .invalidMask: "사진과 옷 영역의 좌표가 맞지 않습니다. 다시 촬영해 주세요."
        case .noForeground: "옷의 윤곽을 찾지 못했습니다. 배경과 구분되도록 펼쳐 주세요."
        case .multipleForegrounds: "여러 대상이 보입니다. 주변 물건을 치우고 옷 한 벌만 촬영해 주세요."
        case .unmatchedGarment: "옷은 촬영했지만 인식한 점을 윤곽과 연결하지 못했습니다. 소매를 펼치거나 사진에서 측정점을 직접 확인해 주세요."
        }
    }
}

nonisolated struct GarmentMaskSelection: Sendable {
    var mask: GarmentMask
    var bounds: NormalizedRect
    var matchedLandmarkCount: Int
    var observedLandmarkCount: Int
    /// Original direct points close enough to this exact foreground for use in
    /// measurement. This does not move a point onto the silhouette boundary.
    var associatedLandmarkIDs: Set<String> = []

    func validatedPoints(_ points: [GarmentLandmark]) -> [GarmentLandmark] {
        var result = points
        for index in result.indices where result[index].derivedFrom == nil {
            result[index].isVisible = result[index].isVisible
                && associatedLandmarkIDs.contains(result[index].id)
        }
        // A derived midpoint cannot restore an unconfirmed source point.
        for _ in result.indices {
            let visible = Set(result.filter(\.isVisible).map(\.id))
            var changed = false
            for index in result.indices {
                if let sources = result[index].derivedFrom,
                   result[index].isVisible, !sources.allSatisfy(visible.contains) {
                    result[index].isVisible = false
                    changed = true
                }
            }
            if !changed { break }
        }
        return result
    }
}

nonisolated enum GarmentMaskAssociationPolicy: Sendable {
    case strict
    /// Used only after both upright and half-turn strict top attempts fail.
    case partialTop
}

/// Associates a semantic landmark prediction with one independently segmented
/// foreground in the SAME image. Association tolerance never dilates the mask
/// passed to the depth engine. A generic foreground alone is not recognition.
nonisolated enum GarmentMaskAssociation {
    static func select(masks: [GarmentMask], points: [GarmentLandmark],
                       imageSize: PixelSize,
                       policy: GarmentMaskAssociationPolicy = .strict) throws -> GarmentMaskSelection {
        guard imageSize.isValid else { throw GarmentMaskAssociationError.invalidMask }
        var candidates: [(mask: GarmentMask, bounds: NormalizedRect)] = []
        for mask in masks {
            guard mask.size.isValid, mask.values.count <= 4_194_304,
                  mask.values.count == mask.size.width * mask.size.height,
                  mask.size.width * imageSize.height == mask.size.height * imageSize.width,
                  mask.values.allSatisfy({ $0 <= 1 }) else {
                throw GarmentMaskAssociationError.invalidMask
            }
            var count = 0, minX = mask.size.width, minY = mask.size.height, maxX = -1, maxY = -1
            for index in mask.values.indices where mask.values[index] == 1 {
                count += 1
                let x = index % mask.size.width, y = index / mask.size.width
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
            // Ignore tiny segmentation specks, but never choose the largest of
            // several substantial objects and silently call it the garment.
            guard Double(count) / Double(mask.values.count) >= 0.02 else { continue }
            candidates.append((mask, .init(x: Double(minX) / Double(mask.size.width),
                y: Double(minY) / Double(mask.size.height),
                width: Double(maxX - minX + 1) / Double(mask.size.width),
                height: Double(maxY - minY + 1) / Double(mask.size.height))))
        }
        guard !candidates.isEmpty else { throw GarmentMaskAssociationError.noForeground }
        guard candidates.count == 1 else { throw GarmentMaskAssociationError.multipleForegrounds }
        let candidate = candidates[0], mask = candidate.mask
        let eligible = points.filter {
            $0.derivedFrom == nil && $0.isVisible && $0.point.isValid
                && $0.confidence.map({ $0.isFinite && $0 >= 0.5 && $0 <= 1 }) == true
        }
        guard eligible.count >= 3, Set(eligible.map(\.id)).count == eligible.count else {
            throw GarmentMaskAssociationError.unmatchedGarment
        }
        // This is object association, not a claim that a boundary keypoint is
        // localized to this tolerance. Vision and pose have independent edge
        // errors; depth still receives the unexpanded segmentation below.
        let radius = max(2, min(8, Int(ceil(Double(min(mask.size.width, mask.size.height)) * 0.015))))
        func isAssociated(_ landmark: GarmentLandmark) -> Bool {
            let x = Int(landmark.point.x * Double(mask.size.width))
            let y = Int(landmark.point.y * Double(mask.size.height))
            for row in max(0, y - radius)...min(mask.size.height - 1, y + radius) {
                for column in max(0, x - radius)...min(mask.size.width - 1, x + radius) {
                    if mask.values[row * mask.size.width + column] == 1 { return true }
                }
            }
            return false
        }
        let matched = eligible.filter(isAssociated)
        guard matched.count >= 3,
              let minX = matched.map(\.point.x).min(), let maxX = matched.map(\.point.x).max(),
              let minY = matched.map(\.point.y).min(), let maxY = matched.map(\.point.y).max(),
              maxX - minX >= 0.03, maxY - minY >= 0.03 else {
            throw GarmentMaskAssociationError.unmatchedGarment
        }
        switch policy {
        case .strict:
            guard Double(matched.count) / Double(eligible.count) >= 0.75 else {
                throw GarmentMaskAssociationError.unmatchedGarment
            }
        case .partialTop:
            guard hasStrongTopBodySupport(matched), matched.count >= 6,
                  Double(matched.count) / Double(eligible.count) >= 0.5 else {
                throw GarmentMaskAssociationError.unmatchedGarment
            }
        }
        let associated = points.filter {
            $0.derivedFrom == nil && $0.isVisible && $0.point.isValid && isAssociated($0)
        }
        return .init(mask: mask, bounds: candidate.bounds,
                     matchedLandmarkCount: matched.count, observedLandmarkCount: eligible.count,
                     associatedLandmarkIDs: Set(associated.map(\.id)))
    }

    private static func hasStrongTopBodySupport(_ matched: [GarmentLandmark]) -> Bool {
        let strong = Dictionary(uniqueKeysWithValues: matched.filter { ($0.confidence ?? 0) >= 0.7 }
            .map { ($0.id, $0.point) })
        guard strong.count >= 4,
              let hemLeft = strong["hem_left"], let hemRight = strong["hem_right"] else { return false }
        let upper: (ImagePoint, ImagePoint)?
        if let left = strong["armpit_left"], let right = strong["armpit_right"] {
            upper = (left, right)
        } else if let left = strong["shoulder_left"], let right = strong["shoulder_right"] {
            upper = (left, right)
        } else { upper = nil }
        guard let upper else { return false }
        func distance(_ first: ImagePoint, _ second: ImagePoint) -> Double {
            hypot(first.x - second.x, first.y - second.y)
        }
        let upperCenter = ImagePoint(x: (upper.0.x + upper.1.x) / 2,
                                     y: (upper.0.y + upper.1.y) / 2)
        let hemCenter = ImagePoint(x: (hemLeft.x + hemRight.x) / 2,
                                   y: (hemLeft.y + hemRight.y) / 2)
        // Distinct bilateral body anchors must cover a body-sized region. Do
        // not let six duplicate sleeve/neck predictions identify another object.
        return distance(upper.0, upper.1) >= 0.05 && distance(hemLeft, hemRight) >= 0.05
            && distance(upperCenter, hemCenter) >= 0.1
    }
}
