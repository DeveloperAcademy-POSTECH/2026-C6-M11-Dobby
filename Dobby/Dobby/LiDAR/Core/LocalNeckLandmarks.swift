import Foundation

/// Pilot trained on two image-side neck points. Scores are not calibrated
/// visibility probabilities; silhouette checks still decide calculation use.
nonisolated enum LocalNeckLandmarks {
    static let resourceName = "NeckSidePilot"
    static let modelVersion = "neck-side-resnet18-pilot-v1-epoch44"
    static let inputWidth = 256
    static let inputHeight = 448
    static let heatmapWidth = 64
    static let heatmapHeight = 112
    static let ids = ["neck_left", "neck_right"]

    static func decode(_ values: [Float], width: Int = heatmapWidth,
                       height: Int = heatmapHeight) throws -> [String: ImagePoint] {
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              values.count == 2 * width * height, values.allSatisfy(\.isFinite) else {
            throw LocalNeckLandmarkError.invalidOutput
        }
        var result: [String: ImagePoint] = [:]
        for channel in 0..<2 {
            let offset = channel * width * height
            var peak = 0
            for index in 1..<(width * height) where values[offset + index] > values[offset + peak] { peak = index }
            let px = peak % width, py = peak / width, maximum = Double(values[offset + peak])
            var sum = 0.0, x = 0.0, y = 0.0
            for row in max(0, py - 2)...min(height - 1, py + 2) {
                for col in max(0, px - 2)...min(width - 1, px + 2) {
                    let weight = exp(Double(values[offset + row * width + col]) - maximum)
                    sum += weight; x += (Double(col) + 0.5) * weight; y += (Double(row) + 0.5) * weight
                }
            }
            let point = ImagePoint(x: x / sum / Double(width), y: y / sum / Double(height))
            guard point.isValid else { throw LocalNeckLandmarkError.invalidOutput }
            result[ids[channel]] = point
        }
        guard result[ids[0]]!.x < result[ids[1]]!.x else { throw LocalNeckLandmarkError.invalidOutput }
        return result
    }
}

nonisolated enum LocalNeckLandmarkError: Error, Sendable {
    case missingModel, incompatibleModel, invalidImage, invalidOutput
}

nonisolated struct LocalNeckLandmarkDiagnostics: Codable, Sendable {
    var modelVersion: String = LocalNeckLandmarks.modelVersion
    /// Input rectangle and predictions use full, verified upright coordinates.
    var inputRect: NormalizedRect
    var predictedPoints: [String: ImagePoint] = [:]
    var adoptedLandmarkIDs: [String] = []
    var failure: String? = nil
}
