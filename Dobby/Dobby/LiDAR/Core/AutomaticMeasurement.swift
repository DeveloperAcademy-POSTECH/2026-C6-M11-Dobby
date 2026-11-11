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
    mutating func requestRecalculation() {
        calculationRevision = UUID()
        persistenceRevision = UUID()
    }

    @discardableResult
    mutating func apply(_ updated: GarmentMeasurementResult) -> Bool {
        guard !needsRecalculation else { return false }
        return apply(updated, for: calculationRevision)
    }

    @discardableResult
    mutating func apply(_ updated: GarmentMeasurementResult, for revision: UUID) -> Bool {
        guard revision == calculationRevision,
              options.effectiveCalculationMode != .garmentPlane
                || updated.algorithmVersion == MeasurementCalculator.algorithmVersion(for: options, landmarks: calculationLandmarks),
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

    var visibleValues: [MeasurementValue] {
        GarmentMeasurementPresentation.overlayMeasurements(result.values, id: { $0.id }).map { value in
            var presented = value
            presented.title = GarmentMeasurementPresentation.overlayTitle(for: value.id, fallback: value.title)
            return presented
        }
    }

    var visibleDefinitions: [MeasurementDefinition] {
        let ids = Set(visibleValues.map(\.id))
        return GarmentMeasurementPresentation.overlayMeasurements(definitions, id: { $0.id })
            .filter { ids.contains($0.id) }.map { definition in
            var presented = definition
            presented.title = GarmentMeasurementPresentation.overlayTitle(for: definition.id, fallback: definition.title)
            return presented
        }
    }

    /// Include physical contributors to derived/projection endpoints, but omit
    /// handles used exclusively by the hidden opposite-side measurement.
    var visibleEditableLandmarks: GarmentLandmarkSet {
        let current = calculationLandmarks
        var pending = visibleDefinitions.flatMap {
            $0.landmarkIDs + ($0.projection?.referenceAxisLandmarkIDs ?? [])
        }
        var required = Set(pending)
        var cursor = 0
        while cursor < pending.count && required.count <= 200 {
            let id = pending[cursor]
            cursor += 1
            for sourceID in current.calculationSourceIDs(for: id) ?? [] where required.insert(sourceID).inserted {
                pending.append(sourceID)
            }
        }
        var visible = editableLandmarks
        visible.points = visible.points.filter { required.contains($0.id) }
        if let startID = editableTotalLengthStartID, required.contains(startID),
           var center = current.points.first(where: { $0.id == startID }) {
            // Start at the depth-backed midpoint when available; keep the raw
            // midpoint editable even when the automatic measurement failed.
            if let displayed = displayLandmarks.points.first(where: {
                $0.id == startID && $0.isVisible && $0.point.isValid
            }) {
                center.point = displayed.point
                center.isVisible = true
            } else if center.contourRule != nil {
                // A contour placeholder uses the hem as a non-measuring hint.
                // It must never appear there as a successfully found top point.
                center.isVisible = false
            } else if GarmentLandmarkModelContract.isLunaOuterwear(version: current.modelVersion, kind: .top) {
                // A null remote seam is an unavailable observation, not the
                // valid-position hint used for manual two-point placement.
                center.isVisible = center.isVisible && center.point.isValid
            } else {
                center.isVisible = center.point.isValid
            }
            visible.points.removeAll { ["neck_left", "neck_right", "neck_center", "top_length_start", "front_length_start"].contains($0.id) }
            visible.points.append(center)
        }
        return visible
    }

    var photoEditingPresentation: GarmentEditingPointPresentation {
        var displayed = visibleEditableLandmarks
        if canCorrectTotalLength, let definition = lengthDefinition {
            for id in definition.landmarkIDs where !displayed.points.contains(where: { $0.id == id }) {
                displayed.points.append(.init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false))
            }
        }
        return .make(displayed: displayed, source: calculationLandmarks, snapshot: snapshot)
    }

    /// Direct points retain their original coordinates. The right thigh contour
    /// becomes a drag target only at its successfully resolved image position;
    /// its invisible crotch hint must never masquerade as a found endpoint.
    var editableLandmarks: GarmentLandmarkSet {
        let current = calculationLandmarks
        var editable = current.replacingDerivedImagePoints(with: needsRecalculation ? nil : result)
        editable.points = editable.points.filter {
            current.effectiveDerivedSourceIDs(for: $0.id) == nil
                && ($0.contourRule == nil || ($0.id == editableThighPointID
                    && $0.contourRule == .waistParallelRightThighMaskV1)
                    || (usesSideNeckTotalLength && $0.id == TopSideNeckLength.hemID
                        && $0.contourRule == .leftNeckVerticalHemMaskV1))
        }
        return editable
    }

    private var allowsNeckCenterEditing: Bool {
        definitions.contains { $0.id == "top.totalLength" && $0.landmarkIDs.contains("neck_center") }
    }

    private var editableTotalLengthStartID: String? {
        canCorrectTotalLength ? lengthDefinition?.landmarkIDs.first : nil
    }

    private var editableThighPointID: String? {
        let matches = definitions.filter { $0.id == "bottom.thighWidthRight" }
        guard matches.count == 1, matches[0].landmarkIDs == ["crotch", "thigh_right"],
              matches[0].projection == nil else { return nil }
        return "thigh_right"
    }

    var calculationLandmarks: GarmentLandmarkSet { adjustedLandmarks ?? landmarks }
    var hasPointAdjustments: Bool { !editedPointIDs.isEmpty }
    var needsRecalculation: Bool { appliedCalculationRevision != calculationRevision }

    var editedPointIDs: Set<String> {
        guard let adjustedLandmarks else { return [] }
        return Set(adjustedLandmarks.points.filter { point in
            guard point.origin == .manual,
                  adjustedLandmarks.effectiveDerivedSourceIDs(for: point.id) == nil,
                  point.contourRule == nil else { return false }
            let original = landmarks.points.first { $0.id == point.id }
            return original?.origin != .manual || original?.point != point.point
        }.map(\.id))
    }

    /// Only the current straight total length can accept two manually confirmed
    /// endpoints. Older projected records still require their original axis.
    var canCorrectTotalLength: Bool {
        let matches = definitions.filter { ["top.totalLength", "top.frontLength"].contains($0.id) }
        return matches.count == 1
            && (matches[0].id == "top.frontLength" ? matches[0].landmarkIDs == ["front_length_start", "hem_center"]
                : [["neck_center", "hem_center"], ["top_length_start", "hem_center"]].contains(matches[0].landmarkIDs)
                    || (usesSideNeckTotalLength && matches[0].landmarkIDs == ["neck_left", TopSideNeckLength.hemID]))
            && matches[0].projection == nil
    }

    var usesSideNeckTotalLength: Bool {
        GarmentLandmarkModelContract.usesSideNeckLength(calculationLandmarks)
    }

    var lengthDefinition: MeasurementDefinition? {
        let matches = definitions.filter { ["top.totalLength", "top.frontLength"].contains($0.id) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Apply both explicitly placed endpoints together to this frozen capture.
    /// Missing total-length points can also be restored by explicit dragging.
    /// Displaying a provisional handle never confirms an observation.
    /// The manual result is not copied: all measurements recalculate from the
    /// original depth, mask, options and unaffected model observations.
    @discardableResult
    mutating func applyTotalLengthCorrection(from manual: ManualMeasurement) -> Bool {
        guard canCorrectTotalLength,
              let definition = lengthDefinition else { return false }
        let ids = definition.landmarkIDs
        let frame = snapshot.frame
        let correctedFrame = manual.snapshot.frame
        guard canCorrectTotalLength,
              manual.definition.id == definition.id,
              manual.definition.landmarkIDs == ids, manual.definition.projection == nil,
              correctedFrame.sessionID == frame.sessionID, correctedFrame.frameID == frame.frameID,
              correctedFrame.source == frame.source, correctedFrame.orientation == frame.orientation,
              correctedFrame.imageSize == frame.imageSize, correctedFrame.intrinsics == frame.intrinsics,
              manual.landmarks.sessionID == frame.sessionID, manual.landmarks.frameID == frame.frameID,
              manual.landmarks.origin == .manual,
              manual.landmarks.points.count == ids.count,
              Set(manual.landmarks.points.map(\.id)) == Set(ids),
              manual.landmarks.points.allSatisfy({
                  $0.origin == .manual && $0.isVisible && $0.point.isValid
                      && $0.derivedFrom == nil && $0.contourRule == nil && $0.confidence == nil
              }) else { return false }

        var updated = calculationLandmarks
        let existingIDs = updated.points.map(\.id)
        let missingCount = ids.filter { !existingIDs.contains($0) }.count
        guard updated.sessionID == frame.sessionID, updated.frameID == frame.frameID,
              updated.points.count + missingCount <= 200,
              existingIDs.allSatisfy({ !$0.isEmpty }), Set(existingIDs).count == existingIDs.count else {
            return false
        }
        var changed = false
        for id in ids {
            guard let corrected = manual.landmarks.points.first(where: { $0.id == id }) else { return false }
            if let index = updated.points.firstIndex(where: { $0.id == id }) {
                let previous = updated.points[index]
                changed = changed || previous.point != corrected.point || previous.origin != .manual
                    || !previous.isVisible || previous.derivedFrom != nil || previous.contourRule != nil || previous.confidence != nil
                updated.points[index] = corrected
            } else {
                updated.points.append(corrected)
                changed = true
            }
        }
        guard changed else { return true }
        adjustedLandmarks = updated.refreshingDerivations(affectedBy: Set(ids))
        invalidateCalculation()
        return true
    }

    /// Coordinates already refer to the complete original sensor image. The UI
    /// performs orientation conversion exactly once before calling this method.
    @discardableResult
    mutating func placePoint(originalPoint: ImagePoint, id: String) -> Bool {
        var updated = calculationLandmarks
        let ids = updated.points.map(\.id)
        if !ids.contains(id), canCorrectTotalLength, lengthDefinition?.landmarkIDs.contains(id) == true,
           updated.points.count < 200 {
            updated.points.append(.init(id: id, point: originalPoint, confidence: nil, isVisible: false))
        }
        guard originalPoint.isValid, updated.points.count <= 200,
              Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }),
              updated.sessionID == snapshot.frame.sessionID,
              updated.frameID == snapshot.frame.frameID,
              let index = updated.points.firstIndex(where: { $0.id == id }),
              (updated.effectiveDerivedSourceIDs(for: id) == nil && updated.points[index].contourRule == nil)
                || id == editableTotalLengthStartID
                || (usesSideNeckTotalLength && id == TopSideNeckLength.hemID
                    && updated.points[index].contourRule == .leftNeckVerticalHemMaskV1)
                || (id == editableThighPointID && updated.points[index].contourRule == .waistParallelRightThighMaskV1)
              else { return false }
        if updated.points[index].origin == .manual, updated.points[index].point == originalPoint { return false }
        // An explicitly placed contour endpoint becomes a direct manual ray on
        // the same garment plane. Later parent edits must not move it again.
        if id == editableTotalLengthStartID || id == editableThighPointID
            || (usesSideNeckTotalLength && id == TopSideNeckLength.hemID) {
            updated.points[index].derivedFrom = nil
            updated.points[index].contourRule = nil
        }
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
            for sourceID in current.calculationSourceIDs(for: id) ?? [] where required.insert(sourceID).inserted {
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
