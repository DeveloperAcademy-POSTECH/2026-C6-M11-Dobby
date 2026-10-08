import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Explicit point confirmation and frozen-frame replay, not sensor accuracy.
final class AutomaticTotalLengthCorrectionTests: XCTestCase {
    private let neck = ImagePoint(x: 0.5, y: 0.25)
    private let hem = ImagePoint(x: 0.5, y: 0.8)

    private func model(missingIDs: Set<String> = ["neck_center", "hem_center"],
                       projected: Bool = false, missingNeckDepth: Bool = false) -> AutomaticMeasurement {
        let scene = SyntheticFixtures.scene()
        var frame = scene.frame
        if missingNeckDepth {
            let width = frame.depth.size.width
            let x = Int(neck.x * Double(width)), y = Int(neck.y * Double(frame.depth.size.height))
            for row in (y - 3)...(y + 3) { for column in (x - 3)...(x + 3) {
                frame.depth.values[row * width + column] = 0
            } }
        }
        var landmarks = scene.landmarks
        landmarks.origin = .model
        landmarks.modelVersion = AutomaticGarmentKind.top.modelVersion
        landmarks.garmentKind = .top
        landmarks.points += [
            .init(id: "neck_left", point: .init(x: 0.4, y: 0.25), confidence: 0.9),
            .init(id: "neck_right", point: .init(x: 0.6, y: 0.25), confidence: 0.9),
            .init(id: "neck_center", point: neck, confidence: 0.9,
                  derivedFrom: ["neck_left", "neck_right"]),
            .init(id: "hem_center", point: hem, confidence: 0.9)
        ]
        landmarks.points.removeAll { missingIDs.contains($0.id) }
        let definitions: [MeasurementDefinition] = [
            .testDistance,
            .init(id: "top.totalLength", title: "총장", landmarkIDs: ["neck_center", "hem_center"],
                  projection: projected ? .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"]) : nil)
        ]
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        return .init(output: .init(runID: UUID(), snapshot: .init(frame: frame, imageJPEG: Data([1, 2, 3])),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    private func confirmedCorrection(for model: AutomaticMeasurement) throws -> ManualMeasurement {
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: neck, index: 0))
        XCTAssertTrue(manual.placePoint(displayPoint: hem, index: 1))
        return manual
    }

    private func calculate(_ model: AutomaticMeasurement) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: model.options).measure(frame: model.snapshot.frame,
            landmarks: model.calculationLandmarks, definitions: model.definitions)
    }

