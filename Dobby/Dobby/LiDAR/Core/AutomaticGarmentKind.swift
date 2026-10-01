import Foundation

/// A semantic pose contract selected from the captured image. The two supplied
/// models are independent detectors; their scores are not classifier probabilities.
nonisolated enum AutomaticGarmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, bottoms

    var id: String { rawValue }
    var title: String { self == .top ? "상의" : "하의" }
    var category: GarmentCategory { self == .top ? .top : .bottoms }
    var supportDescription: String { self == .top ? "긴팔·반팔 상의" : "바지·반바지" }
    var modelResourceName: String { self == .top ? "TopLandmarks" : "BottomLandmarks" }
    var schemaResourceName: String { self == .top ? "schema_top" : "schema_bottom7" }
    var modelVersion: String { self == .top ? "top11-ec1e6b054d59" : "bottom7-976144d4d652" }
}
