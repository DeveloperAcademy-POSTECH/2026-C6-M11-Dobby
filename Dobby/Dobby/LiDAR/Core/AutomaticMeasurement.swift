import Foundation

/// A measurement and its editable physical references. No text fields, alerts,
/// decoded images, screen tasks or presentation state live in this value model.
nonisolated struct AutomaticMeasurement: Identifiable, Sendable {
    let id: UUID
    let snapshot: CaptureSnapshot
    let landmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
    let options: MeasurementOptions
    private(set) var result: GarmentMeasurementResult
    private(set) var referenceByDefinitionCentimeters: [String: Double]
    var context: MeasurementTestContext
    let timings: AutomaticMeasurementTimings?

    init(output: AutomaticMeasurementOutput, context: MeasurementTestContext = .init()) {
        id = output.runID
        snapshot = output.snapshot
        landmarks = output.landmarks
        definitions = output.definitions
        options = output.options
        result = output.result
        referenceByDefinitionCentimeters = [:]
        self.context = context
        timings = output.timings
    }

    init(record: SavedMeasurement) {
        id = record.id
        snapshot = record.snapshot
        landmarks = record.landmarks
        definitions = record.definitions
        options = record.options
        result = record.result
        referenceByDefinitionCentimeters = record.referenceByDefinitionCentimeters ?? [:]
        if definitions.count == 1, let definition = definitions.first,
           referenceByDefinitionCentimeters[definition.id] == nil,
           let reference = record.referenceCentimeters {
            referenceByDefinitionCentimeters[definition.id] = reference
        }
        context = record.testContext ?? .init()
        timings = nil
    }

    mutating func setReference(_ centimeters: Double?, for definitionID: String) throws {
        guard definitions.contains(where: { $0.id == definitionID }) else {
            throw AutomaticMeasurementEditError.unknownDefinition(definitionID)
        }
        if let centimeters, !centimeters.isFinite || centimeters <= 0 {
            throw AutomaticMeasurementEditError.invalidReference(definitionID)
        }
        referenceByDefinitionCentimeters[definitionID] = centimeters
    }

    /// Imported results are replayed with the current engine, but cannot be
    /// replaced by another capture or by a different set of measurement items.
    @discardableResult
    mutating func apply(_ updated: GarmentMeasurementResult) -> Bool {
        guard updated.sessionID == snapshot.frame.sessionID,
              updated.frameID == snapshot.frame.frameID,
              updated.source == snapshot.frame.source,
              updated.values.map(\.id) == definitions.map(\.id) else { return false }
        result = updated
        return true
    }

    func makeRecord(id: UUID = UUID(), savedAt: Date = .now) throws -> SavedMeasurement {
        for (definitionID, reference) in referenceByDefinitionCentimeters {
            guard definitions.contains(where: { $0.id == definitionID }) else {
                throw AutomaticMeasurementEditError.unknownDefinition(definitionID)
            }
            guard reference.isFinite, reference > 0 else {
                throw AutomaticMeasurementEditError.invalidReference(definitionID)
            }
        }
        return SavedMeasurement(id: id, savedAt: savedAt, snapshot: snapshot, landmarks: landmarks,
            definitions: definitions, result: result, referenceCentimeters: nil, options: options,
            testContext: context, referenceByDefinitionCentimeters: referenceByDefinitionCentimeters)
    }

    var displayLandmarks: GarmentLandmarkSet {
        landmarks.replacingDerivedImagePoints(with: result)
    }

    func manualMeasurement(for definitionID: String) -> ManualMeasurement? {
        guard let definition = definitions.first(where: { $0.id == definitionID }),
              definition.landmarkIDs.count == 2 else { return nil }
        // Retain model provenance until both endpoints are explicitly confirmed.
        var selected = landmarks
        selected.points = definition.landmarkIDs.flatMap { id -> [GarmentLandmark] in
            let matches = landmarks.points.filter { $0.id == id }
            // Merely opening the editor must preserve duplicate-ID failures.
            // Only explicit manual confirmation may replace model endpoints.
            return matches.isEmpty
                ? [.init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false)]
                : matches
        }
        // Keep source points while the A/B editor still represents model output.
        // Dropping waist endpoints would make its derived midpoint unresolvable.
        let supportIDs = definition.projection?.referenceAxisLandmarkIDs ?? []
        var required = Set(definition.landmarkIDs + supportIDs)
        var pending = definition.landmarkIDs + supportIDs
        var cursor = 0
        while cursor < pending.count && required.count <= 128 {
            let id = pending[cursor]
            cursor += 1
            for sourceID in landmarks.effectiveDerivedSourceIDs(for: id) ?? [] where required.insert(sourceID).inserted {
                pending.append(sourceID)
            }
        }
        selected.points += landmarks.points.filter {
            required.contains($0.id) && !definition.landmarkIDs.contains($0.id)
        }
        return ManualMeasurement(snapshot: snapshot, landmarks: selected, definition: definition,
            referenceCentimeters: referenceByDefinitionCentimeters[definitionID],
            options: options, testContext: context)
    }
}

nonisolated enum AutomaticMeasurementEditError: Error, Equatable {
    case unknownDefinition(String)
    case invalidReference(String)
}
