import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Preserving a spatial midpoint through display, editing and storage is part
/// of the measurement contract, not evidence of physical sensor accuracy.
final class DerivedLandmarkLifecycleTests: XCTestCase {
    private func measurement(legacy: Bool = false) -> AutomaticMeasurement {
        let scene = SyntheticFixtures.scene(tilted: true)
        var landmarks = scene.landmarks
        landmarks.origin = .model
        landmarks.modelVersion = legacy ? "bottom7-976144d4d652" : "analytic-fixture"
        landmarks.points[0].id = "waist_left"
        landmarks.points[1].id = "waist_right"
        let left = landmarks.points[0].point, right = landmarks.points[1].point
        landmarks.points += [
            .init(id: "waist_center", point: .init(x: (left.x + right.x) / 2, y: 0.5),
                  confidence: 1, derivedFrom: legacy ? nil : ["waist_left", "waist_right"]),
            .init(id: "crotch", point: .init(x: 0.5, y: 0.5 + 0.3 / 1.15), confidence: 1)
        ]
        let definitions: [MeasurementDefinition] = [
            .init(id: "rise", title: "밑위", landmarkIDs: ["waist_center", "crotch"])
        ]
        let snapshot = CaptureSnapshot(frame: scene.frame, imageJPEG: Data([1, 2, 3]))
        let options = MeasurementOptions()
        let result = LiDARMeasurementEngine(options: options).measure(frame: scene.frame,
            landmarks: landmarks, definitions: definitions)
        return AutomaticMeasurement(output: .init(runID: UUID(), snapshot: snapshot, landmarks: landmarks,
            result: result, definitions: definitions, options: options,
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    private func calculate(_ manual: ManualMeasurement) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: manual.options).measure(frame: manual.snapshot.frame,
            landmarks: manual.landmarks, definitions: [manual.definition])
    }

    private func center(in landmarks: GarmentLandmarkSet) throws -> GarmentLandmark {
        try XCTUnwrap(landmarks.points.first { $0.id == "waist_center" })
    }

    func testDisplayUsesReprojectedCenterWithoutMutatingOriginalPhotoCoordinates() throws {
        let model = measurement()
        let raw = try center(in: model.landmarks)
        let displayed = try center(in: model.displayLandmarks)
        XCTAssertGreaterThan(abs(raw.point.x - 0.5), 0.005)
        XCTAssertEqual(displayed.point.x, 0.5, accuracy: 0.000001)
        XCTAssertEqual(displayed.point.y, 0.5, accuracy: 0.000001)
        XCTAssertTrue(displayed.isVisible)
        XCTAssertEqual(try center(in: model.landmarks).point, raw.point)
        XCTAssertEqual(displayed.derivedFrom, ["waist_left", "waist_right"])
    }

    func testUnresolvedOrWrongCaptureResultCannotExposeThePlaceholderAsResolved() throws {
        let model = measurement()
        XCTAssertFalse(try center(in: model.landmarks.replacingDerivedImagePoints(with: nil)).isVisible)
        var other = model.result
        other.frameID = UUID()
        XCTAssertFalse(try center(in: model.landmarks.replacingDerivedImagePoints(with: other)).isVisible)
        other = model.result
        other.sessionID = UUID()
        XCTAssertFalse(try center(in: model.landmarks.replacingDerivedImagePoints(with: other)).isVisible)
        other = model.result
        other.values[0].points.removeAll { $0.id == "waist_center" }
        let display = model.landmarks.replacingDerivedImagePoints(with: other)
        XCTAssertFalse(try center(in: display).isVisible)
        XCTAssertTrue(try XCTUnwrap(display.points.first { $0.id == "crotch" }).isVisible)
    }

    func testManualComparisonKeepsSourcesButOnlyExposesTwoEditableEndpoints() throws {
        for legacy in [false, true] {
            let model = measurement(legacy: legacy)
            var manual = try XCTUnwrap(model.manualMeasurement(for: "rise"))
            XCTAssertEqual(manual.landmarks.points.map(\.id), ["waist_center", "crotch", "waist_left", "waist_right"])
            XCTAssertEqual(manual.displayLandmarks.points.map(\.id), ["waist_center", "crotch"])
            let result = calculate(manual)
            XCTAssertTrue(manual.apply(result, for: manual.calculationRevision))
            XCTAssertEqual(try XCTUnwrap(result.values.first?.meters), 0.3, accuracy: 0.000001)
            XCTAssertEqual(try center(in: manual.displayLandmarks).point.x, 0.5, accuracy: 0.000001)
            XCTAssertEqual(manual.snapshot.frame.frameID, model.snapshot.frame.frameID)
        }
    }

    func testManualConfirmationDropsDerivationAndRequiresBothEndpointsAgain() throws {
        for legacy in [false, true] {
            var manual = try XCTUnwrap(measurement(legacy: legacy).manualMeasurement(for: "rise"))
            XCTAssertTrue(manual.apply(calculate(manual), for: manual.calculationRevision))
            let crotch = manual.displayLandmarks.points[1].point
            let chosen = ImagePoint(x: 0.53, y: 0.5)
            XCTAssertTrue(manual.placePoint(displayPoint: chosen, index: 0))
            XCTAssertEqual(manual.landmarks.origin, .manual)
            XCTAssertNil(manual.landmarks.modelVersion)
            XCTAssertEqual(manual.landmarks.points.map(\.id), ["waist_center", "crotch"])
            XCTAssertTrue(manual.landmarks.points.allSatisfy { $0.derivedFrom == nil })
            XCTAssertEqual(manual.landmarks.points.map(\.isVisible), [true, false])
            XCTAssertEqual(calculate(manual).values.first?.failure, .occludedLandmark)
            XCTAssertFalse(manual.placePoint(displayPoint: chosen, index: 2))
            XCTAssertTrue(manual.placePoint(displayPoint: crotch, index: 1))
            let direct = calculate(manual)
            XCTAssertEqual(direct.values.first?.status, .valid)
            let resultCenter = try XCTUnwrap(direct.values.first?.points.first)
            XCTAssertEqual(resultCenter.imagePoint, chosen)
            XCTAssertNotEqual(resultCenter.quality.method, .spatialAverage)
            XCTAssertNil(resultCenter.sourceLandmarkIDs)
        }
    }

    func testOpeningManualComparisonDoesNotDiscardDuplicateModelEndpoints() throws {
        var record = try measurement().makeRecord()
        record.landmarks.points.append(try XCTUnwrap(record.landmarks.points.first { $0.id == "crotch" }))
        record.result = LiDARMeasurementEngine(options: record.options).measure(frame: record.snapshot.frame,
            landmarks: record.landmarks, definitions: record.definitions)
        XCTAssertEqual(record.result.values.first?.failure, .duplicateLandmark)
        let model = AutomaticMeasurement(record: record)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "rise"))
        XCTAssertEqual(calculate(manual).values.first?.failure, .duplicateLandmark)
        XCTAssertEqual(manual.landmarks.origin, .model)
        // Explicit manual confirmation may replace malformed model input, but
        // merely opening the editor must not turn that input into a valid result.
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.5), index: 0))
        XCTAssertEqual(manual.landmarks.origin, .manual)
        XCTAssertEqual(calculate(manual).values.first?.failure, .occludedLandmark)
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.5 + 0.3 / 1.15), index: 1))
        XCTAssertEqual(calculate(manual).values.first?.status, .valid)
    }

    func testArchiveReloadRetainsDerivationQualityAndCorrectReplay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        let model = measurement()
        let record = try model.makeRecord()
        _ = try await archive.save(record)
        let loaded = try await archive.load(record.id)
        XCTAssertEqual(try center(in: loaded.landmarks).derivedFrom, ["waist_left", "waist_right"])
        let resolved = try XCTUnwrap(loaded.result.values.first?.points.first)
        XCTAssertEqual(resolved.quality.method, .spatialAverage)
        XCTAssertEqual(resolved.sourceLandmarkIDs, ["waist_left", "waist_right"])
        var reopened = AutomaticMeasurement(record: loaded)
        let replay = LiDARMeasurementEngine(options: loaded.options).measure(frame: loaded.snapshot.frame,
            landmarks: loaded.landmarks, definitions: loaded.definitions)
        XCTAssertTrue(reopened.apply(replay))
        XCTAssertEqual(try XCTUnwrap(reopened.result.values.first?.meters), 0.3, accuracy: 0.000001)
        XCTAssertEqual(try center(in: reopened.displayLandmarks).point.x, 0.5, accuracy: 0.000001)
    }

    func testLegacyRecordWithLostSourcePointsFailsInsteadOfReusingWrongMidpoint() throws {
        var record = try measurement(legacy: true).makeRecord()
        record.landmarks.points.removeAll { $0.id == "waist_left" || $0.id == "waist_right" }
        var model = AutomaticMeasurement(record: record)
        let replay = LiDARMeasurementEngine(options: record.options).measure(frame: record.snapshot.frame,
            landmarks: record.landmarks, definitions: record.definitions)
        XCTAssertTrue(model.apply(replay))
        XCTAssertEqual(model.result.values.first?.failure, .missingLandmark)
        XCTAssertNil(model.result.values.first?.meters)
        XCTAssertFalse(try center(in: model.displayLandmarks).isVisible)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "rise"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.5), index: 0))
        XCTAssertTrue(manual.placePoint(displayPoint: record.landmarks.points[1].point, index: 1))
        XCTAssertEqual(calculate(manual).values.first?.status, .valid)
    }
}
