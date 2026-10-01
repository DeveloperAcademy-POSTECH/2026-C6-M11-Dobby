import Foundation
import XCTest
@testable import DobbyLiDARCore

final class TopMeasurementLifecycleTests: XCTestCase {
    private func model() -> AutomaticMeasurement {
        let size = PixelSize(width: 200, height: 200)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 200, fy: 200, cx: 100, cy: 100, referenceSize: size),
            depth: .init(size: size, values: .init(repeating: 1, count: 40_000),
                         confidence: .init(repeating: 2, count: 40_000)), source: .synthetic, orientation: .up)
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: "top11-ec1e6b054d59", points: [
                .init(id: "neck_left", point: .init(x: 0.35, y: 0.25), confidence: 1),
                .init(id: "neck_right", point: .init(x: 0.65, y: 0.25), confidence: 1),
                .init(id: "neck_center", point: .init(x: 0.5, y: 0.25), confidence: 1,
                      derivedFrom: ["neck_left", "neck_right"]),
                .init(id: "hem_center", point: .init(x: 0.7, y: 0.8), confidence: 1)
            ], mask: nil)
        let definition = MeasurementDefinition(id: "top.totalLength", title: "총장(목선에 수직)",
            landmarkIDs: ["neck_center", "hem_center"],
            projection: .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"]))
        let snapshot = CaptureSnapshot(frame: frame, imageJPEG: Data([1, 2, 3]))
        let options = MeasurementOptions()
        let result = LiDARMeasurementEngine(options: options).measure(frame: frame, landmarks: landmarks,
                                                                      definitions: [definition])
        return .init(output: .init(runID: UUID(), snapshot: snapshot, landmarks: landmarks,
            result: result, definitions: [definition], options: options,
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now), context: .init(category: .top))
    }

    private func calculate(_ manual: ManualMeasurement) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: manual.options).measure(frame: manual.snapshot.frame,
            landmarks: manual.landmarks, definitions: [manual.definition])
    }

    func testManualComparisonKeepsProjectionAxisAndDisplaysResolvedEndpoint() throws {
        let automatic = model()
        var manual = try XCTUnwrap(automatic.manualMeasurement(for: "top.totalLength"))
        XCTAssertEqual(Set(manual.landmarks.points.map(\.id)),
                       Set(["neck_center", "hem_center", "neck_left", "neck_right"]))
        let result = calculate(manual)
        XCTAssertEqual(try XCTUnwrap(result.values.first?.meters), 0.55, accuracy: 0.000_001)
        XCTAssertTrue(manual.apply(result, for: manual.calculationRevision))
        let displayed = try XCTUnwrap(manual.displayLandmarks.points.first { $0.id == "hem_center" })
        XCTAssertEqual(displayed.point.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(displayed.point.y, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(manual.landmarks.points.first { $0.id == "hem_center" }).point.x, 0.7)
        XCTAssertEqual(manual.displayLandmarks.points.count, 2)
    }

    func testManualConfirmationUsesDistinctStraightDefinitionAndRequiresBothPoints() throws {
        var manual = try XCTUnwrap(model().manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.setReferenceCentimeters(55))
        XCTAssertTrue(manual.apply(calculate(manual), for: manual.calculationRevision))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.51, y: 0.25), index: 0))
        XCTAssertNil(manual.definition.projection)
        XCTAssertEqual(manual.definition.id, "top.totalLength.manualStraight")
        XCTAssertTrue(manual.definition.title.contains("수동 직선"))
        XCTAssertNil(manual.referenceCentimeters)
        XCTAssertEqual(manual.landmarks.origin, .manual)
        XCTAssertNil(manual.landmarks.modelVersion)
        XCTAssertEqual(manual.landmarks.points.map(\.id), ["neck_center", "hem_center"])
        XCTAssertEqual(manual.landmarks.points.map(\.isVisible), [true, false])
        XCTAssertEqual(calculate(manual).values.first?.failure, .occludedLandmark)
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.8), index: 1))
        let result = calculate(manual)
        XCTAssertEqual(result.values.first?.status, .valid)
        XCTAssertNotEqual(result.values.first?.points.last?.quality.method, .axisProjection)
        XCTAssertTrue(manual.apply(result, for: manual.calculationRevision))
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(manual.makeRecord()))
        XCTAssertNil(decoded.definitions.first?.projection)
        XCTAssertEqual(decoded.definitions.first?.id, "top.totalLength.manualStraight")
    }

    func testArchiveRoundTripPreservesProjectionAndOriginalPrediction() throws {
        let automatic = model()
        let reopened = AutomaticMeasurement(record: try JSONDecoder().decode(SavedMeasurement.self,
            from: JSONEncoder().encode(automatic.makeRecord())))
        XCTAssertEqual(reopened.definitions.first?.projection?.referenceAxisLandmarkIDs,
                       ["neck_left", "neck_right"])
        XCTAssertEqual(try XCTUnwrap(reopened.landmarks.points.first { $0.id == "hem_center" }).point.x, 0.7)
        XCTAssertEqual(reopened.result.values.first?.points.last?.quality.method, .axisProjection)
        XCTAssertEqual(reopened.context.category, .top)
        let replay = LiDARMeasurementEngine(options: reopened.options).measure(frame: reopened.snapshot.frame,
            landmarks: reopened.landmarks, definitions: reopened.definitions)
        XCTAssertEqual(try XCTUnwrap(replay.values.first?.meters), 0.55, accuracy: 0.000_001)
    }
}
