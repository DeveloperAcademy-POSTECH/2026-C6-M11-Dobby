import Foundation

/// A measurement and its editable physical references. No text fields, alerts,
/// decoded images, screen tasks or presentation state live in this value model.
nonisolated struct AutomaticMeasurement: Identifiable, Sendable {
    let id: UUID
    let snapshot: CaptureSnapshot
    let landmarks: GarmentLandmarkSet
    let originalResult: GarmentMeasurementResult
    let definitions: [MeasurementDefinition]
    let options: MeasurementOptions
    private(set) var result: GarmentMeasurementResult
    private var adjustedLandmarks: GarmentLandmarkSet?
    private(set) var calculationRevision = UUID()
    private var appliedCalculationRevision: UUID
    private(set) var persistenceRevision = UUID()
    private(set) var referenceByDefinitionCentimeters: [String: Double]
    var context: MeasurementTestContext {
        didSet { if context != oldValue { persistenceRevision = UUID() } }
    }
    let timings: AutomaticMeasurementTimings?

    init(output: AutomaticMeasurementOutput, context: MeasurementTestContext = .init()) {
        id = output.runID
        snapshot = output.snapshot
        landmarks = output.landmarks
        originalResult = output.result
        definitions = output.definitions
        options = output.options
        result = output.result
        referenceByDefinitionCentimeters = [:]
        self.context = context
        timings = output.timings
        appliedCalculationRevision = calculationRevision
    }

    init(record: SavedMeasurement) {
        id = record.id
        snapshot = record.snapshot
        landmarks = record.originalAutomaticLandmarks ?? record.landmarks
        originalResult = record.originalAutomaticResult ?? record.result
        adjustedLandmarks = record.originalAutomaticLandmarks == nil ? nil : record.landmarks
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
        appliedCalculationRevision = calculationRevision
    }

    mutating func setReference(_ centimeters: Double?, for definitionID: String) throws {
        guard definitions.contains(where: { $0.id == definitionID }) else {
            throw AutomaticMeasurementEditError.unknownDefinition(definitionID)
        }
        if let centimeters, !centimeters.isFinite || centimeters <= 0 {
            throw AutomaticMeasurementEditError.invalidReference(definitionID)
        }
        if referenceByDefinitionCentimeters[definitionID] != centimeters {
            referenceByDefinitionCentimeters[definitionID] = centimeters
            persistenceRevision = UUID()
        }
    }

    /// Imported results are replayed with the current engine, but cannot be
    /// replaced by another capture or by a different set of measurement items.
    @discardableResult
    mutating func apply(_ updated: GarmentMeasurementResult) -> Bool {
        guard !needsRecalculation else { return false }
        return apply(updated, for: calculationRevision)
    }

    @discardableResult
    mutating func apply(_ updated: GarmentMeasurementResult, for revision: UUID) -> Bool {
        guard revision == calculationRevision,
              updated.sessionID == snapshot.frame.sessionID,
              updated.frameID == snapshot.frame.frameID,
              updated.source == snapshot.frame.source,
              updated.values.map(\.id) == definitions.map(\.id) else { return false }
        result = updated
        appliedCalculationRevision = revision
        persistenceRevision = UUID()
        return true
    }

    func makeRecord(id: UUID = UUID(), savedAt: Date = .now) throws -> SavedMeasurement {
        guard !needsRecalculation else { throw AutomaticMeasurementEditError.resultUnavailable }
        for (definitionID, reference) in referenceByDefinitionCentimeters {
            guard definitions.contains(where: { $0.id == definitionID }) else {
                throw AutomaticMeasurementEditError.unknownDefinition(definitionID)
            }
            guard reference.isFinite, reference > 0 else {
                throw AutomaticMeasurementEditError.invalidReference(definitionID)
            }
        }
        return SavedMeasurement(id: id, savedAt: savedAt, snapshot: snapshot, landmarks: calculationLandmarks,
            definitions: definitions, result: result, referenceCentimeters: nil, options: options,
            testContext: context, referenceByDefinitionCentimeters: referenceByDefinitionCentimeters,
            originalAutomaticLandmarks: hasPointAdjustments ? landmarks : nil,
            originalAutomaticResult: hasPointAdjustments ? originalResult : nil)
    }

    var displayLandmarks: GarmentLandmarkSet {
        calculationLandmarks.replacingDerivedImagePoints(with: needsRecalculation ? nil : result)
    }

    /// Raw direct points are the drag targets. A derived midpoint or projected
    /// length annotation never replaces the actual physical source coordinate.
    var editableLandmarks: GarmentLandmarkSet {
        let current = calculationLandmarks
        var editable = current
        editable.points = current.points.filter { current.effectiveDerivedSourceIDs(for: $0.id) == nil }
        return editable
    }

    var calculationLandmarks: GarmentLandmarkSet { adjustedLandmarks ?? landmarks }
    var hasPointAdjustments: Bool { !editedPointIDs.isEmpty }
    var needsRecalculation: Bool { appliedCalculationRevision != calculationRevision }

    var editedPointIDs: Set<String> {
        guard let adjustedLandmarks else { return [] }
        return Set(adjustedLandmarks.points.filter { point in
            guard point.origin == .manual,
                  adjustedLandmarks.effectiveDerivedSourceIDs(for: point.id) == nil else { return false }
            let original = landmarks.points.first { $0.id == point.id }
            return original?.origin != .manual || original?.point != point.point
        }.map(\.id))
    }

    /// Coordinates already refer to the complete original sensor image. The UI
    /// performs orientation conversion exactly once before calling this method.
    @discardableResult
    mutating func placePoint(originalPoint: ImagePoint, id: String) -> Bool {
        var updated = calculationLandmarks
        let ids = updated.points.map(\.id)
        guard originalPoint.isValid, updated.points.count <= 200,
              Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }),
              updated.sessionID == snapshot.frame.sessionID,
              updated.frameID == snapshot.frame.frameID,
              let index = updated.points.firstIndex(where: { $0.id == id }),
              updated.effectiveDerivedSourceIDs(for: id) == nil else { return false }
        if updated.points[index].origin == .manual, updated.points[index].point == originalPoint { return false }
        updated.points[index].point = originalPoint
        updated.points[index].isVisible = true
        updated.points[index].confidence = nil
        updated.points[index].origin = .manual
        adjustedLandmarks = updated
        adjustedLandmarks = updated.refreshingDerivations(affectedBy: editedPointIDs)
        invalidateCalculation()
        return true
    }

    mutating func resetPointAdjustments() {
        guard adjustedLandmarks != nil else { return }
        adjustedLandmarks = nil
        invalidateCalculation()
    }

    private mutating func invalidateCalculation() {
        calculationRevision = UUID()
        persistenceRevision = UUID()
    }

    func manualMeasurement(for definitionID: String) -> ManualMeasurement? {
        guard let definition = definitions.first(where: { $0.id == definitionID }),
              definition.landmarkIDs.count == 2 else { return nil }
        // Retain model provenance until both endpoints are explicitly confirmed.
        let current = calculationLandmarks
        var selected = current
        selected.points = definition.landmarkIDs.flatMap { id -> [GarmentLandmark] in
            let matches = current.points.filter { $0.id == id }
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
            for sourceID in current.effectiveDerivedSourceIDs(for: id) ?? [] where required.insert(sourceID).inserted {
                pending.append(sourceID)
            }
        }
        selected.points += current.points.filter {
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
    case resultUnavailable
}
