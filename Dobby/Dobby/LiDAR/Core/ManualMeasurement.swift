import Foundation

/// A manual measurement and its editing rules. Screen state, images, asynchronous
/// tasks, and persistence services belong to the View or their dedicated services.
nonisolated struct ManualMeasurement: Identifiable, Sendable {
    let id: UUID
    let snapshot: CaptureSnapshot
    let expectedMeters: Double?
    private(set) var landmarks: GarmentLandmarkSet
    private(set) var definition: MeasurementDefinition
    private(set) var result: GarmentMeasurementResult?
    private(set) var options: MeasurementOptions
    private(set) var referenceCentimeters: Double?
    var testContext: MeasurementTestContext {
        didSet {
            if testContext != oldValue { persistenceRevision = UUID() }
        }
    }

    /// Geometry changes require a new calculation. Metadata edits only invalidate
    /// a pending save's presentation, without unnecessarily recalculating depth.
    private(set) var calculationRevision = UUID()
    private(set) var persistenceRevision = UUID()

    init(snapshot: CaptureSnapshot, landmarks: GarmentLandmarkSet? = nil,
         definition: MeasurementDefinition = .testDistance, expectedMeters: Double? = nil,
         referenceCentimeters: Double? = nil, options: MeasurementOptions = .init(),
         testContext: MeasurementTestContext? = nil) {
        id = UUID()
        self.snapshot = snapshot
        self.definition = definition
        self.expectedMeters = expectedMeters
        self.options = options
        self.testContext = testContext ?? .init()
        self.landmarks = landmarks ?? .init(
            sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .manual, modelVersion: nil,
            points: Self.unconfirmedPoints(for: definition), mask: nil
        )
        let reference = referenceCentimeters ?? expectedMeters.map { $0 * 100 }
        self.referenceCentimeters = reference.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var availableDefinitions: [MeasurementDefinition] {
        let definitions = testContext.category.definitions
        // Imported custom definitions keep their original meaning and identifiers.
        return definitions.contains(where: { $0.id == definition.id }) ? definitions : [definition] + definitions
    }

    var useLocalPlane: Bool { options.useLocalPlane }

    /// Only the definition endpoints are editable; supporting source points stay
    /// in the model for 3D derivation until the user starts manual confirmation.
    var displayLandmarks: GarmentLandmarkSet {
        var displayed = landmarks.replacingDerivedImagePoints(with: result)
        displayed.points = definition.landmarkIDs.compactMap { id in displayed.points.first { $0.id == id } }
        // A projected endpoint belongs to this measurement, not to the pose
        // model's original hem landmark. Keep the archived prediction intact.
        if definition.projection != nil,
           let result, result.sessionID == snapshot.frame.sessionID,
           result.frameID == snapshot.frame.frameID,
           let value = result.values.first(where: { $0.id == definition.id }) {
            for index in displayed.points.indices {
                if let resolved = value.points.first(where: {
                    $0.id == displayed.points[index].id && $0.quality.method == .axisProjection
                }), resolved.imagePoint.isValid {
                    displayed.points[index].point = resolved.imagePoint
                }
            }
        }
        return displayed
    }

    mutating func selectCategory(_ category: GarmentCategory) {
        testContext.category = category
        if !category.definitions.contains(where: { $0.id == definition.id }), let first = category.definitions.first {
            selectDefinition(first)
        }
    }

    mutating func selectDefinition(_ newValue: MeasurementDefinition) {
        if definition.id != newValue.id { referenceCentimeters = nil }
        definition = newValue
        landmarks.origin = .manual
        landmarks.modelVersion = nil
        landmarks.points = Self.unconfirmedPoints(for: newValue)
        invalidateCalculation()
    }

    @discardableResult
    mutating func placePoint(displayPoint: ImagePoint, index: Int) -> Bool {
        guard definition.landmarkIDs.indices.contains(index), displayPoint.x.isFinite, displayPoint.y.isFinite else { return false }
        let original = ImageCoordinateTransform.displayToOriginal(displayPoint, orientation: snapshot.frame.orientation)
        let point = ImagePoint(x: min(0.999999, max(0, original.x)), y: min(0.999999, max(0, original.y)))
        let editable = displayLandmarks
        guard editable.points.count == definition.landmarkIDs.count else { return false }
        // Once manual editing begins the two endpoints must be confirmed by hand;
        // derived helper points must not survive as hidden sampling dependencies.
        var updated = editable
        guard updated.placeManualLandmark(at: index, point: point) else { return false }
        if definition.projection != nil {
            // This editor confirms two endpoints, not the model's horizontal
            // reference axis. Record a different measurement instead of silently
            // preserving a rule whose supporting points were discarded.
            definition.projection = nil
            definition.id += ".manualStraight"
            definition.title += " · 수동 직선"
            referenceCentimeters = nil
        }
        landmarks = updated
        invalidateCalculation()
        return true
    }

    mutating func setUseLocalPlane(_ enabled: Bool) {
        guard options.useLocalPlane != enabled else { return }
        options.useLocalPlane = enabled
        invalidateCalculation()
    }

    /// Invalid typed references are rejected rather than serialized into an archive.
    @discardableResult
    mutating func setReferenceCentimeters(_ value: Double?) -> Bool {
        if let value, !value.isFinite || value <= 0 { return false }
        if referenceCentimeters != value {
            referenceCentimeters = value
            persistenceRevision = UUID()
        }
        return true
    }

    /// A result calculated for an older edit, a different frame, or another
    /// definition must never become the visible or saved current measurement.
    @discardableResult
    mutating func apply(_ output: GarmentMeasurementResult, for revision: UUID) -> Bool {
        guard revision == calculationRevision,
              options.effectiveCalculationMode != .garmentPlane
                || output.algorithmVersion == MeasurementCalculator.algorithmVersion(for: options),
              output.sessionID == snapshot.frame.sessionID,
              output.frameID == snapshot.frame.frameID,
              output.source == snapshot.frame.source,
              output.values.count == 1, output.values.first?.id == definition.id else { return false }
        result = output
        persistenceRevision = UUID()
        return true
    }

    func makeRecord(id: UUID = UUID(), savedAt: Date = .now) throws -> SavedMeasurement {
        guard let result else { throw RecordError.resultUnavailable }
        return SavedMeasurement(id: id, savedAt: savedAt, snapshot: snapshot,
            landmarks: landmarks, definitions: [definition], result: result,
            referenceCentimeters: referenceCentimeters, options: options, testContext: testContext)
    }

    enum RecordError: Error, Equatable {
        case resultUnavailable
    }

    private mutating func invalidateCalculation() {
        result = nil
        calculationRevision = UUID()
        persistenceRevision = UUID()
    }

    private static func unconfirmedPoints(for definition: MeasurementDefinition) -> [GarmentLandmark] {
        definition.landmarkIDs.enumerated().map { index, id in
            .init(id: id, point: .init(x: index == 0 ? 0.3 : 0.7, y: 0.5), confidence: nil, isVisible: false)
        }
    }
}
