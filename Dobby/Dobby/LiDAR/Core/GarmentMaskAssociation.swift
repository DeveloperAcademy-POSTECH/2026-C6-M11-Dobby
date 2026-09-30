import Foundation

nonisolated enum GarmentMaskAssociationError: Error, LocalizedError, Sendable, Equatable {
    case invalidMask, noForeground, multipleForegrounds, unmatchedGarment

    var errorDescription: String? {
        switch self {
        case .invalidMask: "사진과 옷 영역의 좌표가 맞지 않습니다. 다시 촬영해 주세요."
        case .noForeground: "옷의 윤곽을 찾지 못했습니다. 배경과 구분되도록 펼쳐 주세요."
        case .multipleForegrounds: "여러 대상이 보입니다. 주변 물건을 치우고 옷 한 벌만 촬영해 주세요."
        case .unmatchedGarment: "인식점과 옷의 윤곽이 일치하지 않습니다. 옷 전체가 보이도록 다시 촬영해 주세요."
        }
    }
}

nonisolated struct GarmentMaskSelection: Sendable {
    var mask: GarmentMask
    var bounds: NormalizedRect
    var matchedLandmarkCount: Int
    var observedLandmarkCount: Int
}

/// Associates a semantic landmark prediction with one independently segmented
/// foreground in the SAME image. Association tolerance never dilates the mask
/// passed to the depth engine. A generic foreground alone is not recognition.
nonisolated enum GarmentMaskAssociation {
    static func select(masks: [GarmentMask], points: [GarmentLandmark],
                       imageSize: PixelSize) throws -> GarmentMaskSelection {
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
        let matched = eligible.filter { landmark in
            let x = Int(landmark.point.x * Double(mask.size.width))
            let y = Int(landmark.point.y * Double(mask.size.height))
            for row in max(0, y - radius)...min(mask.size.height - 1, y + radius) {
                for column in max(0, x - radius)...min(mask.size.width - 1, x + radius) {
                    if mask.values[row * mask.size.width + column] == 1 { return true }
                }
            }
            return false
        }
        guard matched.count >= 3, Double(matched.count) / Double(eligible.count) >= 0.75,
              let minX = matched.map(\.point.x).min(), let maxX = matched.map(\.point.x).max(),
              let minY = matched.map(\.point.y).min(), let maxY = matched.map(\.point.y).max(),
              maxX - minX >= 0.03, maxY - minY >= 0.03 else {
            throw GarmentMaskAssociationError.unmatchedGarment
        }
        return .init(mask: mask, bounds: candidate.bounds,
                     matchedLandmarkCount: matched.count, observedLandmarkCount: eligible.count)
    }
}
