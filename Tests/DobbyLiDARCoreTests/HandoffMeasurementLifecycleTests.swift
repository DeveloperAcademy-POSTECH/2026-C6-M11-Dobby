import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Synthetic frozen-frame contracts. These tests do not establish physical cm accuracy.
@MainActor
final class HandoffMeasurementLifecycleTests: XCTestCase {
    private func fixture(top: Bool = false) -> (CaptureSnapshot, GarmentLandmarkSet, [MeasurementDefinition]) {
        let size = PixelSize(width: 64, height: 48)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 10,
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000), imageSize: .init(width: 640, height: 480),
            intrinsics: .init(fx: 600, fy: 600, cx: 320, cy: 240, referenceSize: .init(width: 640, height: 480)),
            depth: .init(size: size, values: Array(repeating: 1, count: size.width * size.height),
                         confidence: Array(repeating: 2, count: size.width * size.height)),
            source: .sceneDepth, orientation: .up)
        var mask = Array(repeating: UInt8(0), count: size.width * size.height)
        for y in 8..<40 { for x in 10..<54 { mask[y * size.width + x] = 1 } }
        let points: [GarmentLandmark] = top ? [
            .init(id: "neck_left", point: .init(x: 0.4, y: 0.25), confidence: 0.95),
            .init(id: "neck_right", point: .init(x: 0.6, y: 0.25), confidence: 0.95),
            .init(id: "hem_center", point: .init(x: 0.5, y: 0.75), confidence: 0.95),
            .init(id: "top_length_start", point: .init(x: 0.5, y: 0.75), confidence: nil,
                  isVisible: false, contourRule: .neckPerpendicularMaskV1)
        ] : [
            .init(id: "A", point: .init(x: 0.3, y: 0.5), confidence: 0.95),
            .init(id: "B", point: .init(x: 0.7, y: 0.5), confidence: 0.95)
        ]
        let set = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID, origin: .model,
            modelVersion: top ? AutomaticGarmentKind.top.modelVersion : "replay-fixture",
            points: points, mask: .init(size: size, values: mask), garmentKind: top ? .top : nil)
        let definitions: [MeasurementDefinition] = top
            ? [.init(id: "top.totalLength", title: "총장", landmarkIDs: ["top_length_start", "hem_center"])]
            : [.testDistance]
        return (.init(frame: frame, imageJPEG: Data([0xff, 0xd8, 0xff, 0xd9])), set, definitions)
    }

    private func automatic() -> AutomaticMeasurement {
        let (snapshot, set, definitions) = fixture(top: true)
        var options = MeasurementOptions(); options.calculationMode = .garmentPlane
        let result = MeasurementCalculator.measure(frame: snapshot.frame, landmarks: set,
            definitions: definitions, options: options)
        return .init(output: .init(runID: UUID(), snapshot: snapshot, landmarks: set, result: result,
            definitions: definitions, options: options,
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    func testLegacyMissingAndNullModeDecodeLocallyButUnknownModeIsRejected() throws {
        let encoded = try JSONEncoder().encode(MeasurementOptions())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for value: Any? in [nil, NSNull()] {
            object["calculationMode"] = value
            let options = try JSONDecoder().decode(MeasurementOptions.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(options.effectiveCalculationMode, .legacyLocal)
        }
        object["calculationMode"] = "future-plane-v99"
        XCTAssertThrowsError(try JSONDecoder().decode(MeasurementOptions.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testBothPipelineEntrypointsKeepExplicitPlaneMode() async throws {
        let (snapshot, landmarks, definitions) = fixture()
        var options = MeasurementOptions(); options.calculationMode = .garmentPlane
        let pipeline = MeasurementPipeline()
        let direct = await pipeline.measure(snapshot: snapshot, landmarks: landmarks,
            definitions: definitions, options: options)
        let provider = try await pipeline.measure(snapshot: snapshot,
            provider: HandoffFrozenProvider(points: landmarks), definitions: definitions, options: options)
        XCTAssertEqual(direct.algorithmVersion, GarmentPlaneMeasurementEngine.algorithmVersion)
        XCTAssertNotNil(direct.values.first?.meters)
        XCTAssertEqual(direct.values.first?.meters, provider.values.first?.meters)
        XCTAssertEqual(direct.values.first?.points.first?.quality.method, .garmentPlane)
    }

    func testNewAutomaticCaptureSelectsPlaneAndRejectsAResultFromAnotherEngine() async throws {
        let (snapshot, original, definitions) = fixture()
        var points = original
        points.garmentKind = .bottoms
        points.modelVersion = AutomaticGarmentKind.bottoms.modelVersion
        var published: [UUID] = []
        let workflow = AutomaticMeasurementWorkflow(camera: HandoffFrozenCamera(snapshot: snapshot),
            landmarks: HandoffFrozenProvider(points: points), definitions: definitions,
            onSnapshot: { published.append($0.frame.frameID) })
        let output = try await workflow.run(orientation: .up)
        XCTAssertEqual(published, [snapshot.frame.frameID])
        XCTAssertEqual(output.options.effectiveCalculationMode, .garmentPlane)
        XCTAssertEqual(output.result.algorithmVersion, GarmentPlaneMeasurementEngine.algorithmVersion)
        var model = AutomaticMeasurement(output: output)
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.31, y: 0.5), id: "A"))
        let wrong = LiDARMeasurementEngine().measure(frame: snapshot.frame,
            landmarks: model.calculationLandmarks, definitions: definitions)
        XCTAssertFalse(model.apply(wrong, for: model.calculationRevision))
        XCTAssertTrue(model.needsRecalculation)
    }

    func testContourDisplayManualOverrideParentEditAndResetUseSameMode() throws {
        var model = automatic()
        let total = try XCTUnwrap(model.result.values.first)
        XCTAssertNotNil(total.meters)
        XCTAssertEqual(total.points.first?.quality.method, .contourIntersection)
        XCTAssertTrue(model.displayLandmarks.points.contains { $0.id == "top_length_start" && $0.isVisible })
        XCTAssertTrue(model.canCorrectTotalLength)
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.5, y: 0.24), id: "top_length_start"))
        XCTAssertNil(model.calculationLandmarks.points.first { $0.id == "top_length_start" }?.contourRule)
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.42, y: 0.26), id: "neck_left"))
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "top_length_start" }?.point,
                       .init(x: 0.5, y: 0.24), "Parent edits must not overwrite an explicitly confirmed endpoint")
        let replay = MeasurementCalculator.measure(frame: model.snapshot.frame, landmarks: model.calculationLandmarks,
            definitions: model.definitions, options: model.options)
        XCTAssertTrue(model.apply(replay, for: model.calculationRevision))
        XCTAssertEqual(replay.algorithmVersion, GarmentPlaneMeasurementEngine.algorithmVersion)
        let record = try model.makeRecord()
        let restored = AutomaticMeasurement(record: try JSONDecoder().decode(SavedMeasurement.self,
            from: JSONEncoder().encode(record)))
        XCTAssertEqual(restored.options.effectiveCalculationMode, .garmentPlane)
        XCTAssertEqual(restored.editedPointIDs, ["top_length_start", "neck_left"])
        model.resetPointAdjustments()
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "top_length_start" }?.contourRule,
                       .neckPerpendicularMaskV1)
        XCTAssertEqual(model.options.effectiveCalculationMode, .garmentPlane)
    }

    func testParentEditInvalidatesContourWithoutTurningItIntoAnAverageOrDirectEdit() throws {
        var model = automatic()
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.45, y: 0.3), id: "neck_left"))
        let point = try XCTUnwrap(model.calculationLandmarks.points.first { $0.id == "top_length_start" })
        XCTAssertEqual(point.contourRule, .neckPerpendicularMaskV1)
        XCTAssertNil(point.derivedFrom)
        XCTAssertFalse(model.editedPointIDs.contains("top_length_start"))
        XCTAssertFalse(model.visibleEditableLandmarks.points.contains {
            $0.id == "top_length_start" && $0.isVisible
        }, "A pending contour must not expose the hem hint as a detected top point")
        let replay = MeasurementCalculator.measure(frame: model.snapshot.frame, landmarks: model.calculationLandmarks,
            definitions: model.definitions, options: model.options)
        XCTAssertNotNil(replay.values.first?.meters)
    }

    func testFailedPlaneDoesNotDisplayTheHemHintAsATotalLengthStart() {
        var (snapshot, landmarks, definitions) = fixture(top: true)
        snapshot.frame.depth.confidence = nil
        var options = MeasurementOptions(); options.calculationMode = .garmentPlane
        let result = MeasurementCalculator.measure(frame: snapshot.frame, landmarks: landmarks,
            definitions: definitions, options: options)
        let model = AutomaticMeasurement(output: .init(runID: UUID(), snapshot: snapshot, landmarks: landmarks,
            result: result, definitions: definitions, options: options,
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
        XCTAssertNil(result.values.first?.meters)
        XCTAssertTrue(model.canCorrectTotalLength)
        XCTAssertFalse(model.visibleEditableLandmarks.points.contains {
            $0.id == "top_length_start" && $0.isVisible
        })
    }

    func testBothTotalEndpointsMustBeConfirmedAndContourRuleIsCleared() throws {
        var model = automatic()
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.totalLength"))
        XCTAssertFalse(model.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.23), index: 0))
        XCTAssertFalse(model.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.76), index: 1))
        XCTAssertTrue(model.applyTotalLengthCorrection(from: manual))
        XCTAssertEqual(model.options.effectiveCalculationMode, .garmentPlane)
        for id in ["top_length_start", "hem_center"] {
            let point = try XCTUnwrap(model.calculationLandmarks.points.first { $0.id == id })
            XCTAssertEqual(point.origin, .manual); XCTAssertNil(point.contourRule); XCTAssertNil(point.derivedFrom)
        }
    }

    func testArchiveReplayAndMixedReportRetainCalculationModes() async throws {
        let model = automatic()
        let record = try model.makeRecord()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        _ = try await archive.save(record)
        let loaded = try await archive.load(record.id)
        let replay = await MeasurementPipeline().measure(snapshot: loaded.snapshot, landmarks: loaded.landmarks,
            definitions: loaded.definitions, options: loaded.options)
        XCTAssertEqual(replay.algorithmVersion, record.result.algorithmVersion)
        XCTAssertEqual(replay.values.first?.meters, record.result.values.first?.meters)

        let (snapshot, landmarks, definitions) = fixture()
        let legacy = MeasurementCalculator.measure(frame: snapshot.frame, landmarks: landmarks,
            definitions: definitions, options: .init())
        let oldRecord = SavedMeasurement(id: UUID(), savedAt: .now, snapshot: snapshot, landmarks: landmarks,
            definitions: definitions, result: legacy, referenceCentimeters: nil, options: .init())
        var report = MeasurementValidationReportBuilder(); report.add(record); report.add(oldRecord)
        let output = report.report()
        XCTAssertTrue(output.algorithmVersion.contains(LiDARMeasurementEngine.algorithmVersion))
        XCTAssertTrue(output.algorithmVersion.contains(GarmentPlaneMeasurementEngine.algorithmVersion))
        XCTAssertEqual(output.samples.count, 2)
    }
}

private struct HandoffFrozenProvider: GarmentLandmarkProviding {
    let points: GarmentLandmarkSet
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet { points }
}

@MainActor
private struct HandoffFrozenCamera: CaptureSnapshotProviding {
    let snapshot: CaptureSnapshot
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot { snapshot }
}
