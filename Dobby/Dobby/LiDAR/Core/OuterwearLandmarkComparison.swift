import Foundation

nonisolated enum OuterwearComparisonVariant: String, Codable, CaseIterable, Sendable, Identifiable {
    case original, garmentCrop, localRefinement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "A · 기존 전체 사진"
        case .garmentCrop: "B · 옷 영역 크롭"
        case .localRefinement: "C · 크롭 + 부위 확대"
        }
    }
}

nonisolated enum OuterwearComparisonRegion: String, Codable, CaseIterable, Sendable {
    case garment, upper, armpits, leftCuff, rightCuff, hem
    var pointIDs: [String] {
        switch self {
        case .garment: TopLandmarkSchema.expectedKeypoints + ["top_length_start", "front_length_start"]
        case .upper: ["neck_left", "neck_right", "shoulder_left", "shoulder_right", "top_length_start", "front_length_start"]
        case .armpits: ["armpit_left", "armpit_right"]
        case .leftCuff: ["sleeve_end_left"]
        case .rightCuff: ["sleeve_end_right"]
        case .hem: ["hem_left", "hem_center", "hem_right"]
        }
    }
}

/// Every rect refers to the same upright source. Pixel alignment happens before
/// cropping so inverse mapping uses the actual raster extent, not a nominal box.
nonisolated struct OuterwearComparisonCrop: Codable, Sendable {
    var region: OuterwearComparisonRegion
    var rect: NormalizedRect
}

nonisolated enum OuterwearComparisonGeometry {
    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    static func garmentBounds(mask: GarmentMask) throws -> NormalizedRect {
        guard mask.size.isValid, mask.values.count == mask.size.width * mask.size.height else {
            throw GarmentMaskAssociationError.invalidMask
        }
        var minX = mask.size.width, minY = mask.size.height, maxX = -1, maxY = -1, count = 0
        for i in mask.values.indices where mask.values[i] == 1 {
            let x = i % mask.size.width, y = i / mask.size.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y); count += 1
        }
        guard count >= 1, Double(count) / Double(mask.values.count) >= 0.02 else {
            throw GarmentMaskAssociationError.noForeground
        }
        let w = Double(mask.size.width), h = Double(mask.size.height)
        return .init(x: Double(minX) / w, y: Double(minY) / h,
                     width: Double(maxX - minX + 1) / w, height: Double(maxY - minY + 1) / h)
    }

    static func padded(_ rect: NormalizedRect, fraction: Double = 0.06) -> NormalizedRect {
        let x = max(0, rect.x - rect.width * fraction), y = max(0, rect.y - rect.height * fraction)
        return .init(x: x, y: y, width: min(1, rect.x + rect.width * (1 + fraction)) - x,
                     height: min(1, rect.y + rect.height * (1 + fraction)) - y)
    }

    static func aligned(_ rect: NormalizedRect, size: PixelSize) throws -> NormalizedRect {
        guard rect.isValid, size.isValid else { throw OuterwearLandmarkError.invalidResponse }
        let w = Double(size.width), h = Double(size.height)
        let x = max(0, floor(rect.x * w)), y = max(0, floor(rect.y * h))
        let right = min(w, ceil((rect.x + rect.width) * w))
        let bottom = min(h, ceil((rect.y + rect.height) * h))
        return .init(x: x / w, y: y / h, width: (right - x) / w, height: (bottom - y) / h)
    }

    static func observations(_ response: OuterwearLandmarkResponse) -> [String: OuterwearLandmarkObservation] {
        var points = response.points
        points["top_length_start"] = response.totalLengthStart
        if !response.isFrontOnly { points["front_length_start"] = response.frontNeckSeamCenter }
        return points
    }

    static func restoring(_ response: OuterwearLandmarkResponse, crops: [OuterwearComparisonCrop]) throws -> OuterwearLandmarkResponse {
        try response.validate(expectedRequestID: response.requestID)
        guard crops.allSatisfy({ $0.rect.isValid }), Set(crops.map(\.region)).count == crops.count else {
            throw OuterwearLandmarkError.invalidResponse
        }
        var result = response
        for (id, observation) in observations(response) {
            let matches = crops.filter { $0.region.pointIDs.contains(id) }
            guard matches.count == 1 else { throw OuterwearLandmarkError.invalidResponse }
            var restored = observation
            if let p = observation.point {
                let r = matches[0].rect
                let mapped = ImagePoint(x: r.x + p.x * r.width, y: r.y + p.y * r.height)
                guard mapped.isValid else { throw OuterwearLandmarkError.invalidCoordinate(id) }
                restored.point = mapped
            }
            if var support = id == "top_length_start" ? response.centerSupport?.frontNeckSeamCenter
                : id == "hem_center" ? response.centerSupport?.hemCenter : nil {
                let r = matches[0].rect
                support.left = .init(x: r.x + support.left.x * r.width, y: r.y + support.left.y * r.height)
                support.right = .init(x: r.x + support.right.x * r.width, y: r.y + support.right.y * r.height)
                if id == "top_length_start" { result.centerSupport?.frontNeckSeamCenter = support }
                else { result.centerSupport?.hemCenter = support }
            }
            if id == "top_length_start", response.isFrontOnly { result.frontNeckSeamCenter = restored }
            else if id == "top_length_start" { result.backNeckSeamCenter = restored }
            else if id == "front_length_start" { result.frontNeckSeamCenter = restored }
            else { result.points[id] = restored }
        }
        return result
    }

    /// Coarse B observations choose generous windows, never final coordinates.
    /// Missing anchors use overlapping garment-relative windows rather than (0.5,0.5).
    static func refinementCrops(response: OuterwearLandmarkResponse, bounds: NormalizedRect,
                                size: PixelSize) throws -> [OuterwearComparisonCrop] {
        let observations = observations(response)
        return try OuterwearComparisonRegion.allCases.filter { $0 != .garment }.map { region in
            let fallback: NormalizedRect
            switch region {
            case .upper: fallback = .init(x: 0, y: 0, width: 1, height: 0.62)
            case .armpits: fallback = .init(x: 0, y: 0.15, width: 1, height: 0.7)
            case .leftCuff: fallback = .init(x: 0, y: 0, width: 0.5, height: 1)
            case .rightCuff: fallback = .init(x: 0.5, y: 0, width: 0.5, height: 1)
            case .hem: fallback = .init(x: 0, y: 0.5, width: 1, height: 0.5)
            case .garment: fallback = full
            }
            var box = NormalizedRect(x: bounds.x + fallback.x * bounds.width,
                y: bounds.y + fallback.y * bounds.height,
                width: fallback.width * bounds.width, height: fallback.height * bounds.height)
            let anchors = region.pointIDs.compactMap { observations[$0]?.point }.filter {
                $0.x >= bounds.x && $0.x <= bounds.x + bounds.width
                    && $0.y >= bounds.y && $0.y <= bounds.y + bounds.height
            }
            // Tighten only when all primary anchors exist. A missing total-length
            // helper does not invalidate an otherwise complete upper-neck crop.
            let primary = region.pointIDs.filter { !["top_length_start", "front_length_start", "hem_center"].contains($0) }
            let completePrimary = primary.allSatisfy { id in
                guard let p = observations[id]?.point else { return false }
                return p.x >= bounds.x && p.x <= bounds.x + bounds.width
                    && p.y >= bounds.y && p.y <= bounds.y + bounds.height
            }
            if completePrimary, let x0 = anchors.map(\.x).min(), let x1 = anchors.map(\.x).max(),
               let y0 = anchors.map(\.y).min(), let y1 = anchors.map(\.y).max() {
                let px = bounds.width * 0.12, py = bounds.height * 0.15
                let x = max(0, x0 - px), y = max(0, y0 - py)
                box = .init(x: x, y: y, width: min(1, x1 + px) - x, height: min(1, y1 + py) - y)
            }
            return .init(region: region, rect: try aligned(box, size: size))
        }
    }
}

