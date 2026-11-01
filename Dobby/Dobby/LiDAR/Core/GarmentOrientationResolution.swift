import Foundation

nonisolated struct GarmentOrientationAttempt: Codable, Sendable, Equatable {
    /// Complete orientation applied to the same source before this prediction.
    var orientation: ImageOrientation
    var prediction: GarmentOrientationPrediction
}

nonisolated struct GarmentOrientationResolution: Codable, Sendable, Equatable {
    var orientation: ImageOrientation
    var attempts: [GarmentOrientationAttempt]
}

/// Capture and the photo experiment verify that the correction actually yields
/// an upright prediction. This is bounded and independent of clothing labels:
/// never search rotations for an outerwear score or overwrite classifier output.
nonisolated enum GarmentOrientationResolutionPolicy {
    static func resolve(startingAt initial: ImageOrientation = .up,
                        predict: (ImageOrientation) throws -> GarmentOrientationPrediction) throws
        -> GarmentOrientationResolution {
        var orientation = initial
        var attempts: [GarmentOrientationAttempt] = []
        for _ in 0..<3 {
            try Task.checkCancellation()
            let prediction = try predict(orientation)
            attempts.append(.init(orientation: orientation, prediction: prediction))
            if prediction.correction == .upright {
                return .init(orientation: orientation, attempts: attempts)
            }
            let next = GarmentOrientationTransform.composed(device: orientation, correction: prediction.correction)
            // Returning to a visited orientation means contradictory model
            // predictions. Do not choose whichever category happens to pass.
            guard !attempts.contains(where: { $0.orientation == next }) else {
                throw GarmentOrientationResolutionError(attempts: attempts)
            }
            orientation = next
        }
        throw GarmentOrientationResolutionError(attempts: attempts)
    }
}

nonisolated struct GarmentOrientationResolutionError: Error, LocalizedError, Sendable,
    AutomaticMeasurementFailureClassifying {
    let attempts: [GarmentOrientationAttempt]

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { .providerFailure }

    var errorDescription: String? {
        "옷 방향 모델의 결과가 일치하지 않아 옷 종류를 확정하지 않았어요. 측정점 분석은 시작하지 않았어요."
    }
}
