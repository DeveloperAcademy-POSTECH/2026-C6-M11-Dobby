import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic camera geometry only: these checks cannot establish iPhone/tape accuracy.
final class GarmentPlaneIntegrationTests: XCTestCase {
    private struct Scene { var frame: MeasurementFrame; var landmarks: GarmentLandmarkSet }
    private func unit(_ p: Point3D) -> Point3D {
        let l = hypot(hypot(p.x, p.y), p.z)
        return .init(x: p.x / l, y: p.y / l, z: p.z / l)
    }
    private func dot(_ a: Point3D, _ b: Point3D) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private func scene(normal: Point3D = .init(x: 0, y: 0, z: 1), offset: Double = -1.2,
                       depthSize: PixelSize = .init(width: 160, height: 120),
                       maskSize: PixelSize = .init(width: 320, height: 240),
                       maskAt: (Double, Double) -> Bool = { $0 >= 0.2 && $0 <= 0.8 && $1 >= 0.15 && $1 <= 0.85 },
                       modify: (Int, Int, Float) -> Float = { _, _, z in z },
                       confidence: (Int, Int) -> UInt8 = { _, _ in 2 }) -> Scene {
        let ids = (UUID(), UUID()), imageSize = PixelSize(width: 800, height: 600)
        var depths: [Float] = [], levels: [UInt8] = []
        for y in 0..<depthSize.height {
            for x in 0..<depthSize.width {
                let ray = Point3D(x: (Double(x) / Double(depthSize.width) * 800 - 400) / 600,
                                  y: (Double(y) / Double(depthSize.height) * 600 - 300) / 600, z: 1)
                depths.append(modify(x, y, Float(-offset / dot(normal, ray))))
                levels.append(confidence(x, y))
            }
        }
        let mask = GarmentMask(size: maskSize, values: (0..<(maskSize.width * maskSize.height)).map {
            maskAt(Double($0 % maskSize.width) / Double(maskSize.width),
                   Double($0 / maskSize.width) / Double(maskSize.height)) ? 1 : 0
        })
        let frame = MeasurementFrame(sessionID: ids.0, frameID: ids.1, timestamp: 1, capturedAt: .distantPast,
            imageSize: imageSize, intrinsics: .init(fx: 600, fy: 600, cx: 400, cy: 300, referenceSize: imageSize),
            depth: .init(size: depthSize, values: depths, confidence: levels), source: .synthetic, orientation: .up)
        return .init(frame: frame, landmarks: .init(sessionID: ids.0, frameID: ids.1, origin: .model,
            modelVersion: "synthetic-plane", points: [
                .init(id: "A", point: .init(x: 0.35, y: 0.4), confidence: 0.9),
                .init(id: "B", point: .init(x: 0.65, y: 0.6), confidence: 0.9)
            ], mask: mask))
    }
    private func fit(_ scene: Scene, orientation: ImageOrientation = .up) throws -> GarmentPlane {
        try GarmentPlaneGeometry.fit(frame: scene.frame, mask: XCTUnwrap(scene.landmarks.mask), uprightOrientation: orientation)
    }
    private func measure(_ scene: Scene, definitions: [MeasurementDefinition] = [.testDistance],
                         options: MeasurementOptions = .init()) -> GarmentMeasurementResult {
        GarmentPlaneMeasurementEngine(options: options).measure(frame: scene.frame, landmarks: scene.landmarks, definitions: definitions)
    }
    private func value(_ scene: Scene) throws -> MeasurementValue { try XCTUnwrap(measure(scene).values.first) }

