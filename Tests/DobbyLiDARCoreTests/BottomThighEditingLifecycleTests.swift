import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Frozen synthetic captures verify editing and persistence, not sensor accuracy.
@MainActor
final class BottomThighEditingLifecycleTests: XCTestCase {
    private func automatic(validDepth: Bool = true) throws -> AutomaticMeasurement {
        let size = PixelSize(width: 256, height: 192)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1,
            capturedAt: .distantPast, imageSize: .init(width: 640, height: 480),
            intrinsics: .init(fx: 600, fy: 600, cx: 320, cy: 240,
                              referenceSize: .init(width: 640, height: 480)),
            depth: .init(size: size, values: Array(repeating: 1, count: size.width * size.height),
                         confidence: validDepth ? Array(repeating: 2, count: size.width * size.height) : nil),
            source: .synthetic, orientation: .up)
        var pixels = Array(repeating: UInt8(0), count: size.width * size.height)
        for y in 20..<174 { for x in 50..<206 { pixels[y * size.width + x] = 1 } }
        let coordinates: [(String, Double, Double)] = [
            ("waist_left", 0.3, 0.2), ("waist_right", 0.7, 0.2), ("crotch", 0.5, 0.5),
            ("hem_left_outer", 0.3, 0.85), ("hem_left_inner", 0.45, 0.85),
            ("hem_right_inner", 0.55, 0.85), ("hem_right_outer", 0.7, 0.85),
            ("waist_front_center", 0.5, 0.23)
        ]
        let points = BottomLandmarkSchema.addingRightThighCalculationPoint(to: coordinates.map {
            .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: 0.95)
        })
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: AutomaticGarmentKind.bottoms.modelVersion,
            points: points, mask: .init(size: size, values: pixels), garmentKind: .bottoms)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_bottom8.json")
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf: url))
        let definitions = schema.currentMeasurementDefinitions
        var options = MeasurementOptions(); options.calculationMode = .garmentPlane
        let result = MeasurementCalculator.measure(frame: frame, landmarks: landmarks,
            definitions: definitions, options: options)
        return .init(output: .init(runID: UUID(), snapshot: .init(frame: frame, imageJPEG: Data([1])),
            landmarks: landmarks, result: result, definitions: definitions, options: options,
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    private func recalculate(_ model: inout AutomaticMeasurement) {
        let result = MeasurementCalculator.measure(frame: model.snapshot.frame, landmarks: model.calculationLandmarks,
            definitions: model.definitions, options: model.options)
        XCTAssertTrue(model.apply(result, for: model.calculationRevision))
    }

    private func thigh(_ model: AutomaticMeasurement) throws -> MeasurementValue {
        try XCTUnwrap(model.result.values.first { $0.id == "bottom.thighWidthRight" })
    }

    func testResolvedThighIsDraggableAndManualOverrideSurvivesParentEditsAndReset() throws {
        var model = try automatic()
        let original = try thigh(model)
        let automaticPosition = try XCTUnwrap(original.points.first { $0.id == "thigh_right" })
        let handle = try XCTUnwrap(model.visibleEditableLandmarks.points.first { $0.id == "thigh_right" })
        XCTAssertTrue(handle.isVisible)
        XCTAssertEqual(handle.point, automaticPosition.imagePoint)
        XCTAssertEqual(model.visibleValues.map(\.title), ["총장", "허리", "밑위", "허벅지", "밑단"])
        XCTAssertEqual(model.landmarks.points.filter { $0.id != "thigh_right" }.count, 8)

        let manualPosition = ImagePoint(x: 0.73, y: 0.52)
        XCTAssertTrue(model.placePoint(originalPoint: manualPosition, id: "thigh_right"))
        XCTAssertTrue(model.needsRecalculation)
        XCTAssertThrowsError(try model.makeRecord(), "An old result cannot be saved after a drag")
        let manual = try XCTUnwrap(model.calculationLandmarks.points.first { $0.id == "thigh_right" })
        XCTAssertNil(manual.contourRule); XCTAssertNil(manual.derivedFrom); XCTAssertNil(manual.confidence)
        XCTAssertEqual(manual.origin, .manual)
        recalculate(&model)
        let edited = try thigh(model)
        XCTAssertNotEqual(edited.meters, original.meters)
        XCTAssertEqual(edited.points.last?.quality.method, .garmentPlane)
        XCTAssertEqual(edited.points.last?.imagePoint, manualPosition)
        for previous in model.originalResult.values where previous.id != original.id {
            XCTAssertEqual(model.result.values.first { $0.id == previous.id }?.meters, previous.meters)
        }
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.69, y: 0.22), id: "waist_right"))
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.51, y: 0.49), id: "crotch"))
        recalculate(&model)
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "thigh_right" }?.point, manualPosition)
        XCTAssertNotEqual(try thigh(model).meters, edited.meters)

        model.resetPointAdjustments()
        recalculate(&model)
        XCTAssertTrue(model.editedPointIDs.isEmpty)
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "thigh_right" }?.contourRule,
                       .waistParallelRightThighMaskV1)
        XCTAssertEqual(try thigh(model).meters, original.meters)
    }

    func testAutomaticThighRecomputesAfterEachParentEditWithoutBecomingManualOverride() throws {
        for (id, position) in [("waist_left", ImagePoint(x: 0.31, y: 0.23)),
                               ("waist_right", ImagePoint(x: 0.69, y: 0.23)),
                               ("crotch", ImagePoint(x: 0.51, y: 0.49))] {
            var model = try automatic()
            let original = try thigh(model).points.last?.imagePoint
            XCTAssertTrue(model.placePoint(originalPoint: position, id: id))
            XCTAssertFalse(model.visibleEditableLandmarks.points.contains { $0.id == "thigh_right" && $0.isVisible })
            recalculate(&model)
            XCTAssertNotEqual(try thigh(model).points.last?.imagePoint, original)
            XCTAssertFalse(model.editedPointIDs.contains("thigh_right"))
            XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "thigh_right" }?.contourRule,
                           .waistParallelRightThighMaskV1)
        }
    }

    func testArchiveReplayPreservesManualThighAndAutomaticBaselineForReset() async throws {
        var model = try automatic()
        let automaticMeters = try thigh(model).meters
        let coordinate = ImagePoint(x: 0.72, y: 0.51)
        XCTAssertTrue(model.placePoint(originalPoint: coordinate, id: "thigh_right"))
        recalculate(&model)
        try model.setReference(25.5, for: "bottom.thighWidthRight")
        let record = try model.makeRecord()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thigh-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        _ = try await archive.save(record)
        let loaded = try await archive.load(record.id)
        var reopened = AutomaticMeasurement(record: loaded)
        XCTAssertEqual(reopened.editedPointIDs, ["thigh_right"])
        XCTAssertEqual(reopened.calculationLandmarks.points.first { $0.id == "thigh_right" }?.point, coordinate)
        XCTAssertEqual(reopened.referenceByDefinitionCentimeters["bottom.thighWidthRight"], 25.5)
        XCTAssertEqual(try thigh(reopened).meters, try thigh(model).meters)
        let replay = await MeasurementPipeline().measure(snapshot: loaded.snapshot, landmarks: loaded.landmarks,
            definitions: loaded.definitions, options: loaded.options)
        XCTAssertEqual(replay.values.first { $0.id == "bottom.thighWidthRight" }?.meters, try thigh(model).meters)
        reopened.resetPointAdjustments()
        recalculate(&reopened)
        XCTAssertEqual(try thigh(reopened).meters, automaticMeters)
        XCTAssertEqual(reopened.calculationLandmarks.points.first { $0.id == "waist_front_center" }?.point,
                       .init(x: 0.5, y: 0.23))
    }

    func testFailedPlaneDoesNotExposeCrotchHintAsDraggableThigh() throws {
        let model = try automatic(validDepth: false)
        XCTAssertNil(try thigh(model).meters)
        XCTAssertFalse(model.displayLandmarks.points.contains { $0.id == "thigh_right" && $0.isVisible })
        XCTAssertFalse(model.visibleEditableLandmarks.points.contains { $0.id == "thigh_right" && $0.isVisible })
    }
}
