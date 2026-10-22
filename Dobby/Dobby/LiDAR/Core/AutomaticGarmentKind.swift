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
    var schemaResourceName: String { self == .top ? "schema_top" : "schema_bottom8" }
    static let legacyTopModelVersion = "top11-ec1e6b054d59"
    static let legacyBottomModelVersion = "bottom7-976144d4d652"
    static let legacyBottom8ModelVersion = "bottom8-5f65f2483f98"
    static let orientationModelVersion = "orientation4-2c9dc14fbd2d"
    var modelVersion: String { self == .top ? "top11-sleeveouter-62f220dae7f3" : "bottom8-jogger-4a576205b409" }

    /// Saved model identity is part of its measurement contract. Only these
    /// exact previous versions are accepted by the product import adapter.
    var legacyModelVersion: String { self == .top ? Self.legacyTopModelVersion : Self.legacyBottomModelVersion }
}