    func testRawOriginalCoordinatesAndResolutionIndependentTiltedPlaneRoundTripInMeters() throws {
        let normal = unit(.init(x: 0.35, y: -0.25, z: 1)), scene = scene(normal: normal)
        let plane = try fit(scene)
        XCTAssertEqual(abs(dot(normal, plane.normal)), 1, accuracy: 0.00000001)
        XCTAssertEqual(plane.offset, -1.2, accuracy: 0.000001)
        let expected = Point3D(x: 0.14, y: -0.16, z: (1.2 - normal.x * 0.14 + normal.y * 0.16) / normal.z)
        let imagePoint = try XCTUnwrap(GarmentPlaneGeometry.project(expected, frame: scene.frame))
        let actual = try GarmentPlaneGeometry.intersection(point: imagePoint, frame: scene.frame, plane: plane)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.000001)
        let result = try value(scene)
        XCTAssertGreaterThan(try XCTUnwrap(result.meters), 0.1)
        XCTAssertLessThan(try XCTUnwrap(result.meters), 1)
        XCTAssertTrue(result.points.allSatisfy { $0.quality.method == .garmentPlane })
        XCTAssertTrue(result.points.allSatisfy { $0.quality.planeResidualMeters == nil && $0.quality.sampleRadiusPixels == nil })
    }

    func testRigidCameraRollAndTiltKeepTheSamePhysicalLength() throws {
        let normal = unit(.init(x: 0.25, y: -0.1, z: 1)), offset = -1.1
        let a = Point3D(x: -0.15, y: -0.1, z: -(normal.x * -0.15 + normal.y * -0.1 + offset) / normal.z)
        let b = Point3D(x: 0.17, y: 0.12, z: -(normal.x * 0.17 + normal.y * 0.12 + offset) / normal.z)
        let expected = hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
        for (roll, tilt) in [(0.0, 0.0), (0.8, 0), (-1.1, 0.18), (0.35, -0.2)] {
            func rotate(_ p: Point3D) -> Point3D {
                let x = cos(roll) * p.x - sin(roll) * p.y, y = sin(roll) * p.x + cos(roll) * p.y
                return .init(x: cos(tilt) * x + sin(tilt) * p.z, y: y, z: -sin(tilt) * x + cos(tilt) * p.z)
            }
            var rotated = scene(normal: rotate(normal), offset: offset)
            rotated.landmarks.points[0].point = try XCTUnwrap(GarmentPlaneGeometry.project(rotate(a), frame: rotated.frame))
            rotated.landmarks.points[1].point = try XCTUnwrap(GarmentPlaneGeometry.project(rotate(b), frame: rotated.frame))
            XCTAssertEqual(try XCTUnwrap(value(rotated).meters), expected, accuracy: 0.000002)
        }
    }

    func testLandmarkDepthHolesAndMinorityOutliersDoNotRequireLocalDepth() throws {
        let normal = unit(.init(x: 0.3, y: 0.15, z: 1))
        let scene = scene(normal: normal, offset: -1.1, modify: { x, y, depth in
            if (abs(x - 56) < 5 && abs(y - 48) < 5) || (abs(x - 104) < 5 && abs(y - 72) < 5) { return .nan }
            if (x * 19 + y * 31) % 7 == 0 { return depth + 0.15 }
            return depth + sin(Float(x * 11 + y * 7)) * 0.002
        }, confidence: { _, _ in 1 })
        let plane = try fit(scene), measured = try value(scene)
        XCTAssertEqual(measured.status, .valid)
        XCTAssertNotNil(measured.meters)
        XCTAssertLessThan(plane.quality.inlierCount, plane.quality.candidateCount)
        XCTAssertEqual(abs(dot(normal, plane.normal)), 1, accuracy: 0.00001)
        XCTAssertLessThan(plane.quality.orthogonalRMSMeters, 0.002)
    }

    func testRefinementPreservesSupportedPlaneNearInlierThreshold() throws {
        // A synthetic 1.2 m plane with deterministic noise and minority outliers.
        // Blindly accepting each refit loses the required 75% support on this
        // fixture even though the preceding fit has 679 of 896 inliers.
        let scene = scene(modify: { x, y, depth in
            var hash = UInt64(x * 73856093 + y * 19349663 + 233 * 83492791)
            hash = (hash ^ (hash >> 13)) &* 1274126177
            if hash % 100 < 20 { return depth + 0.05 }
            let noise = Double(hash % 10001) / 5000 - 1
            return depth + Float(noise * 0.010)
        })
        let plane = try fit(scene), measured = try value(scene)
        XCTAssertGreaterThanOrEqual(plane.quality.inlierCount,
                                   Int(ceil(Double(plane.quality.candidateCount) * 0.75)))
        XCTAssertLessThanOrEqual(plane.quality.orthogonalRMSMeters, 0.008)
        XCTAssertGreaterThanOrEqual(plane.quality.horizontalCoverage, 0.6)
        XCTAssertGreaterThanOrEqual(plane.quality.verticalCoverage, 0.6)
        XCTAssertEqual(plane.offset, -1.2, accuracy: 0.002)
        XCTAssertEqual(measured.status, .valid)
        XCTAssertEqual(try XCTUnwrap(measured.meters), hypot(0.48, 0.24), accuracy: 0.002)
        XCTAssertTrue(measured.points.allSatisfy { $0.quality.garmentPlaneQuality == plane.quality })
    }

    func testRawAsymmetricMaskSelectsGarmentRatherThanRotatedBackground() throws {
        let scene = scene(maskAt: { $0 > 0.12 && $0 < 0.43 && $1 > 0.18 && $1 < 0.58 }, modify: { x, y, _ in
            let u = Double(x) / 160, v = Double(y) / 120
            return u > 0.12 && u < 0.43 && v > 0.18 && v < 0.58 ? 1.1 : 2.1
        })
        XCTAssertEqual(try fit(scene, orientation: .right).offset, -1.1, accuracy: 0.000001)
    }

    func testClippingUsesUprightSidesRatherThanSensorHorizontalAxis() throws {
        let rawTopTouching = scene(maskAt: { $0 >= 0.25 && $0 <= 0.75 && $1 < 0.7 })
        XCTAssertNoThrow(try fit(rawTopTouching, orientation: .up))
        XCTAssertThrowsError(try fit(rawTopTouching, orientation: .right)) { XCTAssertEqual($0 as? MeasurementFailure, .invalidMask) }
        let rawLeftTouching = scene(maskAt: { $0 < 0.7 && $1 >= 0.25 && $1 <= 0.75 })
        XCTAssertThrowsError(try fit(rawLeftTouching, orientation: .up))
        XCTAssertNoThrow(try fit(rawLeftTouching, orientation: .right))
    }

    func testMissingConfidenceLowConfidenceBadBuffersAndCalibrationCannotFit() throws {
        var missing = scene(); missing.frame.depth.confidence = nil
        XCTAssertEqual(try value(missing).failure, .invalidDepthMap)
        let low = scene(confidence: { _, _ in 0 })
        XCTAssertEqual(try value(low).failure, .insufficientGarmentPlane)
        var badCount = scene(); badCount.frame.depth.confidence?.removeLast()
        XCTAssertEqual(try value(badCount).failure, .invalidDepthMap)
        var badCalibration = scene(); badCalibration.frame.intrinsics.fx = .leastNonzeroMagnitude
        XCTAssertEqual(try value(badCalibration).failure, .invalidCalibration)
        var invalidMask = scene(); invalidMask.landmarks.mask?.values[0] = 2
        XCTAssertEqual(try value(invalidMask).failure, .invalidMask)
        var mismatch = scene(); mismatch.landmarks.frameID = UUID()
        XCTAssertEqual(try value(mismatch).failure, .frameMismatch)
    }

    func testAVFoundationWithoutConfidencePreservesKnownPhysicalLengthAcrossTiltAndRoll() throws {
        // Analytic buffers exercise the AVFoundation source contract; these
        // are not recordings or evidence of physical device accuracy.
        let normal = unit(.init(x: 0.25, y: -0.1, z: 1)), offset = -1.1
        let a = Point3D(x: -0.15, y: -0.1, z: -(normal.x * -0.15 + normal.y * -0.1 + offset) / normal.z)
        let b = Point3D(x: 0.17, y: 0.12, z: -(normal.x * 0.17 + normal.y * 0.12 + offset) / normal.z)
        let expected = hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
        for (roll, tilt) in [(0.0, 0.0), (0.8, 0), (-1.1, 0.18), (0.35, -0.2)] {
            func rotate(_ p: Point3D) -> Point3D {
                let x = cos(roll) * p.x - sin(roll) * p.y, y = sin(roll) * p.x + cos(roll) * p.y
                return .init(x: cos(tilt) * x + sin(tilt) * p.z, y: y, z: -sin(tilt) * x + cos(tilt) * p.z)
            }
            var candidate = scene(normal: rotate(normal), offset: offset)
            candidate.frame.source = .avFoundationLiDAR
            candidate.landmarks.points[0].point = try XCTUnwrap(GarmentPlaneGeometry.project(rotate(a), frame: candidate.frame))
            candidate.landmarks.points[1].point = try XCTUnwrap(GarmentPlaneGeometry.project(rotate(b), frame: candidate.frame))
            let withConfidence = try value(candidate)
            candidate.frame.depth.confidence = nil
            let unknownConfidence = try value(candidate)
            XCTAssertEqual(try XCTUnwrap(unknownConfidence.meters), expected, accuracy: 0.000002)
            XCTAssertEqual(unknownConfidence.meters, withConfidence.meters)
            XCTAssertEqual(unknownConfidence.status, .uncertain)
            XCTAssertNil(unknownConfidence.failure)
            XCTAssertNil(unknownConfidence.failureFeedback)
            XCTAssertTrue(unknownConfidence.points.allSatisfy {
                !$0.quality.confidenceAvailable && $0.quality.method == .garmentPlane
                    && $0.quality.garmentPlaneQuality != nil
            })
            XCTAssertNil(candidate.frame.depth.confidence, "Geometric support must not fabricate a confidence map")
        }
    }

    func testMissingConfidenceRemainsAnInputFailureForSourcesThatRequireIt() throws {
        for source in [DepthSource.sceneDepth, .smoothedSceneDepth, .synthetic] {
            var candidate = scene()
            candidate.frame.source = source
            candidate.frame.depth.confidence = nil
            let measured = try value(candidate)
            XCTAssertEqual(measured.failure, .invalidDepthMap)
            XCTAssertEqual(measured.failureContexts?.first?.reason, .missingDepthConfidence)
            XCTAssertNil(measured.meters)
        }
    }

    func testAVFoundationWithoutConfidenceStillRejectsAbsentMixedAndNarrowDepthSupport() throws {
        let absent = scene(modify: { _, _, _ in 0 })
        let mixed = scene(modify: { x, _, _ in x < 80 ? 1.0 : 1.15 })
        var narrow = scene()
        narrow.frame.intrinsics.fx = 20_000; narrow.frame.intrinsics.fy = 20_000
        for (fixture, reason) in [(absent, MeasurementFailureReason.planeTooFewSamples),
                                  (mixed, .planeInsufficientInliers), (narrow, .planeNarrowSupport)] {
            var candidate = fixture
            candidate.frame.source = .avFoundationLiDAR
            candidate.frame.depth.confidence = nil
            let measured = try value(candidate)
            XCTAssertEqual(measured.failure, .insufficientGarmentPlane)
            XCTAssertEqual(measured.failureContexts?.first?.reason, reason)
            XCTAssertNil(measured.meters)
            XCTAssertTrue(measured.points.isEmpty)
        }
    }

    func testAVFoundationDoesNotIgnorePresentLowOrMalformedConfidenceMaps() throws {
        let low = scene(confidence: { _, _ in 0 })
        var badCount = scene(); badCount.frame.depth.confidence?.removeLast()
        var invalidLevel = scene(); invalidLevel.frame.depth.confidence?[0] = 3
        for (fixture, reason) in [(low, MeasurementFailureReason.lowSensorConfidence),
                                  (badCount, .malformedConfidence), (invalidLevel, .malformedConfidence)] {
            var candidate = fixture
            candidate.frame.source = .avFoundationLiDAR
            let measured = try value(candidate)
            XCTAssertEqual(measured.failureContexts?.first?.reason, reason)
            XCTAssertNil(measured.meters)
        }
    }

    func testMixedSurfacesCurvatureAndOneSidedOrNarrowSupportFailWithoutLocalFallback() throws {
        let mixed = scene(modify: { x, _, _ in x < 80 ? 1.0 : 1.15 })
        let curved = scene(modify: { x, y, _ in 1.2 + 0.14 * sin(Float(x) * 0.11) * cos(Float(y) * 0.09) })
        let oneSide = scene(confidence: { x, _ in x < 75 ? 2 : 0 })
        let narrow = scene(confidence: { _, y in (55...65).contains(y) ? 2 : 0 })
        for scene in [mixed, curved, oneSide, narrow] {
            let result = measure(scene)
            XCTAssertEqual(result.algorithmVersion, GarmentPlaneMeasurementEngine.algorithmVersion)
            XCTAssertEqual(result.values[0].failure, .insufficientGarmentPlane)
            XCTAssertNil(result.values[0].meters)
            XCTAssertTrue(result.values[0].points.isEmpty)
        }
        // The legacy local engine can still resolve two separate surfaces; it
        // must not be selected silently by a failed automatic plane capture.
        XCTAssertNotNil(LiDARMeasurementEngine().measure(frame: mixed.frame, landmarks: mixed.landmarks, definitions: [.testDistance]).values[0].meters)
    }

    func testSampleGridIsBoundedDeterministicAndRMSDescribesReturnedPlane() throws {
        let scene = scene(depthSize: .init(width: 1024, height: 768), modify: { x, y, depth in
            if (x * 19 + y * 31) % 7 == 0 { return depth + 0.15 }
            return depth + sin(Float(x * 11 + y * 7)) * 0.002
        })
        let plane = try fit(scene), second = try fit(scene)
        XCTAssertLessThanOrEqual(plane.quality.interiorCount, 4096)
        XCTAssertEqual(plane.quality, second.quality)
        XCTAssertEqual(plane.normal, second.normal)
        XCTAssertEqual(plane.offset, second.offset)
        // Independent reconstruction of the exact visited grid and returned
        // plane, including raw x/width instead of a half-pixel offset.
        let size = scene.frame.depth.size, mask = try XCTUnwrap(scene.landmarks.mask)
        var step = Int(ceil(sqrt(Double(size.width * size.height) / 4096)))
        while ((size.width + step - 1) / step) * ((size.height + step - 1) / step) > 4096 { step += 1 }
        var sum = 0.0, count = 0
        for y in stride(from: 1, to: size.height - 1, by: step) {
            for x in stride(from: 1, to: size.width - 1, by: step) {
                var inside = true
                for dy in -1...1 { for dx in -1...1 {
                    let mx = Int(Double(x + dx) / Double(size.width) * Double(mask.size.width))
                    let my = Int(Double(y + dy) / Double(size.height) * Double(mask.size.height))
                    inside = inside && mask.values[my * mask.size.width + mx] == 1
                } }
                guard inside else { continue }
                let z = Double(scene.frame.depth.values[y * size.width + x])
                let p = Point3D(x: (Double(x) / Double(size.width) * 800 - 400) / 600 * z,
                                y: (Double(y) / Double(size.height) * 600 - 300) / 600 * z, z: z)
                let residual = dot(plane.normal, p) + plane.offset
                if abs(residual) <= 0.010 { sum += residual * residual; count += 1 }
            }
        }
        XCTAssertEqual(count, plane.quality.inlierCount)
        XCTAssertEqual(sqrt(sum / Double(count)), plane.quality.orthogonalRMSMeters, accuracy: 1e-12)
    }

    func testPlaneNeedsSixtyCandidatesAndQuarterInteriorSupportRatherThanOnlyLocalPatches() throws {
        let tooFew = scene(depthSize: .init(width: 80, height: 60), confidence: { x, y in
            // Fewer than 60 candidates on the actual step-2 fitting grid.
            (25..<35).contains(x) && (25..<35).contains(y) ? 2 : 0
        })
        XCTAssertEqual(try value(tooFew).failure, .insufficientGarmentPlane)
        let tooSparse = scene(confidence: { x, y in ((x * 7 + y * 13) % 5 == 0) ? 2 : 0 })
        XCTAssertEqual(try value(tooSparse).failure, .insufficientGarmentPlane)
        // Uniformly distributed 4/11 support still spans the garment and meets
        // the acceptance fraction; this rejects density, not mere missing data.
        let enough = scene(confidence: { x, y in ((x * 7 + y * 13) % 11 < 4) ? 2 : 0 })
        XCTAssertNotNil(try value(enough).meters)
    }

    func testTinyPhysicalSupportAndSeparatedNoisySheetsRemainRejected() throws {
        var tiny = scene()
        tiny.frame.intrinsics.fx = 20_000; tiny.frame.intrinsics.fy = 20_000
        XCTAssertEqual(try value(tiny).failure, .insufficientGarmentPlane)
        let separated = scene(modify: { x, y, depth in depth + ((x + y).isMultiple(of: 2) ? 0.009 : -0.009) })
        XCTAssertEqual(try value(separated).failure, .insufficientGarmentPlane)
        let acceptableRMS = scene(modify: { x, y, depth in depth + sin(Float(x * 11 + y * 7)) * 0.007 })
        let quality = try fit(acceptableRMS).quality
        XCTAssertGreaterThan(quality.orthogonalRMSMeters, 0.004)
        XCTAssertLessThan(quality.orthogonalRMSMeters, 0.008)
    }

    func testPerEndpointConfidenceFailureDoesNotInvalidateAnotherMeasurement() throws {
        var scene = scene()
        scene.landmarks.points.append(.init(id: "C", point: .init(x: 0.5, y: 0.7), confidence: 0.49))
        let definitions: [MeasurementDefinition] = [.testDistance, .init(id: "bad", title: "bad", landmarkIDs: ["A", "C"])]
        let result = measure(scene, definitions: definitions)
        XCTAssertNotNil(result.values[0].meters)
        XCTAssertNil(result.values[1].meters)
        XCTAssertEqual(result.values[1].failure, .lowLandmarkConfidence)
        XCTAssertEqual(result.values[1].pointFailures?.map(\.landmarkID), ["C"])
        XCTAssertEqual(result.values[1].pointFailures?.map(\.reason), [.lowLandmarkConfidence])
        XCTAssertEqual(result.values[1].pointFailures?.first?.context?.reason, .lowModelConfidence)
        scene.landmarks.points[2].origin = .manual
        XCTAssertNotNil(measure(scene, definitions: definitions).values[1].meters)
    }

    func testDuplicateCycleInvalidDefinitionsAndOptionsRemainRejected() throws {
        var duplicate = scene(); duplicate.landmarks.points.append(duplicate.landmarks.points[0])
        XCTAssertEqual(try value(duplicate).failure, .duplicateLandmark)
        var cycle = scene(); cycle.landmarks.points[0].derivedFrom = ["B", "A"]
        XCTAssertEqual(try value(cycle).failure, .invalidDefinition)
        let regular = scene()
        let duplicateDefinitions = measure(regular, definitions: [.testDistance, .testDistance])
        XCTAssertTrue(duplicateDefinitions.values.allSatisfy { $0.failure == .invalidDefinition })
        var options = MeasurementOptions(); options.sampleRadius = Int.max
        XCTAssertEqual(measure(regular, options: options).values[0].failure, .invalidOptions)
    }

    func testGrazingBehindAndOutOfRangeIntersectionsFail() throws {
        let scene = scene(), accepted = try fit(scene)
        var grazing = accepted; grazing.normal = unit(.init(x: 1, y: 0, z: 0.05)); grazing.offset = -0.06
        XCTAssertThrowsError(try GarmentPlaneGeometry.intersection(point: .init(x: 0.5, y: 0.5), frame: scene.frame, plane: grazing))
        var behind = accepted; behind.offset = 1
        XCTAssertThrowsError(try GarmentPlaneGeometry.intersection(point: .init(x: 0.5, y: 0.5), frame: scene.frame, plane: behind))
        XCTAssertThrowsError(try GarmentPlaneGeometry.intersection(point: .init(x: 1, y: 0.5), frame: scene.frame, plane: accepted))
        XCTAssertNil(GarmentPlaneGeometry.project(.init(x: 0, y: 0, z: -1), frame: scene.frame))
    }

    private func top(maskAt: (Double, Double) -> Bool = { $0 >= 0.2 && $0 <= 0.8 && $1 >= 0.15 && $1 <= 0.85 }) -> Scene {
        var scene = scene(maskAt: maskAt)
        scene.landmarks.points += [
            .init(id: "neck_left", point: .init(x: 0.4, y: 0.25), confidence: 0.9),
            .init(id: "neck_right", point: .init(x: 0.6, y: 0.25), confidence: 0.9),
            .init(id: "hem_center", point: .init(x: 0.52, y: 0.82), confidence: 0.9),
            .init(id: "top_length_start", point: .init(x: 0.5, y: 0.25), confidence: nil,
                  isVisible: false, contourRule: .neckPerpendicularMaskV1)
        ]
        return scene
    }
    private var topDefinitions: [MeasurementDefinition] {
        [.testDistance, .init(id: "top.totalLength", title: "총장", landmarkIDs: ["top_length_start", "hem_center"])]
    }

    func testAVFoundationUnknownConfidenceRemainsUnknownThroughContourAverageAndProjection() throws {
        var candidate = top()
        candidate.frame.source = .avFoundationLiDAR
        candidate.landmarks.points.append(.init(id: "midpoint", point: .init(x: 0.5, y: 0.25), confidence: 1,
            derivedFrom: ["neck_left", "neck_right"]))
        let definitions = topDefinitions + [
            .init(id: "average", title: "average", landmarkIDs: ["midpoint", "hem_center"]),
            .init(id: "projected", title: "projected", landmarkIDs: ["A", "B"],
                  projection: .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"]))
        ]
        let withConfidence = measure(candidate, definitions: definitions)
        candidate.frame.depth.confidence = nil
        let unknownConfidence = measure(candidate, definitions: definitions)
        XCTAssertEqual(unknownConfidence.values.count, definitions.count)
        for (measured, baseline) in zip(unknownConfidence.values, withConfidence.values) {
            XCTAssertEqual(measured.status, .uncertain)
            XCTAssertTrue(measured.hasUsableMeasurement)
            XCTAssertEqual(measured.meters, baseline.meters)
            XCTAssertNil(measured.failure)
            XCTAssertNil(measured.failureFeedback)
            XCTAssertEqual(measured.points.count, baseline.points.count)
            for (point, known) in zip(measured.points, baseline.points) {
                XCTAssertFalse(point.quality.confidenceAvailable)
                XCTAssertEqual(point.quality.method, known.quality.method)
                XCTAssertEqual(point.quality.garmentPlaneQuality, known.quality.garmentPlaneQuality)
                XCTAssertEqual(point.sourceLandmarkIDs, known.sourceLandmarkIDs)
                XCTAssertEqual(point.position, known.position)
            }
        }
        XCTAssertEqual(unknownConfidence.values[1].points.first?.quality.method, .contourIntersection)
        XCTAssertEqual(unknownConfidence.values[2].points.first?.quality.method, .spatialAverage)
        XCTAssertEqual(unknownConfidence.values[3].points.last?.quality.method, .axisProjection)
    }
    func testContourIsPerpendicularInPlaneWithExactReturnedImageEndpointAndNoMidpointSubstitution() throws {
        let scene = top(), result = measure(scene, definitions: topDefinitions)
        let length = result.values[1], start = try XCTUnwrap(length.points.first)
        XCTAssertEqual(try XCTUnwrap(length.meters), 0.804, accuracy: 0.005)
        XCTAssertEqual(start.id, "top_length_start")
        XCTAssertEqual(start.quality.method, .contourIntersection)
        XCTAssertEqual(start.imagePoint.y, 0.15, accuracy: 0.0045)
        XCTAssertEqual(start.imagePoint.x, 0.52, accuracy: 1e-10)
        XCTAssertEqual(start.sourceLandmarkIDs, ["neck_left", "neck_right", "hem_center"])
        XCTAssertEqual(start.imagePoint, GarmentPlaneGeometry.project(start.position, frame: scene.frame))
        XCTAssertNil(start.quality.planeResidualMeters)
        XCTAssertNotNil(start.quality.garmentPlaneQuality)
    }

    func testTiltedContourRemainsPhysicallyPerpendicularRatherThanImageVertical() throws {
        var scene = scene(normal: unit(.init(x: 0.5, y: -0.3, z: 1)))
        scene.landmarks.points += [
            .init(id: "neck_left", point: .init(x: 0.4, y: 0.25), confidence: 0.9),
            .init(id: "neck_right", point: .init(x: 0.6, y: 0.32), confidence: 0.9),
            .init(id: "hem_center", point: .init(x: 0.52, y: 0.82), confidence: 0.9),
            .init(id: "top_length_start", point: .init(x: 0.5, y: 0.25), confidence: nil,
                  isVisible: false, contourRule: .neckPerpendicularMaskV1)
        ]
        let plane = try fit(scene), result = measure(scene, definitions: topDefinitions)
        let length = result.values[1]
        let start = try XCTUnwrap(length.points.first), hem = try XCTUnwrap(length.points.last)
        let left = try GarmentPlaneGeometry.intersection(point: scene.landmarks.points[2].point, frame: scene.frame, plane: plane)
        let right = try GarmentPlaneGeometry.intersection(point: scene.landmarks.points[3].point, frame: scene.frame, plane: plane)
        let neckAxis = Point3D(x: right.x - left.x, y: right.y - left.y, z: right.z - left.z)
        let lengthAxis = Point3D(x: start.position.x - hem.position.x, y: start.position.y - hem.position.y,
                                 z: start.position.z - hem.position.z)
        XCTAssertEqual(dot(unit(neckAxis), unit(lengthAxis)), 0, accuracy: 1e-10)
        XCTAssertEqual(dot(plane.normal, lengthAxis), 0, accuracy: 1e-10)
        XCTAssertGreaterThan(abs(start.imagePoint.x - hem.imagePoint.x), 0.05)
        let mask = try XCTUnwrap(scene.landmarks.mask)
        let pixel = Int(start.imagePoint.y * Double(mask.size.height)) * mask.size.width
            + Int(start.imagePoint.x * Double(mask.size.width))
        XCTAssertEqual(mask.values[pixel], 1, "Returned endpoint must be the last actual interior sample")
    }

    func testReversingNeckOrderKeepsIdenticalContourDirection() throws {
        var scene = top()
        let original = measure(scene, definitions: topDefinitions).values[1]
        let left = scene.landmarks.points[2].point
        scene.landmarks.points[2].point = scene.landmarks.points[3].point; scene.landmarks.points[3].point = left
        let swapped = measure(scene, definitions: topDefinitions).values[1]
        XCTAssertEqual(swapped.meters, original.meters)
        XCTAssertEqual(swapped.points.first?.imagePoint, original.points.first?.imagePoint)
    }

    func testClosedMaskHoleIsPassedButExteriorOpeningStopsAtFirstStableExit() throws {
        let closed = top(maskAt: { x, y in x >= 0.2 && x <= 0.8 && y >= 0.15 && y <= 0.85
            && !(abs(x - 0.52) < 0.025 && abs(y - 0.5) < 0.03) })
        XCTAssertEqual(try XCTUnwrap(measure(closed, definitions: topDefinitions).values[1].meters), 0.804, accuracy: 0.005)
        let open = top(maskAt: { x, y in x >= 0.2 && x <= 0.8 && y >= 0.15 && y <= 0.85
            && !(x > 0.48 && x < 0.56 && y < 0.3) })
        let openResult = measure(open, definitions: topDefinitions)
        XCTAssertNotNil(openResult.values[0].meters)
        XCTAssertEqual(try XCTUnwrap(openResult.values[1].meters), 0.624, accuracy: 0.005)
    }

    func testEarlyExitCroppedTopAndDistantHemFailOnlyTotalLengthWithoutFallback() throws {
        let early = top(maskAt: { x, y in x >= 0.2 && x <= 0.8 && y >= 0.15 && y <= 0.85
            && !(y > 0.65 && y < 0.7) })
        let cropped = top(maskAt: { x, y in x >= 0.2 && x <= 0.8 && y <= 0.85 })
        var distant = top(); distant.landmarks.points[4].point.y = 0.95
        for scene in [early, cropped, distant] {
            let result = measure(scene, definitions: topDefinitions)
            XCTAssertNotNil(result.values[0].meters)
            XCTAssertEqual(result.values[1].failure, .contourIntersectionUnavailable)
            XCTAssertNil(result.values[1].meters)
            XCTAssertFalse(result.values[1].points.contains { $0.id == "top_length_start" })
        }
    }

    func testHemJustOutsideEntersWithinThreeCentimetersWithoutMovingOriginalHem() throws {
        var scene = top(); scene.landmarks.points[4].point.y = 0.86
        let length = measure(scene, definitions: topDefinitions).values[1]
        XCTAssertNotNil(length.meters)
        XCTAssertEqual(length.points.last?.imagePoint.y, 0.86)
        XCTAssertEqual(try XCTUnwrap(length.meters), 0.852, accuracy: 0.005)
    }

    func testContourParentConfidenceAndDegenerateNeckFailOnlyLength() throws {
        var low = top(); low.landmarks.points[2].confidence = 0.49
        var degenerate = top(); degenerate.landmarks.points[3].point = degenerate.landmarks.points[2].point
        for (scene, reason) in [(low, MeasurementFailure.lowLandmarkConfidence), (degenerate, .contourIntersectionUnavailable)] {
            let result = measure(scene, definitions: topDefinitions)
            XCTAssertNotNil(result.values[0].meters)
            XCTAssertNil(result.values[1].meters)
            XCTAssertEqual(result.values[1].failure, reason)
        }
    }

    func testUserDirectStartOverrideIsNotReplacedByContourRule() throws {
        var scene = top()
        scene.landmarks.points[5] = .init(id: "top_length_start", point: .init(x: 0.52, y: 0.22), confidence: nil, origin: .manual)
        let length = measure(scene, definitions: topDefinitions).values[1]
        XCTAssertEqual(length.points.first?.imagePoint.y, 0.22)
        XCTAssertEqual(length.points.first?.quality.method, .garmentPlane)
        XCTAssertEqual(try XCTUnwrap(length.meters), 0.72, accuracy: 0.000001)
    }

    func testUnknownModelConfidencePropagatesThroughAverageContourAndProjectionButNotManualPoint() throws {
        var scene = top()
        // The contour placeholder itself is not an independent prediction.
        XCTAssertEqual(measure(scene, definitions: topDefinitions).values[1].status, .valid)
        scene.landmarks.points[2].confidence = nil
        scene.landmarks.points.append(.init(id: "midpoint", point: .init(x: 0.5, y: 0.25), confidence: 1,
            derivedFrom: ["neck_left", "neck_right"]))
        let definitions = topDefinitions + [
            .init(id: "average", title: "average", landmarkIDs: ["midpoint", "hem_center"]),
            .init(id: "projected", title: "projected", landmarkIDs: ["A", "B"],
                  projection: .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"]))
        ]
        let result = measure(scene, definitions: definitions)
        XCTAssertEqual(result.values.map(\.status), [.valid, .uncertain, .uncertain, .uncertain])
        XCTAssertTrue(result.values.allSatisfy { $0.meters != nil && $0.failure == nil })
        scene.landmarks.points[2].origin = .manual
        XCTAssertTrue(measure(scene, definitions: definitions).values.allSatisfy { $0.status == .valid })
    }
}