    private func totalLength(_ result: GarmentMeasurementResult) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == "top.totalLength" })
    }

    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testMissingEndpointsStayUnavailableUntilBothAreExplicitlyConfirmed() throws {
        var automatic = model()
        let originalRevision = automatic.calculationRevision
        let originalPersistence = automatic.persistenceRevision
        XCTAssertTrue(automatic.canCorrectTotalLength)
        XCTAssertNil(try totalLength(automatic.result).meters)
        XCTAssertEqual(try totalLength(automatic.result).failure, .missingLandmark)
        XCTAssertFalse(automatic.placePoint(originalPoint: neck, id: "neck_center"),
                       "Ordinary dragging must not create a missing point")
        XCTAssertFalse(automatic.placePoint(originalPoint: hem, id: "arbitrary"))
        var manual = try XCTUnwrap(automatic.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.landmarks.points.allSatisfy { !$0.isVisible })
        XCTAssertFalse(automatic.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(manual.placePoint(displayPoint: neck, index: 0))
        XCTAssertFalse(automatic.applyTotalLengthCorrection(from: manual),
                       "One confirmation must not partially modify the automatic model")
        XCTAssertEqual(automatic.calculationRevision, originalRevision)
        XCTAssertEqual(automatic.persistenceRevision, originalPersistence)
        XCTAssertTrue(automatic.calculationLandmarks.points.allSatisfy { !["neck_center", "hem_center"].contains($0.id) })
        XCTAssertTrue(manual.placePoint(displayPoint: hem, index: 1))
        XCTAssertTrue(automatic.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(automatic.needsRecalculation)
        XCTAssertNil(try totalLength(automatic.result).meters,
                     "Confirming image points must not invent a length before depth replay")
    }

    func testCorrectionRestoresOnlySupportedMissingEndpointsAndPreservesRawEvidence() throws {
        for missing: Set<String> in [["neck_center"], ["hem_center"], ["neck_center", "hem_center"]] {
            var automatic = model(missingIDs: missing)
            let originalLandmarks = try bytes(automatic.landmarks)
            let originalResult = try bytes(automatic.originalResult)
            let originalSnapshot = try bytes(automatic.snapshot)
            let originalRevision = automatic.calculationRevision
            let originalResultRevision = automatic.result
            let manual = try confirmedCorrection(for: automatic)
            XCTAssertTrue(automatic.applyTotalLengthCorrection(from: manual))
            XCTAssertEqual(automatic.editedPointIDs, ["neck_center", "hem_center"])
            XCTAssertEqual(automatic.calculationLandmarks.points.count, automatic.landmarks.points.count + missing.count)
            XCTAssertEqual(automatic.calculationLandmarks.origin, .model)
            XCTAssertFalse(automatic.apply(originalResultRevision, for: originalRevision))
            XCTAssertThrowsError(try automatic.makeRecord())
            for point in automatic.landmarks.points where !["neck_center", "hem_center"].contains(point.id) {
                let current = try XCTUnwrap(automatic.calculationLandmarks.points.first { $0.id == point.id })
                XCTAssertEqual(try bytes(current), try bytes(point))
            }
            let corrected = calculate(automatic)
            XCTAssertTrue(automatic.apply(corrected, for: automatic.calculationRevision))
            XCTAssertEqual(try XCTUnwrap(totalLength(corrected).meters), 0.6325, accuracy: 0.000001)
            XCTAssertEqual(corrected.values.first?.meters, automatic.originalResult.values.first?.meters)
            XCTAssertTrue(try totalLength(corrected).points.allSatisfy {
                $0.quality.method != .spatialAverage && $0.sourceLandmarkIDs == nil
            })
            XCTAssertEqual(try bytes(automatic.landmarks), originalLandmarks)
            XCTAssertEqual(try bytes(automatic.originalResult), originalResult)
            XCTAssertEqual(try bytes(automatic.snapshot), originalSnapshot)
            let record = try automatic.makeRecord()
            XCTAssertEqual(try bytes(try XCTUnwrap(record.originalAutomaticLandmarks)), originalLandmarks)
            XCTAssertEqual(try bytes(try XCTUnwrap(record.originalAutomaticResult)), originalResult)
            let acceptedRevision = automatic.calculationRevision
            let acceptedPersistenceRevision = automatic.persistenceRevision
            XCTAssertTrue(automatic.applyTotalLengthCorrection(from: manual))
            XCTAssertEqual(automatic.calculationRevision, acceptedRevision,
                           "Repeated application must not invalidate an already accepted calculation")
            XCTAssertEqual(automatic.persistenceRevision, acceptedPersistenceRevision)
            XCTAssertFalse(automatic.needsRecalculation)
        }
    }

    func testCorrectionRejectsOtherCapturesCoordinatesAndLandmarkSessionsAtomically() throws {
        var automatic = model()
        let correction = try confirmedCorrection(for: automatic)
        let originalRevision = automatic.calculationRevision
        var incompatibleSnapshots: [CaptureSnapshot] = []
        var snapshot = correction.snapshot
        snapshot.frame.frameID = UUID(); incompatibleSnapshots.append(snapshot)
        snapshot = correction.snapshot
        snapshot.frame.sessionID = UUID(); incompatibleSnapshots.append(snapshot)
        snapshot = correction.snapshot
        snapshot.frame.source = .sceneDepth; incompatibleSnapshots.append(snapshot)
        snapshot = correction.snapshot
        snapshot.frame.orientation = .right; incompatibleSnapshots.append(snapshot)
        snapshot = correction.snapshot
        snapshot.frame.intrinsics.fx += 1; incompatibleSnapshots.append(snapshot)
        for snapshot in incompatibleSnapshots {
            let other = ManualMeasurement(snapshot: snapshot, landmarks: correction.landmarks,
                                          definition: correction.definition)
            XCTAssertFalse(automatic.applyTotalLengthCorrection(from: other))
        }
        var wrongLandmarks = correction.landmarks
        wrongLandmarks.sessionID = UUID()
        XCTAssertFalse(automatic.applyTotalLengthCorrection(from: .init(snapshot: correction.snapshot,
            landmarks: wrongLandmarks, definition: correction.definition)))
        XCTAssertEqual(automatic.calculationRevision, originalRevision)
        XCTAssertFalse(automatic.hasPointAdjustments)
    }

    func testCorrectionRejectsUnexpectedEndpointsAndUnconfirmedProvenance() throws {
        var automatic = model()
        let correction = try confirmedCorrection(for: automatic)
        var malformed: [GarmentLandmarkSet] = []
        var points = correction.landmarks
        points.points[1].id = "arbitrary"; malformed.append(points)
        points = correction.landmarks
        points.points[1].isVisible = false; malformed.append(points)
        points = correction.landmarks
        points.points[1].origin = .model; malformed.append(points)
        points = correction.landmarks
        points.points[1].derivedFrom = ["neck_left", "neck_right"]; malformed.append(points)
        points = correction.landmarks
        points.points[1].point.x = .nan; malformed.append(points)
        for points in malformed {
            XCTAssertFalse(automatic.applyTotalLengthCorrection(from: .init(snapshot: correction.snapshot,
                landmarks: points, definition: correction.definition)))
        }
        XCTAssertFalse(automatic.hasPointAdjustments)
        XCTAssertNil(try totalLength(automatic.result).meters)
    }

    func testReloadAndResetRestoreOriginalMissingPointFailure() throws {
        var automatic = model()
        XCTAssertTrue(automatic.applyTotalLengthCorrection(from: try confirmedCorrection(for: automatic)))
        XCTAssertTrue(automatic.apply(calculate(automatic), for: automatic.calculationRevision))
        let encoded = try bytes(automatic.makeRecord())
        var reopened = AutomaticMeasurement(record: try JSONDecoder().decode(SavedMeasurement.self, from: encoded))
        XCTAssertEqual(reopened.editedPointIDs, ["neck_center", "hem_center"])
        XCTAssertNotNil(try totalLength(reopened.result).meters)
        reopened.resetPointAdjustments()
        XCTAssertTrue(reopened.needsRecalculation)
        XCTAssertFalse(reopened.hasPointAdjustments)
        XCTAssertEqual(try bytes(reopened.calculationLandmarks), try bytes(reopened.landmarks))
        XCTAssertTrue(reopened.apply(calculate(reopened), for: reopened.calculationRevision))
        XCTAssertEqual(try totalLength(reopened.result).failure, .missingLandmark)
        XCTAssertNil(try totalLength(reopened.result).meters)
    }

    func testManualConfirmationDoesNotBypassMissingDepthOrBreakUnrelatedMeasurements() throws {
        var automatic = model(missingNeckDepth: true)
        XCTAssertTrue(automatic.applyTotalLengthCorrection(from: try confirmedCorrection(for: automatic)))
        XCTAssertTrue(automatic.apply(calculate(automatic), for: automatic.calculationRevision))
        XCTAssertEqual(try totalLength(automatic.result).failure, .insufficientDepth)
        XCTAssertNil(try totalLength(automatic.result).meters)
        XCTAssertEqual(automatic.result.values.first?.status, .valid)
        XCTAssertEqual(try XCTUnwrap(automatic.result.values.first?.meters), 0.5, accuracy: 0.000001)
        XCTAssertNoThrow(try automatic.makeRecord())
    }

    func testLegacyProjectionCannotUseCorrectionToInventMissingAxisPoints() throws {
        var automatic = model(missingIDs: ["neck_left", "neck_right"], projected: true)
        let original = try bytes(automatic.landmarks)
        XCTAssertFalse(automatic.canCorrectTotalLength)
        let manual = try confirmedCorrection(for: automatic)
        XCTAssertEqual(manual.definition.id, "top.totalLength.manualStraight")
        XCTAssertFalse(automatic.applyTotalLengthCorrection(from: manual))
        XCTAssertEqual(try bytes(automatic.calculationLandmarks), original)
        XCTAssertFalse(automatic.hasPointAdjustments)
        XCTAssertEqual(try totalLength(calculate(automatic)).failure, .missingLandmark)
    }
}
