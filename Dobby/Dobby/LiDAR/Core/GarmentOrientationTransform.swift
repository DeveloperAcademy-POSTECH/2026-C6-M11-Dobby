import Foundation

/// Clockwise correction needed to stand the garment upright, after the device's
/// display orientation. This is deliberately not the garment's current angle.
nonisolated enum GarmentOrientationCorrection: Int, Codable, Sendable, CaseIterable {
    case upright = 0, clockwise90 = 90, clockwise180 = 180, clockwise270 = 270

    var imageOrientation: ImageOrientation {
        switch self {
        case .upright: .up
        case .clockwise90: .right
        case .clockwise180: .down
        case .clockwise270: .left
        }
    }
}

nonisolated enum GarmentOrientationError: Error, LocalizedError, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying {
    case modelMissing, invalidImage, invalidModelInput, inputBuffer, invalidProbabilities

    var errorDescription: String? {
        switch self {
        case .modelMissing: "옷 방향 모델이 앱에 포함되어 있지 않습니다."
        case .invalidImage: "옷 방향을 확인할 사진을 준비하지 못했습니다."
        case .invalidModelInput: "옷 방향 모델의 입력 또는 출력 형식이 예상과 다릅니다."
        case .inputBuffer: "옷 방향 모델 입력 이미지를 만들지 못했습니다."
        case .invalidProbabilities: "옷 방향 모델의 네 방향 확률을 읽지 못했습니다."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { .invalidConfiguration }
}

nonisolated struct GarmentOrientationPrediction: Codable, Sendable, Equatable {
    var correction: GarmentOrientationCorrection
    /// Original probabilities; no low-confidence cutoff is invented here.
    var probabilities: [Int: Double]
    var confidence: Double
    var margin: Double

    init(probabilities: [Int: Double]) throws {
        let angles = GarmentOrientationCorrection.allCases.map(\.rawValue)
        guard Set(probabilities.keys) == Set(angles),
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.values.reduce(0, +) - 1) <= 0.02 else {
            throw GarmentOrientationError.invalidProbabilities
        }
        let ranked = angles.sorted {
            probabilities[$0]! == probabilities[$1]! ? $0 < $1 : probabilities[$0]! > probabilities[$1]!
        }
        correction = GarmentOrientationCorrection(rawValue: ranked[0])!
        self.probabilities = probabilities
        confidence = probabilities[ranked[0]]!
        margin = confidence - probabilities[ranked[1]]!
    }
}

nonisolated enum GarmentOrientationTransform {
    /// Both rotations act clockwise on top-left normalized image coordinates.
    /// The resulting orientation is the only transform passed to pose and mask;
    /// their existing inverse mapping restores the raw sensor raster once.
    static func composed(device: ImageOrientation, correction: GarmentOrientationCorrection) -> ImageOrientation {
        let orientations: [ImageOrientation] = [.up, .right, .down, .left]
        let index = orientations.firstIndex(of: device)!
        return orientations[(index + correction.rawValue / 90) % 4]
    }
}

/// Exact orientation-classifier training preprocessing. Pose keeps its separate
/// existing 640 px letterbox contract, including its own dimension rounding.
nonisolated struct GarmentOrientationLetterbox: Sendable, Equatable {
    static let side = 224
    static let padding: UInt8 = 114
    let resizedWidth: Int
    let resizedHeight: Int
    let offsetX: Int
    let offsetY: Int

    init(size: PixelSize) throws {
        guard size.isValid else { throw GarmentOrientationError.invalidImage }
        let scale = Double(Self.side) / Double(max(size.width, size.height))
        resizedWidth = min(Self.side, max(1, Int(floor(Double(size.width) * scale + 0.5))))
        resizedHeight = min(Self.side, max(1, Int(floor(Double(size.height) * scale + 0.5))))
        offsetX = (Self.side - resizedWidth) / 2
        offsetY = (Self.side - resizedHeight) / 2
    }
}
