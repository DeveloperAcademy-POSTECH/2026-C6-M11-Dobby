import Foundation

nonisolated enum TopLandmarkSchemaError: LocalizedError, Equatable, Sendable {
    case invalidSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidSchema(let reason): "상의 측정점 정의를 읽을 수 없습니다. \(reason)"
        }
    }
}

/// The top model shares YOLO pose geometry with the bottom model, but its drawable
/// skeleton is not a measurement graph. Keep the six physical definitions explicit.
nonisolated struct TopLandmarkSchema: Sendable {
    static let expectedKeypoints = [
        "neck_left", "neck_right", "shoulder_left", "shoulder_right",
        "armpit_left", "armpit_right", "sleeve_end_left", "sleeve_end_right",
        "hem_left", "hem_center", "hem_right"
    ]

    let decoderSchema: BottomLandmarkSchema
    var name: String { decoderSchema.name }
    var keypoints: [String] { decoderSchema.keypoints }
    var labels: [String: [String]] { decoderSchema.labels }
    var derived: [String: [String]] { decoderSchema.derived }
    var skeleton: [[String]] { decoderSchema.skeleton }
    var derivedOrder: [String] { decoderSchema.derivedOrder }

    init(jsonData: Data) throws {
        let schema: BottomLandmarkSchema
        do {
            schema = try BottomLandmarkSchema(jsonData: jsonData)
        } catch BottomLandmarkError.invalidSchema(let reason) {
            throw TopLandmarkSchemaError.invalidSchema(reason)
        }
        guard schema.name == "top", schema.keypoints == Self.expectedKeypoints,
              schema.derived["neck_center"] == ["neck_left", "neck_right"] else {
            throw TopLandmarkSchemaError.invalidSchema("11개 측정점의 순서와 목 중앙의 파생 정의가 상의 모델과 일치해야 합니다.")
        }
        decoderSchema = schema
    }

    static func decode(_ jsonData: Data) throws -> Self { try .init(jsonData: jsonData) }

    var measurementDefinitions: [MeasurementDefinition] { Self.canonicalMeasurementDefinitions }

    static let canonicalMeasurementDefinitions: [MeasurementDefinition] = [
            .init(id: "top.shoulderWidth", title: "어깨너비", landmarkIDs: ["shoulder_left", "shoulder_right"]),
            .init(id: "top.chestWidth", title: "가슴 단면", landmarkIDs: ["armpit_left", "armpit_right"]),
            .init(id: "top.hemWidth", title: "밑단 단면", landmarkIDs: ["hem_left", "hem_right"]),
            .init(id: "top.sleeveLengthLeft", title: "왼쪽 소매길이(직선)", landmarkIDs: ["shoulder_left", "sleeve_end_left"]),
            .init(id: "top.sleeveLengthRight", title: "오른쪽 소매길이(직선)", landmarkIDs: ["shoulder_right", "sleeve_end_right"]),
            .init(id: "top.totalLength", title: "총장(목선에 수직)", landmarkIDs: ["neck_center", "hem_center"],
                  projection: .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"]))
        ]
}