nonisolated struct OuterwearComparisonInput: Codable, Sendable {
    var crop: OuterwearComparisonCrop
    var width: Int
    var height: Int
    var jpeg: Data
}

nonisolated struct OuterwearComparisonResult: Codable, Sendable, Identifiable {
    var variant: OuterwearComparisonVariant
    var requestID: UUID
    var durationSeconds: Double
    var incrementalSeconds: Double
    var inputs: [OuterwearComparisonInput]
    var localResponse: OuterwearLandmarkResponse?
    var response: OuterwearLandmarkResponse?
    var diagnostics: GarmentRecognitionDiagnostics?
    var validationError: String?
    var requestError: String?
    var id: OuterwearComparisonVariant { variant }
}

nonisolated struct OuterwearComparisonReport: Codable, Sendable {
    var version = "outerwear-comparison-v1"
    var id: UUID
    var createdAt: Date
    var sourceSHA256: String
    var sourceSize: PixelSize
    var sourceJPEG: Data
    var category: String
    var orientationPrediction: GarmentOrientationPrediction
    var mask: GarmentMask
    var results: [OuterwearComparisonResult]
    /// Optional so existing experiment files still decode. Preserve classifier
    /// evidence used by the automatic target gate for this run.
    var classifierScores: [GarmentClassificationScore]? = nil
    var classifierRoute: GarmentClassifierRoute? = nil
    /// First prediction above remains raw; this records the applied transform
    /// and any extra local checks instead of inventing a corrected probability.
    var orientationResolution: GarmentOrientationResolution? = nil
}
