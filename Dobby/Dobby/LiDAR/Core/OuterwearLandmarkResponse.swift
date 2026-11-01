import Foundation

/// Wire observations describe visibility, not a calibrated pose-detector probability.
nonisolated enum OuterwearLandmarkVisibility: String, Codable, Sendable {
    case visible, occluded, uncertain, estimated
}

nonisolated enum OuterwearLandmarkView: String, Codable, Sendable {
    case front, back, unknown
}

nonisolated enum OuterwearLandmarkNeckStyle: String, Codable, Sendable {
    case hood, collar, standCollar = "stand_collar", hoodAndCollar = "hood_and_collar", collarless, unknown
}

nonisolated enum OuterwearLandmarkError: Error, LocalizedError, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying, AutomaticMeasurementFailureCauseProviding {
    case invalidResponse, mismatchedRequest, invalidCoordinate(String), unsupportedGeometry

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "아우터 측정점 응답의 형식을 확인하지 못했어요."
        case .mismatchedRequest: "아우터 측정점이 이번 촬영 요청과 일치하지 않아요."
        case .invalidCoordinate: "아우터 측정점의 사진 좌표를 확인하지 못했어요."
        case .unsupportedGeometry: "아우터 측정점과 옷 영역의 연결을 확인하지 못했어요."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        self == .mismatchedRequest ? .frameMismatch : .providerFailure
    }
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        self == .unsupportedGeometry ? .garmentStructureUnverified : .invalidRecognitionResult
    }
}

