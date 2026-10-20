import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Synthetic contract fixtures; these do not establish garment detection or physical LiDAR accuracy.
final class GarmentValidationDiagnosticsTests: XCTestCase {
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
    }

    private func scene(pointA: ImagePoint = .init(x: 0.5, y: 0.5),
                       confidenceA: Double = 0.95,
                       policy: GarmentMaskAssociationPolicy = .strict) throws -> Scene {
        let size = PixelSize(width: 100, height: 100)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1,
            capturedAt: Date(timeIntervalSince1970: 1), imageSize: size,
            intrinsics: .init(fx: 100, fy: 100, cx: 50, cy: 50, referenceSize: size),
            depth: .init(size: size, values: .init(repeating: 1, count: 10_000),
                         confidence: .init(repeating: 2, count: 10_000)),
            source: .synthetic, orientation: .right)
        var maskValues = [UInt8](repeating: 0, count: 10_000)
        for y in 20..<80 { for x in 20..<80 { maskValues[y * 100 + x] = 1 } }
        // No mask sample is within the association radius of A=(50,50), but
        // the unchanged depth radius of three still includes a supported ring.
        for y in 48...52 { for x in 48...52 { maskValues[y * 100 + x] = 0 } }
        let mask = GarmentMask(size: size, values: maskValues)
        let raw: [GarmentLandmark] = [
            .init(id: "A", point: pointA, confidence: confidenceA),
            .init(id: "B", point: .init(x: 0.3, y: 0.3), confidence: 0.95),
            .init(id: "C", point: .init(x: 0.7, y: 0.3), confidence: 0.95),
            .init(id: "D", point: .init(x: 0.7, y: 0.7), confidence: 0.95)
        ]
        let selection = try GarmentMaskAssociation.select(masks: [mask], points: raw,
            imageSize: size, policy: policy)
        XCTAssertEqual(selection.mask, mask)
        let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: frame.orientation,
            selectedPoseOrientation: frame.orientation, associationPolicy: selection.policy,
            rawPoints: raw, pointAssessments: selection.pointAssessments,
            poseAttempts: [.init(orientation: frame.orientation, rawPoints: raw,
                                associationPolicy: selection.policy,
                                pointAssessments: selection.pointAssessments)])
        return .init(frame: frame, landmarks: .init(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: "synthetic-diagnostics", points: selection.validatedPoints(raw),
            mask: selection.mask, recognitionDiagnostics: diagnostics))
    }

    private func result(_ scene: Scene, definitions: [MeasurementDefinition] = [.testDistance]) -> GarmentMeasurementResult {
        LiDARMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks, definitions: definitions)
    }

    private func model(_ scene: Scene) -> AutomaticMeasurement {
        .init(output: .init(runID: UUID(), snapshot: .init(frame: scene.frame, imageJPEG: Data([1, 2, 3])),
            landmarks: scene.landmarks, result: result(scene), definitions: [.testDistance], options: .init(),
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2)))
    }

    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testLegacyArchiveWithoutRecognitionDiagnosticsOrPointFailuresStillDecodes() throws {
        var scene = try scene()
        for y in 47...53 { for x in 47...53 { scene.frame.depth.values[y * 100 + x] = 0 } }
        let record = try model(scene).makeRecord()
        XCTAssertFalse(record.result.values.first?.pointFailures?.isEmpty ?? true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes(record)) as? [String: Any])
        var landmarks = try XCTUnwrap(json["landmarks"] as? [String: Any])
        landmarks.removeValue(forKey: "recognitionDiagnostics")
        json["landmarks"] = landmarks
        var result = try XCTUnwrap(json["result"] as? [String: Any])
        var values = try XCTUnwrap(result["values"] as? [[String: Any]])
        for index in values.indices { values[index].removeValue(forKey: "pointFailures") }
        result["values"] = values
        json["result"] = result
        let decoded = try JSONDecoder().decode(SavedMeasurement.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.landmarks.recognitionDiagnostics)
        XCTAssertTrue(decoded.result.values.allSatisfy { $0.pointFailures == nil })
        XCTAssertEqual(decoded.result.values.first?.status, record.result.values.first?.status)
        XCTAssertEqual(decoded.landmarks.points.map(\.point), record.landmarks.points.map(\.point))
    }

    func testArchiveAndManualEditPreserveUntouchedAutomaticRecognitionEvidence() throws {
        let scene = try scene()
        let originalDiagnostics = try bytes(XCTUnwrap(scene.landmarks.recognitionDiagnostics))
        let initial = try model(scene).makeRecord()
        let restored = try JSONDecoder().decode(SavedMeasurement.self, from: bytes(initial))
        XCTAssertEqual(try bytes(XCTUnwrap(restored.landmarks.recognitionDiagnostics)), originalDiagnostics)

        var edited = AutomaticMeasurement(record: restored)
        let target = ImagePoint(x: 0.4, y: 0.5)
        XCTAssertTrue(edited.placePoint(originalPoint: target, id: "A"))
        let recalculated = LiDARMeasurementEngine().measure(frame: edited.snapshot.frame,
            landmarks: edited.calculationLandmarks, definitions: edited.definitions)
        XCTAssertEqual(recalculated.values.first?.status, .valid)
        XCTAssertTrue(recalculated.values.first?.pointFailures?.isEmpty ?? true)
        XCTAssertTrue(edited.apply(recalculated, for: edited.calculationRevision))
        let saved = try JSONDecoder().decode(SavedMeasurement.self, from: bytes(edited.makeRecord()))
        let original = try XCTUnwrap(saved.originalAutomaticLandmarks)
        XCTAssertEqual(try bytes(XCTUnwrap(original.recognitionDiagnostics)), originalDiagnostics)
        XCTAssertEqual(original.points.first { $0.id == "A" }?.point, scene.landmarks.points.first?.point)
        XCTAssertEqual(saved.landmarks.points.first { $0.id == "A" }?.point, target)
        XCTAssertEqual(saved.landmarks.points.first { $0.id == "A" }?.origin, .manual)
        let reopened = AutomaticMeasurement(record: saved)
        XCTAssertEqual(reopened.calculationLandmarks.points.first { $0.id == "A" }?.point, target)
        XCTAssertEqual(try bytes(XCTUnwrap(reopened.landmarks.recognitionDiagnostics)), originalDiagnostics)
    }

    func testOutsideMaskAssessmentKeepsRawPointAndSupportedDepthRemainsUncertain() throws {
        let scene = try scene()
        let diagnostics = try XCTUnwrap(scene.landmarks.recognitionDiagnostics)
        XCTAssertEqual(diagnostics.pointAssessments.first { $0.landmarkID == "A" }?.status, .outsideMask)
        XCTAssertEqual(try bytes(scene.landmarks.points), try bytes(diagnostics.rawPoints))
        XCTAssertTrue(try XCTUnwrap(scene.landmarks.points.first { $0.id == "A" }).isVisible)
        let value = try XCTUnwrap(result(scene).values.first)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertNil(value.failure)
        XCTAssertTrue(value.pointFailures?.isEmpty ?? true)
        XCTAssertEqual(try XCTUnwrap(value.meters), hypot(0.2, 0.2), accuracy: 0.00001)
        XCTAssertEqual(value.points.first { $0.id == "A" }?.imagePoint, diagnostics.rawPoints.first?.point)
        XCTAssertEqual(scene.landmarks.mask?.values[50 * 100 + 50], 0)
    }

    func testAbsentLocalDepthReportsFailedEndpointWithoutChangingMask() throws {
        var scene = try scene()
        let originalMask = scene.landmarks.mask
        for y in 47...53 { for x in 47...53 { scene.frame.depth.values[y * 100 + x] = 0 } }
        let value = try XCTUnwrap(result(scene).values.first)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertNil(value.meters)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertEqual(value.pointFailures, [.init(landmarkID: "A", reason: .insufficientDepth)])
        XCTAssertEqual(value.points.map(\.id), ["B"])
        XCTAssertEqual(scene.landmarks.mask, originalMask)
        XCTAssertTrue(scene.landmarks.points.first?.isVisible == true)
        let restored = try JSONDecoder().decode(SavedMeasurement.self, from: bytes(model(scene).makeRecord()))
        XCTAssertEqual(restored.result.values.first?.pointFailures, value.pointFailures)
        XCTAssertEqual(restored.landmarks.mask, originalMask)
    }

    func testMaskAssessmentDoesNotPromoteLowModelConfidence() throws {
        let scene = try scene(confidenceA: 0.49)
        let value = try XCTUnwrap(result(scene).values.first)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .lowLandmarkConfidence)
        XCTAssertEqual(value.pointFailures, [.init(landmarkID: "A", reason: .lowLandmarkConfidence)])
        XCTAssertNil(value.meters)
    }

    func testSubjectAssociationNeedsReviewEvenWithCompleteDepthSupport() throws {
        let target = ImagePoint(x: 0.4, y: 0.5)
        let strict = try scene(pointA: target)
        let subject = try scene(pointA: target, policy: .subject)
        XCTAssertEqual(try XCTUnwrap(result(strict).values.first).status, .valid)
        XCTAssertTrue(try XCTUnwrap(subject.landmarks.recognitionDiagnostics).requiresReview)
        let value = try XCTUnwrap(result(subject).values.first)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertNil(value.failure)
        XCTAssertEqual(value.meters, result(strict).values.first?.meters)
    }

    func testFrameMismatchRemainsHardFailureDespiteRecognitionDiagnostics() throws {
        var scene = try scene(policy: .subject)
        scene.landmarks.frameID = UUID()
        let value = try XCTUnwrap(result(scene).values.first)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .frameMismatch)
        XCTAssertNil(value.meters)
        XCTAssertTrue(value.points.isEmpty)
    }

    func testSuccessfulDerivedDepthRecoveryDoesNotRetainFailuresFromAnotherMeasurement() throws {
        var scene = try scene(pointA: .init(x: 0.4, y: 0.5))
        let points: [GarmentLandmark] = [
            .init(id: "neck_left", point: .init(x: 0.4, y: 0.3), confidence: 0.95),
            .init(id: "neck_right", point: .init(x: 0.6, y: 0.3), confidence: 0.95),
            .init(id: "hem_center", point: .init(x: 0.5, y: 0.75), confidence: 0.95),
            .init(id: "neck_center", point: .init(x: 0.5, y: 0.3), confidence: 0.95,
                  derivedFrom: ["neck_left", "neck_right"])
        ]
        scene.landmarks.points = points
        scene.landmarks.modelVersion = AutomaticGarmentKind.legacyTopModelVersion
        scene.landmarks.garmentKind = .top
        scene.landmarks.recognitionDiagnostics = nil
        for centerX in [40, 60] {
            for y in 27...33 { for x in (centerX - 3)...(centerX + 3) { scene.frame.depth.values[y * 100 + x] = 0 } }
        }
        let definitions: [MeasurementDefinition] = [
            .init(id: "neckBoundary", title: "Synthetic neckline", landmarkIDs: ["neck_left", "neck_right"]),
            .init(id: "top.totalLength", title: "Synthetic total", landmarkIDs: ["neck_center", "hem_center"])
        ]
        let values = result(scene, definitions: definitions).values
        XCTAssertEqual(values[0].status, .unavailable)
        XCTAssertEqual(Set(values[0].pointFailures?.map(\.landmarkID) ?? []), ["neck_left", "neck_right"])
        XCTAssertTrue(values[0].pointFailures?.allSatisfy { $0.reason == .insufficientDepth } == true)
        XCTAssertEqual(values[1].status, .uncertain)
        XCTAssertNotNil(values[1].meters)
        XCTAssertEqual(values[1].points.first?.quality.method, .recoveredSpatialAverage)
        XCTAssertTrue(values[1].pointFailures?.isEmpty ?? true)
        XCTAssertNil(values[1].failure)
    }
}
