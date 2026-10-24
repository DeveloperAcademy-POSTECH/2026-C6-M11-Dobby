import Foundation
import XCTest
@testable import DobbyLiDARCore

final class AutomaticMeasurementModelTests: XCTestCase {
    func testRetryPreservesOriginalPointsAndRejectsStaleCalculationWithoutInventingAnEdit() throws {
        var model = measurement()
        let result = model.result, original = model.landmarks
        let stale = model.calculationRevision
        model.requestRecalculation()
        XCTAssertTrue(model.needsRecalculation)
        XCTAssertThrowsError(try model.makeRecord())
        let superseded = model.calculationRevision
        model.requestRecalculation()
        XCTAssertFalse(model.apply(result, for: stale))
        XCTAssertFalse(model.apply(result, for: superseded))
        XCTAssertTrue(model.apply(result, for: model.calculationRevision))
        XCTAssertFalse(model.needsRecalculation)
        XCTAssertFalse(model.hasPointAdjustments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(model.landmarks.points), try encoder.encode(original.points))
        XCTAssertEqual(model.originalResult.values[0].meters, result.values[0].meters)
        XCTAssertNil(try model.makeRecord().originalAutomaticLandmarks)
    }

    private func measurement() -> AutomaticMeasurement {
        let fixture = SyntheticFixtures.scene()
        let definitions: [MeasurementDefinition] = [.testDistance,
            .init(id: "missing", title: "Missing", landmarkIDs: ["A", "unknown"])]
        let snapshot = CaptureSnapshot(frame: fixture.frame, imageJPEG: Data([1, 2, 3]))
        let options = MeasurementOptions()
        let result = LiDARMeasurementEngine(options: options).measure(frame: fixture.frame,
            landmarks: fixture.landmarks, definitions: definitions)
        return AutomaticMeasurement(output: .init(runID: UUID(), snapshot: snapshot, landmarks: fixture.landmarks,
            result: result, definitions: definitions, options: options,
            timings: .init(captureSeconds: 0.1, landmarksSeconds: 0.2, measurementSeconds: 0.03, totalSeconds: 0.33),
            startedAt: .now, finishedAt: .now))
    }

    func testReferencesRejectNonPhysicalNumbersWithoutReplacingValidValue() throws {
        var model = measurement()
        try model.setReference(50, for: "test")
        for invalid in [0.0, -1, Double.nan, .infinity] {
            XCTAssertThrowsError(try model.setReference(invalid, for: "test"))
            XCTAssertEqual(model.referenceByDefinitionCentimeters["test"], 50)
        }
        XCTAssertThrowsError(try model.setReference(1, for: "unknown"))
        try model.setReference(nil, for: "test")
        XCTAssertNil(model.referenceByDefinitionCentimeters["test"])
    }

    func testRecordRoundTripPreservesPartialFailureAndReferencesWithoutViewState() throws {
        var model = measurement()
        try model.setReference(50, for: "test")
        try model.setReference(20, for: "missing")
        model.context = .init(category: .top, specimenName: "shirt", deviceModel: "test device", conditions: "flat")
        let record = try model.makeRecord()
        let data = try JSONEncoder().encode(record)
        let reopened = AutomaticMeasurement(record: try JSONDecoder().decode(SavedMeasurement.self, from: data))
        XCTAssertEqual(reopened.referenceByDefinitionCentimeters, ["test": 50, "missing": 20])
        XCTAssertEqual(reopened.context, model.context)
        XCTAssertEqual(reopened.result.values[0].meters ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reopened.result.values[1].status, .unavailable)
        XCTAssertEqual(reopened.result.values[1].failure, .missingLandmark)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for viewOnlyKey in ["referenceTexts", "isSaving", "errorMessage", "image", "exportedURL"] {
            XCTAssertNil(json[viewOnlyKey])
        }
    }

    func testLegacyScalarIsOnlyAppliedToOneItemAndDoesNotOverrideItemReference() throws {
        var record = try measurement().makeRecord()
        record.referenceCentimeters = 75
        record.referenceByDefinitionCentimeters = nil
        XCTAssertTrue(AutomaticMeasurement(record: record).referenceByDefinitionCentimeters.isEmpty)
        record.definitions = [.testDistance]
        XCTAssertEqual(AutomaticMeasurement(record: record).referenceByDefinitionCentimeters["test"], 75)
        record.referenceByDefinitionCentimeters = ["test": 50]
        XCTAssertEqual(AutomaticMeasurement(record: record).referenceByDefinitionCentimeters["test"], 50)
    }

    func testImportedInvalidReferenceCannotBeSavedAsValidMeasurement() throws {
        var record = try measurement().makeRecord()
        record.referenceByDefinitionCentimeters = ["test": -1]
        XCTAssertThrowsError(try AutomaticMeasurement(record: record).makeRecord())
        record.referenceByDefinitionCentimeters = ["alien": 50]
        XCTAssertThrowsError(try AutomaticMeasurement(record: record).makeRecord())
    }

    func testReplayRejectsOtherFramesSourcesAndDefinitions() {
        var model = measurement()
        let original = model.result
        var other = original
        other.frameID = UUID()
        XCTAssertFalse(model.apply(other))
        other = original; other.sessionID = UUID()
        XCTAssertFalse(model.apply(other))
        other = original; other.source = .sceneDepth
        XCTAssertFalse(model.apply(other))
        other = original; other.values.reverse()
        XCTAssertFalse(model.apply(other))
        XCTAssertEqual(model.result.frameID, original.frameID)
        XCTAssertEqual(model.result.values.map(\.id), original.values.map(\.id))
        XCTAssertTrue(model.apply(original))
    }

    func testManualComparisonKeepsSameCaptureDefinitionAndModelProvenance() throws {
        var record = try measurement().makeRecord()
        record.landmarks.origin = .model
        record.landmarks.modelVersion = "fixture-model"
        record.landmarks.points.reverse()
        record.options.useLocalPlane = false
        record.referenceByDefinitionCentimeters = ["test": 51]
        let model = AutomaticMeasurement(record: record)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "test"))
        XCTAssertEqual(manual.snapshot.frame.frameID, model.snapshot.frame.frameID)
        XCTAssertEqual(manual.snapshot.imageJPEG, model.snapshot.imageJPEG)
        XCTAssertEqual(manual.landmarks.points.map(\.id), ["A", "B"])
        XCTAssertEqual(manual.landmarks.origin, .model)
        XCTAssertEqual(manual.landmarks.modelVersion, "fixture-model")
        XCTAssertFalse(manual.options.useLocalPlane)
        XCTAssertEqual(manual.referenceCentimeters, 51)
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.2, y: 0.5), index: 0))
        XCTAssertEqual(manual.landmarks.origin, .manual)
        XCTAssertFalse(manual.landmarks.points[1].isVisible)
        XCTAssertNil(model.manualMeasurement(for: "unknown"))
    }
}