nonisolated struct OuterwearLandmarkObservation: Codable, Sendable {
    var point: ImagePoint?
    var visibility: OuterwearLandmarkVisibility

    init(point: ImagePoint?, visibility: OuterwearLandmarkVisibility) {
        self.point = point
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case point, visibility }

    init(from decoder: any Decoder) throws {
        try OuterwearWireKeys.require(decoder, keys: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try container.decode(OuterwearLandmarkVisibility.self, forKey: .visibility)
        point = try container.decodeIfPresent(StrictPoint.self, forKey: .point)?.value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The wire contract requires an explicit null for unavailable positions.
        try container.encode(point, forKey: .point)
        try container.encode(visibility, forKey: .visibility)
    }

    fileprivate func validate(id: String) throws {
        if visibility == .visible || visibility == .estimated {
            guard let point, point.isValid else { throw OuterwearLandmarkError.invalidCoordinate(id) }
        } else if point != nil {
            throw OuterwearLandmarkError.invalidResponse
        }
    }

    fileprivate struct StrictPoint: Decodable {
        let value: ImagePoint
        private enum CodingKeys: String, CodingKey { case x, y }
        init(from decoder: any Decoder) throws {
            try OuterwearWireKeys.require(decoder, keys: ["x", "y"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = .init(x: try container.decode(Double.self, forKey: .x),
                          y: try container.decode(Double.self, forKey: .y))
        }
    }
}

/// Two directly observed edges supporting a virtual center. Coordinates use the
/// same space as the corresponding center (including in refinement crops).
nonisolated struct OuterwearCenterSupport: Codable, Sendable {
    var left: ImagePoint
    var right: ImagePoint
    var midpoint: ImagePoint { .init(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2) }
    private enum CodingKeys: String, CodingKey { case left, right }
    init(left: ImagePoint, right: ImagePoint) { self.left = left; self.right = right }
    init(from decoder: any Decoder) throws {
        try OuterwearWireKeys.require(decoder, keys: ["left", "right"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(OuterwearLandmarkObservation.StrictPoint.self, forKey: .left).value
        right = try c.decode(OuterwearLandmarkObservation.StrictPoint.self, forKey: .right).value
    }
}

nonisolated struct OuterwearCenterSupports: Codable, Sendable {
    var frontNeckSeamCenter: OuterwearCenterSupport?
    var hemCenter: OuterwearCenterSupport?
    private enum CodingKeys: String, CodingKey { case frontNeckSeamCenter, hemCenter = "hem_center" }
    init(frontNeckSeamCenter: OuterwearCenterSupport? = nil, hemCenter: OuterwearCenterSupport? = nil) {
        self.frontNeckSeamCenter = frontNeckSeamCenter; self.hemCenter = hemCenter
    }
    init(from decoder: any Decoder) throws {
        try OuterwearWireKeys.require(decoder, keys: ["frontNeckSeamCenter", "hem_center"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frontNeckSeamCenter = try c.decodeIfPresent(OuterwearCenterSupport.self, forKey: .frontNeckSeamCenter)
        hemCenter = try c.decodeIfPresent(OuterwearCenterSupport.self, forKey: .hemCenter)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frontNeckSeamCenter, forKey: .frontNeckSeamCenter)
        try c.encode(hemCenter, forKey: .hemCenter)
    }
}

/// Coordinates remain in the uploaded upright image until the policy restores
/// them to the complete raw RGB grid. The original snapshot is never rewritten.
nonisolated struct OuterwearLandmarkResponse: Codable, Sendable {
    static let expectedSchemaVersion = "outerwear-landmarks-v1"
    static let expectedModelVersion = "luna-outerwear11-backseam-v1"
    static let expectedViewLengthSchemaVersion = "outerwear-landmarks-v2"
    static let expectedViewLengthModelVersion = "luna-outerwear11-view-length-v2"
    static let expectedFrontLengthSchemaVersion = "outerwear-landmarks-v3"
    static let expectedFrontLengthModelVersion = "luna-outerwear11-front-length-v3"
    static let expectedGapSchemaVersion = "outerwear-landmarks-v4"
    static let expectedGapModelVersion = "luna-outerwear11-front-gap-v4"
    static let expectedModel = "gpt-6-luna"

    var requestID: String
    var schemaVersion: String
    var modelVersion: String
    var model: String
    var view: OuterwearLandmarkView
    var neckStyle: OuterwearLandmarkNeckStyle
    var points: [String: OuterwearLandmarkObservation]
    var backNeckSeamCenter: OuterwearLandmarkObservation
    /// Absent only in the exact legacy v1 wire contract. In v2 the observation
    /// itself is required, while its point may explicitly be unavailable.
    var centerSupport: OuterwearCenterSupports?
    var frontNeckSeamCenter: OuterwearLandmarkObservation?

    init(requestID: String, schemaVersion: String = Self.expectedSchemaVersion,
         modelVersion: String = Self.expectedModelVersion, model: String = Self.expectedModel,
         view: OuterwearLandmarkView, neckStyle: OuterwearLandmarkNeckStyle,
         points: [String: OuterwearLandmarkObservation],
         backNeckSeamCenter: OuterwearLandmarkObservation = .init(point: nil, visibility: .uncertain),
         frontNeckSeamCenter: OuterwearLandmarkObservation? = nil,
         centerSupport: OuterwearCenterSupports? = nil) {
        self.requestID = requestID
        self.schemaVersion = schemaVersion
        self.modelVersion = modelVersion
        self.model = model
        self.view = view
        self.neckStyle = neckStyle
        self.points = points
        self.backNeckSeamCenter = backNeckSeamCenter
        self.centerSupport = centerSupport
        self.frontNeckSeamCenter = frontNeckSeamCenter
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestID = "requestId", schemaVersion, modelVersion, model, view, neckStyle, points, backNeckSeamCenter,
             frontNeckSeamCenter, centerSupport
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        let keys: [CodingKeys]
        switch schemaVersion {
        case Self.expectedSchemaVersion:
            keys = CodingKeys.allCases.filter { $0 != .frontNeckSeamCenter && $0 != .centerSupport }
        case Self.expectedViewLengthSchemaVersion:
            keys = CodingKeys.allCases.filter { $0 != .centerSupport }
        case Self.expectedFrontLengthSchemaVersion:
            keys = CodingKeys.allCases.filter { $0 != .backNeckSeamCenter && $0 != .centerSupport }
        case Self.expectedGapSchemaVersion:
            keys = CodingKeys.allCases.filter { $0 != .backNeckSeamCenter }
        default:
            throw OuterwearLandmarkError.invalidResponse
        }
        try OuterwearWireKeys.require(decoder, keys: keys.map(\.rawValue))
        requestID = try container.decode(String.self, forKey: .requestID)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        model = try container.decode(String.self, forKey: .model)
        view = try container.decode(OuterwearLandmarkView.self, forKey: .view)
        neckStyle = try container.decode(OuterwearLandmarkNeckStyle.self, forKey: .neckStyle)
        points = try container.decode([String: OuterwearLandmarkObservation].self, forKey: .points)
        centerSupport = try container.decodeIfPresent(OuterwearCenterSupports.self, forKey: .centerSupport)
        backNeckSeamCenter = [Self.expectedFrontLengthSchemaVersion, Self.expectedGapSchemaVersion].contains(schemaVersion)
            ? .init(point: nil, visibility: .uncertain)
            : try container.decode(OuterwearLandmarkObservation.self, forKey: .backNeckSeamCenter)
        frontNeckSeamCenter = schemaVersion != Self.expectedSchemaVersion
            ? try container.decode(OuterwearLandmarkObservation.self, forKey: .frontNeckSeamCenter) : nil
    }

    var isFrontOnly: Bool {
        (schemaVersion == Self.expectedFrontLengthSchemaVersion && modelVersion == Self.expectedFrontLengthModelVersion) || allowsCenterEstimates
    }

    var allowsCenterEstimates: Bool {
        schemaVersion == Self.expectedGapSchemaVersion && modelVersion == Self.expectedGapModelVersion
    }

    var totalLengthStart: OuterwearLandmarkObservation {
        isFrontOnly ? frontNeckSeamCenter ?? .init(point: nil, visibility: .uncertain) : backNeckSeamCenter
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(model, forKey: .model)
        try container.encode(view, forKey: .view)
        try container.encode(neckStyle, forKey: .neckStyle)
        try container.encode(points, forKey: .points)
        if ![Self.expectedFrontLengthSchemaVersion, Self.expectedGapSchemaVersion].contains(schemaVersion) {
            try container.encode(backNeckSeamCenter, forKey: .backNeckSeamCenter)
        }
        try container.encodeIfPresent(frontNeckSeamCenter, forKey: .frontNeckSeamCenter)
        try container.encodeIfPresent(centerSupport, forKey: .centerSupport)
    }

    func validate(expectedRequestID: String) throws {
        guard !expectedRequestID.isEmpty, expectedRequestID.count <= 128,
              requestID == expectedRequestID else { throw OuterwearLandmarkError.mismatchedRequest }
        let isLegacy = schemaVersion == Self.expectedSchemaVersion && modelVersion == Self.expectedModelVersion
            && frontNeckSeamCenter == nil
        let isViewLength = schemaVersion == Self.expectedViewLengthSchemaVersion
            && modelVersion == Self.expectedViewLengthModelVersion && frontNeckSeamCenter != nil
        let isFrontLength = isFrontOnly && frontNeckSeamCenter != nil
            && backNeckSeamCenter.point == nil && backNeckSeamCenter.visibility == .uncertain
            && (view == .front || frontNeckSeamCenter?.point == nil)
        guard isLegacy || isViewLength || isFrontLength, model == Self.expectedModel,
              Set(points.keys) == Set(TopLandmarkSchema.expectedKeypoints) else {
            throw OuterwearLandmarkError.invalidResponse
        }
        guard allowsCenterEstimates ? centerSupport != nil : centerSupport == nil else {
            throw OuterwearLandmarkError.invalidResponse
        }
        for id in TopLandmarkSchema.expectedKeypoints {
            try points[id]!.validate(id: id)
            if points[id]!.visibility == .estimated && !(allowsCenterEstimates && id == "hem_center") {
                throw OuterwearLandmarkError.invalidResponse
            }
        }
        if backNeckSeamCenter.visibility == .estimated || (frontNeckSeamCenter?.visibility == .estimated && !allowsCenterEstimates) {
            throw OuterwearLandmarkError.invalidResponse
        }
        if allowsCenterEstimates {
            for (observation, support) in [(frontNeckSeamCenter!, centerSupport!.frontNeckSeamCenter),
                                            (points["hem_center"]!, centerSupport!.hemCenter)] {
                if observation.visibility == .estimated {
                    guard view == .front, let support, support.left.isValid, support.right.isValid,
                          support.left.x < support.right.x, let point = observation.point,
                          abs(point.x - support.midpoint.x) < 1e-9, abs(point.y - support.midpoint.y) < 1e-9 else {
                        throw OuterwearLandmarkError.invalidResponse
                    }
                } else if support != nil { throw OuterwearLandmarkError.invalidResponse }
            }
        }
        try backNeckSeamCenter.validate(id: "top_length_start")
        try frontNeckSeamCenter?.validate(id: "front_length_start")
    }
}

/// Total-length recovery cannot return or replace any shoulder, chest or sleeve
/// observation. Each of its two coordinates belongs to its named detail crop.
nonisolated struct OuterwearLengthRefinementResponse: Codable, Sendable {
    static let expectedVersion = "outerwear-two-center-refinement-v4"
    var requestID: String
    var refinementVersion = Self.expectedVersion
    var modelVersion = OuterwearLandmarkResponse.expectedGapModelVersion
    var model = OuterwearLandmarkResponse.expectedModel
    var view: OuterwearLandmarkView
    var neckStyle: OuterwearLandmarkNeckStyle
    var frontNeckSeamCenter: OuterwearLandmarkObservation
    var hemCenter: OuterwearLandmarkObservation
    var centerSupport: OuterwearCenterSupports

    init(requestID: String, view: OuterwearLandmarkView, neckStyle: OuterwearLandmarkNeckStyle,
         frontNeckSeamCenter: OuterwearLandmarkObservation, hemCenter: OuterwearLandmarkObservation,
         centerSupport: OuterwearCenterSupports) {
        self.requestID = requestID; self.view = view; self.neckStyle = neckStyle
        self.frontNeckSeamCenter = frontNeckSeamCenter; self.hemCenter = hemCenter; self.centerSupport = centerSupport
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestID = "requestId", refinementVersion, modelVersion, model, view, neckStyle,
             frontNeckSeamCenter, hemCenter = "hem_center", centerSupport
    }
    init(from decoder: any Decoder) throws {
        try OuterwearWireKeys.require(decoder, keys: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID)
        refinementVersion = try c.decode(String.self, forKey: .refinementVersion)
        modelVersion = try c.decode(String.self, forKey: .modelVersion)
        model = try c.decode(String.self, forKey: .model)
        view = try c.decode(OuterwearLandmarkView.self, forKey: .view)
        neckStyle = try c.decode(OuterwearLandmarkNeckStyle.self, forKey: .neckStyle)
        frontNeckSeamCenter = try c.decode(OuterwearLandmarkObservation.self, forKey: .frontNeckSeamCenter)
        hemCenter = try c.decode(OuterwearLandmarkObservation.self, forKey: .hemCenter)
        centerSupport = try c.decode(OuterwearCenterSupports.self, forKey: .centerSupport)
    }

    /// Reuse v4 point/support validation and existing archive diagnostics. Null
    /// slots are not new observations of the other ten points.
    func landmarkResponse(expectedRequestID: String) throws -> OuterwearLandmarkResponse {
        guard refinementVersion == Self.expectedVersion,
              modelVersion == OuterwearLandmarkResponse.expectedGapModelVersion,
              view == .front || (frontNeckSeamCenter.point == nil && hemCenter.point == nil) else {
            throw OuterwearLandmarkError.invalidResponse
        }
        var points = Dictionary(uniqueKeysWithValues: TopLandmarkSchema.expectedKeypoints.map {
            ($0, OuterwearLandmarkObservation(point: nil, visibility: .uncertain))
        })
        points["hem_center"] = hemCenter
        let result = OuterwearLandmarkResponse(requestID: requestID,
            schemaVersion: OuterwearLandmarkResponse.expectedGapSchemaVersion, modelVersion: modelVersion, model: model,
            view: view, neckStyle: neckStyle, points: points,
            frontNeckSeamCenter: frontNeckSeamCenter, centerSupport: centerSupport)
        try result.validate(expectedRequestID: expectedRequestID)
        return result
    }

    func restoring(crops: [OuterwearComparisonCrop]) throws -> Self {
        _ = try landmarkResponse(expectedRequestID: requestID)
        guard crops.count == 2, Set(crops.map(\.region)) == Set([.upper, .hem]),
              crops.allSatisfy({ $0.rect.isValid }) else { throw OuterwearLandmarkError.invalidResponse }
        var result = self
        for crop in crops {
            func restore(_ p: ImagePoint) -> ImagePoint {
                .init(x: crop.rect.x + p.x * crop.rect.width, y: crop.rect.y + p.y * crop.rect.height)
            }
            var observation = crop.region == .upper ? frontNeckSeamCenter : hemCenter
            observation.point = observation.point.map(restore)
            var support = crop.region == .upper ? centerSupport.frontNeckSeamCenter : centerSupport.hemCenter
            if let original = support {
                support = .init(left: restore(original.left), right: restore(original.right))
            }
            if crop.region == .upper {
                result.frontNeckSeamCenter = observation; result.centerSupport.frontNeckSeamCenter = support
            } else {
                result.hemCenter = observation; result.centerSupport.hemCenter = support
            }
        }
        _ = try result.landmarkResponse(expectedRequestID: requestID)
        return result
    }
}

private nonisolated enum OuterwearWireKeys {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func require(_ decoder: any Decoder, keys: [String]) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(keys) else {
            throw OuterwearLandmarkError.invalidResponse
        }
    }
}
