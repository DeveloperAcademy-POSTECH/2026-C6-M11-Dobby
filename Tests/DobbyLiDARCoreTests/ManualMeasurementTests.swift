import XCTest
@testable import DobbyLiDARCore

final class ManualMeasurementTests: XCTestCase {
    private func model(orientation: ImageOrientation = .up) -> ManualMeasurement {
        let scene = SyntheticFixtures.scene()
        var snapshot = CaptureSnapshot(frame: scene.frame, imageJPEG: Data([1, 2, 3]))
        snapshot.frame.orientation = orientation
        return ManualMeasurement(snapshot: snapshot, landmarks: scene.landmarks, expectedMeters: scene.expectedMeters)
    }

    private func output(for model: ManualMeasurement) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: model.options).measure(frame: model.snapshot.frame,
            landmarks: model.landmarks, definitions: [model.definition])
    }

    func testPointEditRejectsLateCalculationAndCannotSavePreviousResult() throws {
        var model = model()
        let oldRevision = model.calculationRevision
        let oldOutput = output(for: model)
        XCTAssertTrue(model.apply(oldOutput, for: oldRevision))
        XCTAssertNoThrow(try model.makeRecord())

        XCTAssertTrue(model.placePoint(displayPoint: .init(x: 0.35, y: 0.5), index: 0))
        XCTAssertNil(model.result)
        XCTAssertFalse(model.apply(oldOutput, for: oldRevision))
        XCTAssertThrowsError(try model.makeRecord()) { XCTAssertEqual($0 as? ManualMeasurement.RecordError, .resultUnavailable) }

        XCTAssertTrue(model.apply(output(for: model), for: model.calculationRevision))
        XCTAssertEqual(try model.makeRecord().landmarks.points[0].point, .init(x: 0.35, y: 0.5))
    }

    func testMetadataEditsInvalidateSaveRevisionWithoutDiscardingCalculatedGeometry() throws {
        var model = model()
        let calculation = model.calculationRevision
        XCTAssertTrue(model.apply(output(for: model), for: calculation))
        let savedRevision = model.persistenceRevision
        model.testContext.specimenName = "검정 셔츠 01"
        XCTAssertNotEqual(savedRevision, model.persistenceRevision)
        XCTAssertEqual(calculation, model.calculationRevision)
        XCTAssertNotNil(model.result)
        let metadataRevision = model.persistenceRevision
        XCTAssertTrue(model.setReferenceCentimeters(51.25))
        XCTAssertNotEqual(metadataRevision, model.persistenceRevision)
        XCTAssertEqual(calculation, model.calculationRevision)
        let record = try model.makeRecord()
        XCTAssertEqual(record.referenceCentimeters, 51.25)
        XCTAssertEqual(record.testContext?.specimenName, "검정 셔츠 01")
    }

    func testInvalidReferencesAreNeverAcceptedOrArchived() throws {
        var model = model()
        XCTAssertTrue(model.apply(output(for: model), for: model.calculationRevision))
        let revision = model.persistenceRevision
        for reference in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertFalse(model.setReferenceCentimeters(reference))
            XCTAssertEqual(model.referenceCentimeters, 50)
            XCTAssertEqual(model.persistenceRevision, revision)
            XCTAssertEqual(try model.makeRecord().referenceCentimeters, 50)
        }
        XCTAssertTrue(model.setReferenceCentimeters(nil))
        XCTAssertNil(try model.makeRecord().referenceCentimeters)
    }

    func testInvalidInitialReferenceIsNotStoredAndDefaultContextDoesNotInventDevice() {
        let snapshot = model().snapshot
        for reference in [0.0, -1, .nan, .infinity] {
            let model = ManualMeasurement(snapshot: snapshot, expectedMeters: 0.5, referenceCentimeters: reference)
            XCTAssertNil(model.referenceCentimeters)
            XCTAssertEqual(model.testContext.deviceModel, "")
        }
        XCTAssertNil(ManualMeasurement(snapshot: snapshot, expectedMeters: .infinity).referenceCentimeters)
        XCTAssertEqual(ManualMeasurement(snapshot: snapshot, expectedMeters: 0.5).referenceCentimeters, 50)
    }

    func testSwitchingCategoryDropsIncompatibleDefinitionReferenceAndConfirmedPoints() {
        var model = model()
        model.selectDefinition(.longSleeve[0])
        model.setReferenceCentimeters(52)
        model.placePoint(displayPoint: .init(x: 0.3, y: 0.5), index: 0)
        model.placePoint(displayPoint: .init(x: 0.7, y: 0.5), index: 1)
        model.apply(output(for: model), for: model.calculationRevision)
        let revision = model.calculationRevision
        model.selectCategory(.bottoms)
        XCTAssertEqual(model.definition.id, "waist")
        XCTAssertEqual(model.testContext.category, .bottoms)
        XCTAssertNil(model.referenceCentimeters)
        XCTAssertTrue(model.landmarks.points.allSatisfy { !$0.isVisible })
        XCTAssertNil(model.result)
        XCTAssertNotEqual(revision, model.calculationRevision)
    }

    func testCompatibleCategoryAndImportedCustomDefinitionKeepTheirMeaning() {
        var model = model()
        let revision = model.calculationRevision
        model.selectCategory(.bottoms)
        XCTAssertEqual(model.definition.id, "test")
        XCTAssertEqual(model.calculationRevision, revision)
        XCTAssertEqual(model.referenceCentimeters, 50)
        let custom = MeasurementDefinition(id: "custom-seam", title: "기존 기준선", landmarkIDs: ["a", "b"])
        let imported = ManualMeasurement(snapshot: model.snapshot, definition: custom)
        XCTAssertEqual(imported.availableDefinitions.first?.id, "custom-seam")
        XCTAssertEqual(imported.landmarks.points.map(\.id), ["a", "b"])
    }

    func testManualConfirmationNeverSilentlyAcceptsRemainingModelPoints() {
        let original = model()
        var points = original.landmarks
        points.origin = .model
        points.modelVersion = "example-model"
        var model = ManualMeasurement(snapshot: original.snapshot, landmarks: points)
        XCTAssertTrue(model.placePoint(displayPoint: points.points[0].point, index: 0))
        XCTAssertEqual(model.landmarks.origin, .manual)
        XCTAssertNil(model.landmarks.modelVersion)
        XCTAssertEqual(model.landmarks.points.map(\.isVisible), [true, false])
        XCTAssertEqual(output(for: model).values.first?.failure, .occludedLandmark)
        XCTAssertTrue(model.placePoint(displayPoint: points.points[1].point, index: 1))
        XCTAssertEqual(output(for: model).values.first?.status, .valid)
    }

    func testOrientationClampingAndInvalidGestureDoNotCorruptGeometry() {
        var model = model(orientation: .right)
        let originalPoint = model.landmarks.points[0].point
        let displayPoint = ImageCoordinateTransform.originalToDisplay(originalPoint, orientation: .right)
        XCTAssertTrue(model.placePoint(displayPoint: displayPoint, index: 0))
        XCTAssertEqual(model.landmarks.points[0].point.x, originalPoint.x, accuracy: 0.000_001)
        XCTAssertEqual(model.landmarks.points[0].point.y, originalPoint.y, accuracy: 0.000_001)
        XCTAssertTrue(model.placePoint(displayPoint: .init(x: 3, y: -2), index: 0))
        XCTAssertTrue(model.landmarks.points[0].point.isValid)
        let revision = model.calculationRevision
        XCTAssertFalse(model.placePoint(displayPoint: .init(x: .nan, y: 0.5), index: 0))
        XCTAssertFalse(model.placePoint(displayPoint: .init(x: 0.5, y: 0.5), index: 5))
        XCTAssertEqual(revision, model.calculationRevision)
    }

    func testOptionChangeRetainsImportedSettingsAndRejectsOldResult() throws {
        let original = model()
        var options = MeasurementOptions()
        options.sampleRadius = 5
        options.minimumSamples = 9
        var model = ManualMeasurement(snapshot: original.snapshot, landmarks: original.landmarks, options: options)
        let previous = output(for: model), revision = model.calculationRevision
        model.setUseLocalPlane(false)
        XCTAssertEqual(model.options.sampleRadius, 5)
        XCTAssertEqual(model.options.minimumSamples, 9)
        XCTAssertFalse(model.options.useLocalPlane)
        XCTAssertFalse(model.apply(previous, for: revision))
        XCTAssertTrue(model.apply(output(for: model), for: model.calculationRevision))
        let record = try model.makeRecord()
        XCTAssertEqual(record.options.sampleRadius, 5)
        XCTAssertFalse(record.options.useLocalPlane)
    }

    func testMismatchedFrameSourceAndDefinitionResultsAreRejected() {
        var model = model()
        let revision = model.calculationRevision
        let correct = output(for: model)
        var mismatched = correct
        mismatched.frameID = UUID()
        XCTAssertFalse(model.apply(mismatched, for: revision))
        mismatched = correct; mismatched.sessionID = UUID()
        XCTAssertFalse(model.apply(mismatched, for: revision))
        mismatched = correct; mismatched.source = .sceneDepth
        XCTAssertFalse(model.apply(mismatched, for: revision))
        mismatched = correct; mismatched.values[0].id = "wrong-definition"
        XCTAssertFalse(model.apply(mismatched, for: revision))
        mismatched = correct; mismatched.values.append(correct.values[0])
        XCTAssertFalse(model.apply(mismatched, for: revision))
        XCTAssertNil(model.result)
        XCTAssertTrue(model.apply(correct, for: revision))
    }

    func testUnavailableMeasurementIsSavedWithImmutableInputsForFailureAnalysis() throws {
        let scene = SyntheticFixtures.scene(missingDepth: true)
        let snapshot = CaptureSnapshot(frame: scene.frame, imageJPEG: Data([9, 8, 7]))
        var model = ManualMeasurement(snapshot: snapshot, landmarks: scene.landmarks,
            testContext: .init(category: .top, specimenName: "셔츠", deviceModel: "테스트 기기", conditions: "합성 깊이 없음"))
        XCTAssertTrue(model.apply(output(for: model), for: model.calculationRevision))
        let id = UUID(), savedAt = Date(timeIntervalSince1970: 100)
        let record = try model.makeRecord(id: id, savedAt: savedAt)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.savedAt, savedAt)
        XCTAssertEqual(record.snapshot.imageJPEG, snapshot.imageJPEG)
        XCTAssertEqual(record.snapshot.frame.frameID, snapshot.frame.frameID)
        XCTAssertEqual(record.result.values.first?.failure, .insufficientDepth)
        XCTAssertEqual(record.result.values.first?.status, .unavailable)
        XCTAssertEqual(record.testContext?.deviceModel, "테스트 기기")
    }

    func testMalformedEmptyDefinitionCanBeReportedWithoutIndexingCrash() {
        var model = ManualMeasurement(snapshot: model().snapshot,
            definition: .init(id: "empty", title: "잘못된 정의", landmarkIDs: []))
        XCTAssertTrue(model.landmarks.points.isEmpty)
        XCTAssertTrue(model.apply(output(for: model), for: model.calculationRevision))
        XCTAssertEqual(model.result?.values.first?.failure, .invalidDefinition)
    }
}
