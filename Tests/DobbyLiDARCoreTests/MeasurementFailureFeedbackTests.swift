import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Synthetic failure-guard evidence; no physical garment accuracy is asserted.
final class MeasurementFailureFeedbackTests: XCTestCase {
    private struct Scene { var frame: MeasurementFrame; var landmarks: GarmentLandmarkSet }
    private func scene(depth: (Int, Int) -> Float = { _, _ in 1.2 },
                       confidence: (Int, Int) -> UInt8 = { _, _ in 2 }) -> Scene {
        let imageSize = PixelSize(width: 800, height: 600), size = PixelSize(width: 80, height: 60)
        let sessionID = UUID(), frameID = UUID()
        let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 1, capturedAt: .distantPast,
            imageSize: imageSize, intrinsics: .init(fx: 600, fy: 600, cx: 400, cy: 300, referenceSize: imageSize),
            depth: .init(size: size, values: (0..<4800).map { depth($0 % 80, $0 / 80) },
                         confidence: (0..<4800).map { confidence($0 % 80, $0 / 80) }),
            source: .synthetic, orientation: .up)
        let mask = GarmentMask(size: size, values: (0..<4800).map {
            (15...65).contains($0 % 80) && (8...52).contains($0 / 80) ? 1 : 0
        })
        let landmarks = GarmentLandmarkSet(sessionID: sessionID, frameID: frameID, origin: .model,
            modelVersion: "synthetic-feedback", points: [
                .init(id: "A", point: .init(x: 0.35, y: 0.4), confidence: 0.9),
                .init(id: "B", point: .init(x: 0.65, y: 0.6), confidence: 0.9)
            ], mask: mask)
        return .init(frame: frame, landmarks: landmarks)
    }
    private func measure(_ scene: Scene, plane: Bool = false,
                         definitions: [MeasurementDefinition] = [.testDistance]) -> [MeasurementValue] {
        if plane {
            return GarmentPlaneMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks,
                                                          definitions: definitions).values
        }
        return LiDARMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks,
                                               definitions: definitions).values
    }
    private func first(_ scene: Scene, plane: Bool = false) throws -> MeasurementValue {
        try XCTUnwrap(measure(scene, plane: plane).first)
    }

    func testUsablePositiveValuesNeverWarnEvenWhenUncertainOrWithStaleDiagnostics() throws {
        var value = try first(scene())
        XCTAssertTrue(value.hasUsableMeasurement)
        for status in [MeasurementStatus.valid, .uncertain] {
            value.status = status
            value.failureContexts = [.init(stage: .garmentPlane, reason: .planeHighResidual, scope: .capture)]
            value.pointFailures = [.init(landmarkID: "A", reason: .insufficientDepth)]
            XCTAssertTrue(value.hasUsableMeasurement)
            XCTAssertNil(value.failureFeedback)
        }
        XCTAssertEqual(value.status, .uncertain, "The display policy must not erase diagnostic status")
    }

    func testMalformedAndContradictoryValuesNeverInventUsableNumbers() {
        for meters in [Double?.none, 0, -1, .infinity, .nan] {
            let value = MeasurementValue(id: "m", title: "길이", meters: meters, status: .valid, failure: nil, points: [])
            XCTAssertFalse(value.hasUsableMeasurement)
            XCTAssertNotNil(value.failureFeedback)
        }
        let unavailable = MeasurementValue(id: "m", title: "길이", meters: 0.5, status: .unavailable, failure: nil, points: [])
        XCTAssertFalse(unavailable.hasUsableMeasurement)
        XCTAssertNotNil(unavailable.failureFeedback)
        let failed = MeasurementValue(id: "m", title: "길이", meters: 0.5, status: .valid, failure: .insufficientDepth, points: [])
        XCTAssertFalse(failed.hasUsableMeasurement)
    }

    func testPerPointDifferentFailuresAreAllRetainedAndDoNotInvalidateOtherMeasurement() throws {
        for plane in [false, true] {
            var scene = scene()
            scene.landmarks.points[0].confidence = 0.49
            scene.landmarks.points[1].isVisible = false
            scene.landmarks.points += [
                .init(id: "C", point: .init(x: 0.4, y: 0.5), confidence: 0.9),
                .init(id: "D", point: .init(x: 0.6, y: 0.5), confidence: 0.9)
            ]
            let values = measure(scene, plane: plane, definitions: [.testDistance,
                .init(id: "ok", title: "정상 항목", landmarkIDs: ["C", "D"])])
            let failed = values[0], feedback = try XCTUnwrap(failed.failureFeedback)
            XCTAssertEqual(failed.failure, .lowLandmarkConfidence)
            XCTAssertEqual(failed.pointFailures?.map(\.landmarkID), ["A", "B"])
            XCTAssertEqual(failed.pointFailures?.compactMap { $0.context?.reason }, [.lowModelConfidence, .hiddenPoint])
            XCTAssertTrue(feedback.reason.contains(MeasurementFailureReason.lowModelConfidence.explanation))
            XCTAssertTrue(feedback.reason.contains(MeasurementFailureReason.hiddenPoint.explanation))
            XCTAssertEqual(feedback.relatedLandmarkIDs, ["A", "B"])
            XCTAssertEqual(feedback.suggestedAction, .editPoints)
            XCTAssertFalse(feedback.isCaptureFailure)
            XCTAssertTrue(values[1].hasUsableMeasurement)
            XCTAssertNil(values[1].failureFeedback)
        }
    }

    func testGlobalFrameCalibrationAndBufferFailuresRemainCaptureScoped() throws {
        var mismatch = scene(); mismatch.landmarks.frameID = UUID()
        var calibration = scene(); calibration.frame.intrinsics.fx = 0
        var malformed = scene(); malformed.frame.depth.values.removeLast()
        var badConfidence = scene(); badConfidence.frame.depth.confidence?[0] = 3
        for (scene, reason) in [(mismatch, MeasurementFailureReason.frameIdentityMismatch),
                                (calibration, .invalidCalibration), (malformed, .malformedDepth),
                                (badConfidence, .malformedConfidence)] {
            for plane in [false, true] {
                let value = try first(scene, plane: plane), feedback = try XCTUnwrap(value.failureFeedback)
                XCTAssertEqual(value.failureContexts?.first?.reason, reason)
                XCTAssertTrue(feedback.isCaptureFailure)
                XCTAssertTrue(feedback.relatedLandmarkIDs.isEmpty)
                XCTAssertNil(value.pointFailures)
                XCTAssertFalse(feedback.reason.contains("어두"))
            }
        }
    }

    func testNoDepthOutOfRangeLowSensorConfidenceAndFewSamplesAreDistinct() throws {
        let noDepth = scene(depth: { _, _ in 0 })
        let farDepth = scene(depth: { _, _ in 4 })
        let lowConfidence = scene(confidence: { _, _ in 0 })
        let few = scene(depth: { x, y in x == 28 && y == 24 ? 1.2 : 0 })
        for (scene, reason) in [(noDepth, MeasurementFailureReason.noDepthSamples),
                                (farDepth, .depthOutsideSupportedRange),
                                (lowConfidence, .lowSensorConfidence), (few, .tooFewDepthSamples)] {
            let value = try first(scene)
            XCTAssertEqual(value.failure, .insufficientDepth)
            XCTAssertEqual(value.pointFailures?.first?.context?.reason, reason)
            XCTAssertNil(value.meters)
            XCTAssertEqual(value.failureFeedback?.suggestedAction, .retake)
        }
    }

    func testLocalClusterOutlierAndSpatialSupportFailuresKeepTheirActualGuardReason() throws {
        let fragmented = scene(depth: { x, y in
            guard (25...31).contains(x), (21...27).contains(y) else { return 1.2 }
            return 1 + Float((y - 21) * 7 + x - 25) * 0.03
        })
        let rejected = scene(depth: { x, y in
            guard (27...29).contains(x), (24...25).contains(y) else { return 0 }
            return (y - 24) * 3 + x - 27 < 4 ? 1.2 : 1.21
        })
        let remotePixels = Set(["25,21", "31,21", "30,21", "31,22", "31,23", "31,24"])
        let remote = scene(depth: { x, y in remotePixels.contains("\(x),\(y)") ? 1.2 : 0 })
        for (scene, reason) in [(fragmented, MeasurementFailureReason.noSupportedDepthCluster),
                                (rejected, .depthOutlierRejection), (remote, .depthSupportTooFar)] {
            let value = try first(scene)
            XCTAssertEqual(value.failure, .insufficientDepth)
            XCTAssertEqual(value.pointFailures?.first?.context?.reason, reason)
            XCTAssertEqual(value.pointFailures?.first?.landmarkID, "A")
            XCTAssertNotNil(value.pointFailures?.first?.context?.evidence)
        }
    }

    func testPlaneMissingConfidenceSparseSupportAndMixedSurfacesAreDistinct() throws {
        var missing = scene(); missing.frame.depth.confidence = nil
        let absent = scene(depth: { _, _ in 0 })
        let low = scene(confidence: { _, _ in 0 })
        let mixed = scene(depth: { x, _ in x < 40 ? 1 : 1.15 })
        var narrow = scene(); narrow.frame.intrinsics.fx = 12_000; narrow.frame.intrinsics.fy = 12_000
        for (scene, reason) in [(missing, MeasurementFailureReason.missingDepthConfidence),
                                (absent, .planeTooFewSamples), (low, .lowSensorConfidence),
                                (mixed, .planeInsufficientInliers), (narrow, .planeNarrowSupport)] {
            let value = try first(scene, plane: true)
            XCTAssertEqual(value.failureContexts?.first?.reason, reason)
            XCTAssertTrue(value.failureFeedback?.isCaptureFailure == true)
            XCTAssertNil(value.meters)
        }
    }

    func testAVFoundationMissingConfidenceAloneDoesNotHideUsableLengthOrCreateFailureFeedback() throws {
        var candidate = scene()
        candidate.frame.source = .avFoundationLiDAR
        candidate.frame.depth.confidence = nil
        let measured = try first(candidate, plane: true)
        XCTAssertEqual(measured.status, .uncertain)
        XCTAssertTrue(measured.hasUsableMeasurement)
        XCTAssertGreaterThan(try XCTUnwrap(measured.meters), 0)
        XCTAssertNil(measured.failure)
        XCTAssertNil(measured.failureContexts)
        XCTAssertNil(measured.failureFeedback)
        XCTAssertTrue(measured.points.allSatisfy { !$0.quality.confidenceAvailable })
    }

    func testAVFoundationWithoutConfidenceReportsActualDepthFailureRatherThanMissingMetadata() throws {
        let absent = scene(depth: { _, _ in 0 })
        let mixed = scene(depth: { x, _ in x < 40 ? 1 : 1.15 })
        for (fixture, reason) in [(absent, MeasurementFailureReason.planeTooFewSamples),
                                  (mixed, .planeInsufficientInliers)] {
            var candidate = fixture
            candidate.frame.source = .avFoundationLiDAR
            candidate.frame.depth.confidence = nil
            let measured = try first(candidate, plane: true)
            let feedback = try XCTUnwrap(measured.failureFeedback)
            XCTAssertEqual(measured.failureContexts?.first?.reason, reason)
            XCTAssertTrue(feedback.reason.contains(reason.explanation))
            XCTAssertFalse(feedback.reason.contains(MeasurementFailureReason.missingDepthConfidence.explanation))
            XCTAssertTrue(feedback.isCaptureFailure)
            XCTAssertEqual(feedback.suggestedAction, .retake)
            XCTAssertNil(measured.meters)
        }
    }

    func testMaskMissingMalformedCoverageAndClippingAreDistinct() throws {
        var missing = scene(); missing.landmarks.mask = nil
        var malformed = scene(); malformed.landmarks.mask?.values[0] = 2
        var coverage = scene(); coverage.landmarks.mask?.values = .init(repeating: 0, count: 4800)
        var clipped = scene()
        for y in 8...52 { clipped.landmarks.mask?.values[y * 80] = 1 }
        for (scene, reason) in [(missing, MeasurementFailureReason.missingMask), (malformed, .malformedMask),
                                (coverage, .maskCoverage), (clipped, .maskClipped)] {
            let value = try first(scene, plane: true)
            XCTAssertEqual(value.failure, .invalidMask)
            XCTAssertEqual(value.failureContexts?.first?.reason, reason)
        }
    }

    func testDuplicateDefinitionZeroDistanceAndDegenerateProjectionHaveExactReasons() throws {
        let duplicate = measure(scene(), definitions: [.testDistance, .testDistance])
        XCTAssertTrue(duplicate.allSatisfy { $0.failureContexts?.first?.reason == .duplicateDefinition })
        for plane in [false, true] {
            var same = scene(); same.landmarks.points[1].point = same.landmarks.points[0].point
            let zero = try first(same, plane: plane)
            XCTAssertEqual(zero.failure, .invalidDefinition)
            XCTAssertEqual(zero.failureContexts?.first?.reason, .zeroLength)
            let axis = measure(same, plane: plane, definitions: [
                .init(id: "axis", title: "투영", landmarkIDs: ["A", "B"],
                      projection: .init(referenceAxisLandmarkIDs: ["A", "B"]))
            ])[0]
            XCTAssertEqual(axis.failureContexts?.first?.reason, .degenerateAxis)
        }
    }

    func testDetailedIntersectionAndContourKeepPublicLegacyFailureType() throws {
        let scene = scene(), mask = try XCTUnwrap(scene.landmarks.mask)
        let plane = try GarmentPlaneGeometry.fit(frame: scene.frame, mask: mask, uprightOrientation: .up)
        let left = Point3D(x: 0, y: 0, z: 1.2), right = Point3D(x: 0.001, y: 0, z: 1.2)
        let hem = Point3D(x: 0, y: 0.3, z: 1.2)
        XCTAssertThrowsError(try TopContourLength.startDetailed(neckLeft: left, neckRight: right, hem: hem,
            mask: mask, frame: scene.frame, plane: plane)) {
            XCTAssertEqual(($0 as? ContextualMeasurementError)?.context.reason, .contourNeckAxisTooShort)
            XCTAssertEqual(($0 as? ContextualMeasurementError)?.context.recovery, .correctTotalLength)
        }
        XCTAssertThrowsError(try TopContourLength.start(neckLeft: left, neckRight: right, hem: hem,
            mask: mask, frame: scene.frame, plane: plane)) {
            XCTAssertEqual($0 as? MeasurementFailure, .contourIntersectionUnavailable)
        }
        var grazing = plane; grazing.normal = .init(x: 1, y: 0, z: 0)
        XCTAssertThrowsError(try GarmentPlaneGeometry.intersectionDetailed(point: .init(x: 0.5, y: 0.5),
            frame: scene.frame, plane: grazing)) {
            XCTAssertEqual(($0 as? ContextualMeasurementError)?.context.reason, .planeViewingAngle)
        }
        XCTAssertThrowsError(try GarmentPlaneGeometry.intersection(point: .init(x: 0.5, y: 0.5),
            frame: scene.frame, plane: grazing)) {
            XCTAssertEqual($0 as? MeasurementFailure, .insufficientGarmentPlane)
        }
    }

    func testOldArchivesDoNotInventDetailedReasonsAndFutureContextCodesStayReadable() throws {
        let old = Data(#"{"id":"test","title":"총장","meters":null,"status":"unavailable","failure":"insufficientGarmentPlane","points":[],"pointFailures":[{"landmarkID":"A","reason":"insufficientDepth"}]}"#.utf8)
        let value = try JSONDecoder().decode(MeasurementValue.self, from: old)
        XCTAssertNil(value.failureContexts)
        XCTAssertNil(value.pointFailures?.first?.context)
        XCTAssertTrue(value.failureFeedback?.reason.contains("세부 원인이 없어요") == true)
        XCTAssertFalse(value.failureFeedback?.reason.contains("각도") == true)
        let future = Data(#"{"stage":"future-stage","reason":"future-reason","scope":"future-scope","recovery":"future-action","evidence":{"samples":3}}"#.utf8)
        let context = try JSONDecoder().decode(MeasurementFailureContext.self, from: future)
        XCTAssertEqual(context.stage, .unknown); XCTAssertEqual(context.reason, .unknown)
        XCTAssertEqual(context.scope, .unknown); XCTAssertEqual(context.recovery, .none)
        XCTAssertEqual(context.evidence?["samples"], 3)
        let empty = try JSONDecoder().decode(MeasurementFailureContext.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.reason, .unknown)
        let actual = try first(scene(confidence: { _, _ in 0 }), plane: true)
        let restored = try JSONDecoder().decode(MeasurementValue.self, from: JSONEncoder().encode(actual))
        XCTAssertEqual(restored.failureContexts, actual.failureContexts)
        XCTAssertEqual(restored.failureFeedback, actual.failureFeedback)
    }
}
