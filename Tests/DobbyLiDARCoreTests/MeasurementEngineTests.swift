import XCTest
@testable import DobbyLiDARCore

final class MeasurementEngineTests: XCTestCase {
    private func measurement(
        _ frame: MeasurementFrame,
        _ landmarks: GarmentLandmarkSet,
        options: MeasurementOptions = .init()
    ) throws -> MeasurementValue {
        let result = LiDARMeasurementEngine(options: options).measure(
            frame: frame, landmarks: landmarks, definitions: [.testDistance]
        )
        XCTAssertEqual(result.frameID, frame.frameID)
        XCTAssertEqual(result.sessionID, frame.sessionID)
        XCTAssertEqual(result.values.count, 1)
        return try XCTUnwrap(result.values.first)
    }

    func testFlatPlaneReturnsKnownHalfMetre() throws {
        let scene = SyntheticFixtures.scene()
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), scene.expectedMeters, accuracy: 0.0001)
        XCTAssertEqual(value.status, .valid)
        XCTAssertNil(value.failure)
    }

    func testTiltedPlaneUsesThreeDimensionalDistance() throws {
        let scene = SyntheticFixtures.scene(tilted: true)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), scene.expectedMeters, accuracy: 0.0005)
        let points = value.points
        XCTAssertEqual(points.count, 2)
        if points.count == 2 {
            // The true depth difference is 0.5 * sin(25 degrees), about 21.1 cm.
            XCTAssertEqual(abs(points[1].position.z - points[0].position.z), 0.211309, accuracy: 0.001)
        }
    }

    func testEachEndpointUsesItsOwnDepth() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.points = [
            .init(id: "A", point: .init(x: 0.25, y: 0.5), confidence: 1),
            .init(id: "B", point: .init(x: 0.75, y: 0.5), confidence: 1)
        ]
        for y in 0..<scene.frame.depth.size.height {
            for x in 0..<scene.frame.depth.size.width {
                scene.frame.depth.values[y * scene.frame.depth.size.width + x] = x < 80 ? 1 : 2
            }
        }
        // A=(-1/3, 0, 1), B=(2/3, 0, 2); distance=sqrt(2), not a shared-depth width.
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), sqrt(2), accuracy: 0.0001)
    }

    func testUnprojectionRetainsOffAxisPosition() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.depth.values = .init(repeating: 1.2, count: scene.frame.depth.values.count)
        scene.landmarks.points = [
            .init(id: "A", point: .init(x: 0.25, y: 0.25), confidence: 1),
            .init(id: "B", point: .init(x: 0.75, y: 0.75), confidence: 1)
        ]
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), 1.0, accuracy: 0.0001)
        let a = try XCTUnwrap(value.points.first)
        XCTAssertEqual(a.position.x, -0.4, accuracy: 0.0001)
        XCTAssertEqual(a.position.y, -0.3, accuracy: 0.0001)
        XCTAssertEqual(a.position.z, 1.2, accuracy: 0.0001)
    }

    func testMismatchedCalibrationReferenceSizeIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.intrinsics.referenceSize.width /= 2
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidCalibration)
        XCTAssertNil(value.meters)
    }

    func testDepthAspectMismatchIsRejectedEvenWhenBufferCountMatches() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.depth.size = .init(width: 120, height: 160)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidDepthMap)
        XCTAssertNil(value.meters)
    }

    func testMalformedOptionsAreRejectedBeforeSampling() throws {
        var options = [MeasurementOptions]()
        var nonfinite = MeasurementOptions()
        nonfinite.minimumDepthMeters = .nan
        options.append(nonfinite)
        var negative = MeasurementOptions()
        negative.sampleRadius = -1
        options.append(negative)
        var excessive = MeasurementOptions()
        excessive.sampleRadius = Int.max
        options.append(excessive)
        let scene = SyntheticFixtures.scene()
        for candidate in options {
            let value = try measurement(scene.frame, scene.landmarks, options: candidate)
            XCTAssertEqual(value.failure, .invalidOptions)
            XCTAssertNil(value.meters)
        }
    }

    func testUnknownDepthConfidenceCannotBecomeValid() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.depth.confidence = nil
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertNotNil(value.meters)
        XCTAssertTrue(value.points.allSatisfy { !$0.quality.confidenceAvailable })
    }

    func testMissingDepthReturnsUnavailableWithoutZeroMeasurement() throws {
        let scene = SyntheticFixtures.scene(missingDepth: true)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertNil(value.meters)
    }

    func testLowSensorConfidenceSamplesAreRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.depth.confidence = .init(repeating: 0, count: scene.frame.depth.values.count)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertNil(value.meters)
    }

    func testFrameAndSessionMismatchAreRejected() throws {
        for mismatchSession in [false, true] {
            var scene = SyntheticFixtures.scene()
            if mismatchSession { scene.landmarks.sessionID = UUID() }
            else { scene.landmarks.frameID = UUID() }
            let value = try measurement(scene.frame, scene.landmarks)
            XCTAssertEqual(value.failure, .frameMismatch)
            XCTAssertNil(value.meters)
        }
    }

    func testOutOfBoundsAndNonfiniteLandmarksAreRejected() throws {
        for point in [ImagePoint(x: 1, y: 0.5), .init(x: -0.1, y: 0.5), .init(x: .nan, y: 0.5)] {
            var scene = SyntheticFixtures.scene()
            scene.landmarks.points[0].point = point
            let value = try measurement(scene.frame, scene.landmarks)
            XCTAssertEqual(value.failure, .outOfBounds)
            XCTAssertNil(value.meters)
        }
    }

    func testMalformedDepthAndConfidenceBuffersAreRejected() throws {
        for malformedConfidence in [false, true] {
            var scene = SyntheticFixtures.scene()
            if malformedConfidence { scene.frame.depth.confidence?.removeLast() }
            else { scene.frame.depth.values.removeLast() }
            let value = try measurement(scene.frame, scene.landmarks)
            XCTAssertEqual(value.failure, .invalidDepthMap)
            XCTAssertNil(value.meters)
        }
    }

    func testNonfiniteDepthDoesNotProduceNonfiniteMeasurement() throws {
        for depth: Float in [.nan, .infinity, -.infinity] {
            var scene = SyntheticFixtures.scene()
            scene.frame.depth.values = .init(repeating: depth, count: scene.frame.depth.values.count)
            let value = try measurement(scene.frame, scene.landmarks)
            XCTAssertEqual(value.status, .unavailable)
            XCTAssertNil(value.meters)
        }
    }

    func testNonfiniteCalibrationIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.intrinsics.fx = .nan
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidCalibration)
        XCTAssertNil(value.meters)
    }

    func testFiniteCalibrationThatOverflowsUnprojectionIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.intrinsics.fx = Double.leastNonzeroMagnitude
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidCalibration)
        XCTAssertNil(value.meters)
        XCTAssertTrue(value.points.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(value))
    }

    func testRepresentableVerySmallDistanceDoesNotUnderflowToZero() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.intrinsics.fx = 1e180
        scene.frame.intrinsics.fy = 1e180
        let value = try measurement(scene.frame, scene.landmarks)
        let distance = try XCTUnwrap(value.meters)
        XCTAssertGreaterThan(distance, 0)
        XCTAssertTrue(distance.isFinite)
        // The calibration is mathematically representable, but its ill-conditioned local
        // plane cannot justify a valid sensor result.
        XCTAssertEqual(value.status, .uncertain)
    }

    func testLowModelConfidenceIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.origin = .model
        scene.landmarks.points[0].confidence = 0.1
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .lowLandmarkConfidence)
        XCTAssertNil(value.meters)
    }

    func testMissingModelConfidenceCannotClaimValidResult() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.origin = .model
        scene.landmarks.points[0].confidence = nil
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertNotNil(value.meters)
    }

    func testSensorConfidenceOutsideDefinedRangeIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.frame.depth.confidence?[0] = 3
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidDepthMap)
        XCTAssertNil(value.meters)
    }

    func testOccludedLandmarkIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.points[0].isVisible = false
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .occludedLandmark)
        XCTAssertNil(value.meters)
    }

    func testDuplicateLandmarkDoesNotSilentlyPickOne() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.points.append(scene.landmarks.points[0])
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .duplicateLandmark)
        XCTAssertNil(value.meters)
    }

    func testMissingLandmarkPreservesUnrelatedSuccessfulMeasurement() throws {
        let scene = SyntheticFixtures.scene()
        let definitions: [MeasurementDefinition] = [
            .testDistance,
            .init(id: "missing", title: "Missing point", landmarkIDs: ["A", "C"])
        ]
        let result = LiDARMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks, definitions: definitions)
        XCTAssertEqual(result.values.count, 2)
        let success = try XCTUnwrap(result.values.first { $0.id == "test" })
        XCTAssertEqual(try XCTUnwrap(success.meters), 0.5, accuracy: 0.0001)
        let missing = try XCTUnwrap(result.values.first { $0.id == "missing" })
        XCTAssertEqual(missing.failure, .missingLandmark)
        XCTAssertNil(missing.meters)
    }

    func testMaskExcludesDeeperBackgroundNextToEndpoint() throws {
        var scene = SyntheticFixtures.scene()
        let width = scene.frame.depth.size.width
        let height = scene.frame.depth.size.height
        let boundary = Int(scene.landmarks.points[0].point.x * Double(width))
        for y in 0..<height {
            for x in 0..<boundary {
                let index = y * width + x
                scene.frame.depth.values[index] = 2.5
                scene.landmarks.mask?.values[index] = 0
            }
        }
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), 0.5, accuracy: 0.001)
    }

    func testMaskCannotBorrowDepthFromEntirelyExcludedGarment() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.mask?.values = .init(repeating: 0, count: scene.frame.depth.values.count)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertNil(value.meters)
    }

    func testExcludedLandmarkCannotClaimValidFromSurroundingMaskDepth() throws {
        var scene = SyntheticFixtures.scene()
        let size = try XCTUnwrap(scene.landmarks.mask?.size)
        let target = scene.landmarks.points[0].point
        let x = Int(target.x * Double(size.width))
        let y = Int(target.y * Double(size.height))
        // A background hole surrounds the endpoint, while an otherwise perfectly flat,
        // high-confidence foreground patch still surrounds its convex hull.
        for row in (y - 1)...(y + 1) {
            for column in (x - 1)...(x + 1) {
                scene.landmarks.mask?.values[row * size.width + column] = 0
            }
        }
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertNotEqual(value.status, .valid)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(value.meters), scene.expectedMeters, accuracy: 0.0001)
    }

    func testAsymmetricCalibrationAndTwoAxisSlopesAcrossDepthResolutions() throws {
        // This fixture derives z from a 3D plane equation, not from engine output.
        // Unequal focal lengths, an off-centre principal point, diagonal endpoints and
        // both slope directions exercise mistakes a centred horizontal fixture hides.
        for depthWidth in [160, 256, 320] {
            for slopeX in [-0.6, -0.2, 0.0, 0.2, 0.6] {
                for slopeY in [-0.5, 0.0, 0.5] {
                    var scene = SyntheticFixtures.scene()
                    let imageSize = PixelSize(width: 1024, height: 768)
                    let depthSize = PixelSize(width: depthWidth, height: depthWidth * 3 / 4)
                    let k = CameraIntrinsics(fx: 715, fy: 820, cx: 493, cy: 351, referenceSize: imageSize)
                    let intercept = 1.13
                    func position(_ p: ImagePoint) -> Point3D {
                        let rx = (p.x * Double(imageSize.width) - k.cx) / k.fx
                        let ry = (p.y * Double(imageSize.height) - k.cy) / k.fy
                        let z = intercept / (1 - slopeX * rx - slopeY * ry)
                        return .init(x: rx * z, y: ry * z, z: z)
                    }
                    scene.frame.imageSize = imageSize
                    scene.frame.intrinsics = k
                    var depths: [Float] = []
                    for y in 0..<depthSize.height {
                        for x in 0..<depthSize.width {
                            depths.append(Float(position(.init(
                                x: (Double(x) + 0.5) / Double(depthSize.width),
                                y: (Double(y) + 0.5) / Double(depthSize.height)
                            )).z))
                        }
                    }
                    scene.frame.depth = .init(size: depthSize, values: depths,
                                              confidence: .init(repeating: 2, count: depths.count))
                    scene.landmarks.mask = .init(size: depthSize, values: .init(repeating: 1, count: depths.count))
                    let a = ImagePoint(x: 0.27, y: 0.29), b = ImagePoint(x: 0.67, y: 0.64)
                    scene.landmarks.points[0].point = a
                    scene.landmarks.points[1].point = b
                    let first = position(a), last = position(b)
                    let expected = hypot(hypot(last.x - first.x, last.y - first.y), last.z - first.z)
                    let value = try measurement(scene.frame, scene.landmarks)
                    let context = "depth width \(depthWidth), slopes \(slopeX), \(slopeY)"
                    XCTAssertEqual(try XCTUnwrap(value.meters), expected, accuracy: 0.000002, context)
                    XCTAssertEqual(value.status, .valid, context)
                    XCTAssertTrue(value.points.allSatisfy { $0.quality.method == .localPlane }, context)
                }
            }
        }
    }

    func testMalformedMaskIsRejected() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.mask?.values.removeLast()
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.failure, .invalidMask)
        XCTAssertNil(value.meters)
    }

    func testSmallNoiseAndSparseOutliersKeepKnownDistance() throws {
        let scene = SyntheticFixtures.scene(tilted: true, noisy: true)
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(try XCTUnwrap(value.meters), scene.expectedMeters, accuracy: 0.01)
    }

    func testStrongDepthDiscontinuityCannotClaimValidResult() throws {
        var scene = SyntheticFixtures.scene()
        let width = scene.frame.depth.size.width
        for y in 0..<scene.frame.depth.size.height {
            for x in 0..<width {
                scene.frame.depth.values[y * width + x] = (x + y).isMultiple(of: 2) ? 0.8 : 1.6
            }
        }
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertNotEqual(value.status, .valid)
        if let meters = value.meters { XCTAssertTrue(meters.isFinite) }
    }

    func testCollinearSamplesUseUncertainMedianInsteadOfInventingPlane() throws {
        var scene = SyntheticFixtures.scene()
        let width = scene.frame.depth.size.width
        for y in 0..<scene.frame.depth.size.height where y != 60 {
            for x in 0..<width {
                scene.frame.depth.values[y * width + x] = 0
            }
        }
        let value = try measurement(scene.frame, scene.landmarks)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(value.meters), 0.5, accuracy: 0.001)
        XCTAssertTrue(value.points.allSatisfy { $0.quality.method == .robustMedian })
    }

    func testPolylineAddsExplicitSegments() throws {
        var scene = SyntheticFixtures.scene()
        scene.landmarks.points.append(.init(id: "C", point: .init(x: 0.5, y: 0.5), confidence: 1))
        let result = LiDARMeasurementEngine().measure(
            frame: scene.frame, landmarks: scene.landmarks,
            definitions: [.init(id: "path", title: "A to C to B", landmarkIDs: ["A", "C", "B"])]
        )
        let value = try XCTUnwrap(result.values.first)
        XCTAssertEqual(try XCTUnwrap(value.meters), 0.5, accuracy: 0.0001)
    }

    func testAllDisplayOrientationsRoundTripAnOffCentrePoint() {
        let original = ImagePoint(x: 0.2, y: 0.35)
        let expected: [ImageOrientation: ImagePoint] = [
            .up: original, .right: .init(x: 0.65, y: 0.2),
            .down: .init(x: 0.8, y: 0.65), .left: .init(x: 0.35, y: 0.8)
        ]
        for orientation in ImageOrientation.allCases {
            let display = ImageCoordinateTransform.originalToDisplay(original, orientation: orientation)
            XCTAssertEqual(display.x, expected[orientation]!.x, accuracy: 1e-12)
            XCTAssertEqual(display.y, expected[orientation]!.y, accuracy: 1e-12)
            let recovered = ImageCoordinateTransform.displayToOriginal(display, orientation: orientation)
            XCTAssertEqual(recovered.x, original.x, accuracy: 1e-12)
            XCTAssertEqual(recovered.y, original.y, accuracy: 1e-12)
        }
    }
}
