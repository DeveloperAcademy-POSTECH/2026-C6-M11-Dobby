import Foundation

/// One dispatch contract for initial results, editing, archive replay and reports.
/// Point provenance never chooses the engine: manual overrides of an automatic
/// garment measurement keep its original calculation mode.
nonisolated enum MeasurementCalculator {
    static func measure(frame: MeasurementFrame, landmarks: GarmentLandmarkSet,
                        definitions: [MeasurementDefinition], options: MeasurementOptions) -> GarmentMeasurementResult {
        switch options.effectiveCalculationMode {
        case .legacyLocal:
            LiDARMeasurementEngine(options: options).measure(frame: frame, landmarks: landmarks, definitions: definitions)
        case .garmentPlane:
            GarmentPlaneMeasurementEngine(options: options).measure(frame: frame, landmarks: landmarks, definitions: definitions)
        }
    }

    static func algorithmVersion(for options: MeasurementOptions) -> String {
        switch options.effectiveCalculationMode {
        case .legacyLocal: LiDARMeasurementEngine.algorithmVersion
        case .garmentPlane: GarmentPlaneMeasurementEngine.algorithmVersion
        }
    }
}
