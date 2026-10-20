import Foundation
import XCTest
@testable import DobbyLiDARCore

@MainActor
final class AutomaticLandmarkAdjustmentTests: XCTestCase {
    private func model(tilted: Bool = false, legacyProjection: Bool = false) -> AutomaticMeasurement {
        let size = PixelSize(width: 200, height: 200)
        let values: [Float] = (0..<40_000).map { index in
            let ray = (Double(index % 200) + 0.5 - 100) / 200
            return Float(tilted ? 1 / (1 - 0.5 * ray) : 1)
        }
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 200, fy: 200, cx: 100, cy: 100, referenceSize: size),
            depth: .init(size: size, values: values, confidence: .init(repeating: 2, count: values.count)),
            source: .synthetic, orientation: .right)
        let points: [GarmentLandmark] = [
            .init(id: "neck_left", point: .init(x: 0.35, y: 0.25), confidence: 1),
            .init(id: "neck_right", point: .init(x: 0.65, y: 0.25), confidence: 1),
            .init(id: "shoulder_left", point: .init(x: 0.25, y: 0.3), confidence: 1),
            .init(id: "shoulder_right", point: .init(x: 0.75, y: 0.3), confidence: 1),
            .init(id: "armpit_left", point: .init(x: 0.3, y: 0.45), confidence: 1),
            .init(id: "armpit_right", point: .init(x: 0.7, y: 0.45), confidence: 1),
            .init(id: "sleeve_end_left", point: .init(x: 0.1, y: 0.65), confidence: 1),
            .init(id: "sleeve_end_right", point: .init(x: 0.9, y: 0.65), confidence: 1),
            .init(id: "hem_left", point: .init(x: 0.3, y: 0.8), confidence: 1),
            .init(id: "hem_center", point: .init(x: 0.7, y: 0.8), confidence: 1),
            .init(id: "hem_right", point: .init(x: 0.7, y: 0.8), confidence: 1),
            .init(id: "neck_center", point: .init(x: 0.5, y: 0.25), confidence: 1,
                  derivedFrom: ["neck_left", "neck_right"])
        ]
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID, origin: .model,
            modelVersion: AutomaticGarmentKind.legacyTopModelVersion, points: points,
            mask: .init(size: size, values: .init(repeating: 1, count: values.count)), garmentKind: .top)
        let definitions = TopLandmarkSchema.legacyMeasurementDefinitions.map { definition in
            var result = definition
            if legacyProjection, result.id == "top.totalLength" {
                result.projection = .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"])
            }
            return result
        }
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        return .init(output: .init(runID: UUID(), snapshot: .init(frame: frame, imageJPEG: Data([1, 2, 3])),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    private func calculate(_ model: AutomaticMeasurement) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: model.options).measure(frame: model.snapshot.frame,
            landmarks: model.calculationLandmarks, definitions: model.definitions)
    }

    private func value(_ result: GarmentMeasurementResult, _ id: String) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == id })
    }

    private func point(_ landmarks: GarmentLandmarkSet, _ id: String) throws -> GarmentLandmark {
        try XCTUnwrap(landmarks.points.first { $0.id == id })
    }

    private func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testOneSharedShoulderEditRecalculatesWidthAndSleeveWithoutChangingOtherDimensionsOrOriginalEvidence() throws {
        var session = model()
        let original = try canonicalBytes(session.landmarks)
        let initial = session.result
        try session.setReference(50, for: "top.shoulderWidth")
        let depth = session.snapshot.frame.depth.values
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        XCTAssertEqual(session.editedPointIDs, ["shoulder_left"])
        XCTAssertEqual(session.snapshot.frame.depth.values, depth)
        XCTAssertEqual(try point(session.calculationLandmarks, "shoulder_left").point, .init(x: 0.2, y: 0.3),
                       "Core accepts raw coordinates without applying the .right orientation a second time")
        let corrected = calculate(session)
        XCTAssertTrue(session.apply(corrected, for: session.calculationRevision))
        XCTAssertEqual(try XCTUnwrap(value(corrected, "top.shoulderWidth").meters), 0.55, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(value(corrected, "top.sleeveLengthLeft").meters), hypot(0.1, 0.35), accuracy: 0.000001)
        XCTAssertEqual(try value(corrected, "top.chestWidth").meters, try value(initial, "top.chestWidth").meters)
        XCTAssertEqual(try canonicalBytes(session.landmarks), original)
        XCTAssertEqual(session.referenceByDefinitionCentimeters["top.shoulderWidth"], 50)
        XCTAssertEqual(try point(session.calculationLandmarks, "shoulder_left").origin, .manual)
        XCTAssertNil(try point(session.calculationLandmarks, "shoulder_left").confidence)
        XCTAssertEqual(try point(session.landmarks, "shoulder_left").confidence, 1)
    }

    func testUntouchedLowConfidenceAndOccludedModelPointsRemainUnavailableAfterAnotherPointIsConfirmed() throws {
        var saved = try model().makeRecord()
        saved.landmarks.points[saved.landmarks.points.firstIndex { $0.id == "shoulder_right" }!].confidence = 0.1
        saved.landmarks.points[saved.landmarks.points.firstIndex { $0.id == "hem_center" }!].isVisible = false
        var session = AutomaticMeasurement(record: saved)
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        let output = calculate(session)
        XCTAssertEqual(try value(output, "top.shoulderWidth").failure, .lowLandmarkConfidence)
        XCTAssertEqual(try value(output, "top.totalLength").failure, .occludedLandmark)
        XCTAssertEqual(try value(output, "top.sleeveLengthLeft").status, .valid)
        XCTAssertEqual(try point(session.calculationLandmarks, "shoulder_right").confidence, 0.1)
        XCTAssertEqual(session.calculationLandmarks.origin, .model)
    }

    private func correctedNeckParent(legacyProjection: Bool = false) throws -> AutomaticMeasurement {
        var record = try model(legacyProjection: legacyProjection).makeRecord()
        for id in ["neck_left", "neck_center"] {
            let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == id })
            record.landmarks.points[index].confidence = 0.1
            record.landmarks.points[index].isVisible = false
        }
        var session = AutomaticMeasurement(record: record)
        XCTAssertFalse(session.editableLandmarks.points.contains { $0.id == "neck_center" })
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.35, y: 0.25), id: "neck_left"))
        let neck = try point(session.calculationLandmarks, "neck_center")
        XCTAssertEqual(neck.derivedFrom, ["neck_left", "neck_right"])
        XCTAssertTrue(neck.isVisible)
        XCTAssertNil(neck.confidence)
        XCTAssertEqual(neck.origin, .manual)
        return session
    }

    func testCorrectedNeckParentRepairsDerivedVisibilityAndConfidenceForCurrentStraightTotalLength() throws {
        let session = try correctedNeckParent()
        let output = calculate(session)
        let length = try value(output, "top.totalLength")
        XCTAssertEqual(try XCTUnwrap(length.meters), hypot(0.2, 0.55), accuracy: 0.000001)
        XCTAssertEqual(length.points.first?.quality.method, .spatialAverage)
        XCTAssertNotEqual(length.points.last?.quality.method, .axisProjection)
        XCTAssertNil(session.definitions.last?.projection)
        XCTAssertEqual(length.points.last?.imagePoint, try point(session.calculationLandmarks, "hem_center").point,
                       "The current straight segment ends at its editable physical hem marker")
    }

    func testCorrectedNeckParentPreservesExplicitLegacyProjectionContract() throws {
        let session = try correctedNeckParent(legacyProjection: true)
        let output = calculate(session)
        let length = try value(output, "top.totalLength")
        XCTAssertEqual(try XCTUnwrap(length.meters), 0.55, accuracy: 0.000001)
        XCTAssertEqual(length.points.first?.quality.method, .spatialAverage)
        XCTAssertEqual(length.points.last?.quality.method, .axisProjection)
        XCTAssertEqual(session.definitions.last?.projection?.referenceAxisLandmarkIDs, ["neck_left", "neck_right"])
        XCTAssertEqual(try point(session.calculationLandmarks, "hem_center").point.x, 0.7,
                       "Projected annotation does not overwrite its direct physical endpoint")
    }

    func testDerivedDisplayOnTiltedDepthUsesSpatialMeanInsteadOfSamplingEditedTwoDimensionalMidpoint() throws {
        var session = model(tilted: true)
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.25), id: "neck_left"))
        let output = calculate(session)
        XCTAssertTrue(session.apply(output, for: session.calculationRevision))
        let rawHint = try point(session.calculationLandmarks, "neck_center").point
        let displayed = try point(session.displayLandmarks, "neck_center").point
        XCTAssertEqual(rawHint.x, 0.425, accuracy: 0.000001)
        XCTAssertGreaterThan(abs(displayed.x - rawHint.x), 0.005)
        let aZ = 1 / (1 - 0.5 * (0.2 - 0.5)), bZ = 1 / (1 - 0.5 * (0.65 - 0.5))
        let spatialX = ((0.2 - 0.5) * aZ + (0.65 - 0.5) * bZ) / 2
        let spatialZ = (aZ + bZ) / 2
        XCTAssertEqual(displayed.x, spatialX / spatialZ + 0.5, accuracy: 0.00001)
    }

    func testLegacyWaistMidpointRemainsDerivedAfterDirectWaistCorrection() throws {
        var record = try model().makeRecord()
        record.landmarks.modelVersion = AutomaticGarmentKind.legacyBottomModelVersion
        record.landmarks.garmentKind = .bottoms
        record.landmarks.points = [
            .init(id: "waist_left", point: .init(x: 0.3, y: 0.2), confidence: 1),
            .init(id: "waist_right", point: .init(x: 0.7, y: 0.2), confidence: 1),
            .init(id: "waist_center", point: .init(x: 0.5, y: 0.2), confidence: 0.1),
            .init(id: "crotch", point: .init(x: 0.5, y: 0.7), confidence: 1)
        ]
        record.definitions = [.init(id: "rise", title: "밑위", landmarkIDs: ["waist_center", "crotch"])]
        record.result = LiDARMeasurementEngine().measure(frame: record.snapshot.frame, landmarks: record.landmarks,
                                                        definitions: record.definitions)
        var session = AutomaticMeasurement(record: record)
        XCTAssertFalse(session.placePoint(originalPoint: .init(x: 0.4, y: 0.2), id: "waist_center"))
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.2), id: "waist_left"))
        XCTAssertEqual(session.calculationLandmarks.effectiveDerivedSourceIDs(for: "waist_center"), ["waist_left", "waist_right"])
        let output = calculate(session)
        XCTAssertEqual(try XCTUnwrap(output.values.first?.meters), hypot(0.05, 0.5), accuracy: 0.000001)
        XCTAssertEqual(output.values.first?.points.first?.sourceLandmarkIDs, ["waist_left", "waist_right"])
    }

    func testStaleCalculationCannotApplyOrSaveAndResetRestoresOriginalInputs() throws {
        var session = model()
        let original = session.landmarks
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        let oldRevision = session.calculationRevision
        let oldOutput = calculate(session)
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.15, y: 0.3), id: "shoulder_left"))
        XCTAssertFalse(session.apply(oldOutput, for: oldRevision))
        XCTAssertFalse(session.apply(oldOutput))
        XCTAssertTrue(session.needsRecalculation)
        XCTAssertThrowsError(try session.makeRecord())
        XCTAssertTrue(session.apply(calculate(session), for: session.calculationRevision))
        XCTAssertNoThrow(try session.makeRecord())
        session.resetPointAdjustments()
        XCTAssertFalse(session.hasPointAdjustments)
        XCTAssertTrue(session.needsRecalculation)
        XCTAssertEqual(session.calculationLandmarks.points.map(\.point), original.points.map(\.point))
        XCTAssertTrue(session.apply(calculate(session), for: session.calculationRevision))
        XCTAssertNil(try session.makeRecord().originalAutomaticLandmarks)
    }

    func testNeckCenterEditRecalculatesPersistsAndResetsWithoutMovingParents() throws {
        var session = model()
        let original = session.calculationLandmarks
        let initialLength = try value(session.result, "top.totalLength").meters
        let target = ImagePoint(x: 0.5, y: 0.35)
        XCTAssertTrue(session.placePoint(originalPoint: target, id: "neck_center"))
        XCTAssertNil(try point(session.calculationLandmarks, "neck_center").derivedFrom)
        XCTAssertEqual(session.editedPointIDs, ["neck_center"])
        for id in ["neck_left", "neck_right"] {
            XCTAssertEqual(try point(session.calculationLandmarks, id).point, try point(original, id).point)
        }
        XCTAssertTrue(session.apply(calculate(session), for: session.calculationRevision))
        let length = try XCTUnwrap(value(session.result, "top.totalLength").meters)
        XCTAssertLessThan(length, try XCTUnwrap(initialLength))
        let data = try JSONEncoder().encode(session.makeRecord())
        var reopened = AutomaticMeasurement(record: try JSONDecoder().decode(SavedMeasurement.self, from: data))
        XCTAssertEqual(try point(reopened.calculationLandmarks, "neck_center").point, target)
        XCTAssertNil(try point(reopened.calculationLandmarks, "neck_center").derivedFrom)
        XCTAssertTrue(reopened.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        XCTAssertEqual(try point(reopened.calculationLandmarks, "neck_center").point, target)
        reopened.resetPointAdjustments()
        XCTAssertEqual(try point(reopened.calculationLandmarks, "neck_center").derivedFrom, ["neck_left", "neck_right"])
        XCTAssertTrue(reopened.apply(calculate(reopened), for: reopened.calculationRevision))
        XCTAssertEqual(try value(reopened.result, "top.totalLength").meters, initialLength)
    }

    func testInvalidCoordinatesUnknownAndDerivedIDsDoNotMutateRevisionOrGeometry() {
        var session = model()
        let revision = session.calculationRevision
        for (id, point) in [("missing", ImagePoint(x: 0.5, y: 0.5)), ("neck_center", .init(x: -0.1, y: 0.3)),
                            ("hem_center", .init(x: 1, y: 0.3)), ("hem_center", .init(x: .nan, y: 0.3))] {
            XCTAssertFalse(session.placePoint(originalPoint: point, id: id))
        }
        XCTAssertEqual(session.calculationRevision, revision)
        XCTAssertFalse(session.hasPointAdjustments)
    }

    func testArchiveRoundTripRetainsOriginalConfidenceCorrectedGeometryAndCurrentResult() async throws {
        var session = model()
        let originalBytes = try canonicalBytes(session.landmarks)
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        XCTAssertTrue(session.apply(calculate(session), for: session.calculationRevision))
        let record = try session.makeRecord()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DobbyFullPoseEdits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        _ = try await archive.save(record)
        let reopened = AutomaticMeasurement(record: try await archive.load(record.id))
        XCTAssertEqual(try canonicalBytes(reopened.landmarks), originalBytes)
        XCTAssertEqual(reopened.editedPointIDs, ["shoulder_left"])
        XCTAssertFalse(reopened.needsRecalculation)
        XCTAssertEqual(try point(reopened.calculationLandmarks, "shoulder_left").point.x, 0.2)
        XCTAssertEqual(try value(reopened.result, "top.shoulderWidth").meters, 0.55)
        XCTAssertEqual(reopened.snapshot.frame.depth.values, session.snapshot.frame.depth.values)
        XCTAssertEqual(reopened.originalResult.values.map(\.meters), session.originalResult.values.map(\.meters))
    }

    func testLegacyJSONWithoutOriginalOrPointProvenanceFieldsStillReplays() throws {
        let original = try model().makeRecord()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "originalAutomaticLandmarks")
        object.removeValue(forKey: "originalAutomaticResult")
        var landmarks = try XCTUnwrap(object["landmarks"] as? [String: Any])
        var points = try XCTUnwrap(landmarks["points"] as? [[String: Any]])
        for index in points.indices { points[index].removeValue(forKey: "origin") }
        landmarks["points"] = points; object["landmarks"] = landmarks
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: JSONSerialization.data(withJSONObject: object))
        let reopened = AutomaticMeasurement(record: decoded)
        XCTAssertFalse(reopened.hasPointAdjustments)
        XCTAssertEqual(calculate(reopened).values.map(\.meters), original.result.values.map(\.meters))
    }

    func testHumanCorrectionsAreExcludedFromAutomatedValidationTrack() throws {
        var record = try model().makeRecord()
        record.snapshot.frame.source = .sceneDepth // Contract fixture, not real sensor evidence.
        record.result.source = .sceneDepth
        var session = AutomaticMeasurement(record: record)
        XCTAssertTrue(session.placePoint(originalPoint: .init(x: 0.2, y: 0.3), id: "shoulder_left"))
        XCTAssertTrue(session.apply(calculate(session), for: session.calculationRevision))
        var builder = MeasurementValidationReportBuilder()
        builder.add(try session.makeRecord())
        XCTAssertEqual(builder.report().automated.attempts, 0)
        XCTAssertEqual(builder.report().manual.attempts, session.definitions.count)
    }
}
