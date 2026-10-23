import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic geometry and contract regressions, not a claim of real-device accuracy.
final class BottomThighContourTests: XCTestCase {
    private typealias G = GarmentPlaneGeometry
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
        var plane: GarmentPlane
        var lateral: Point3D
        var vertical: Point3D
        let center = Point3D(x: 0, y: 0, z: 1.2)

        func world(_ x: Double, _ y: Double) -> Point3D {
            G.add(center, G.add(G.scale(lateral, x), G.scale(vertical, y)))
        }
        func projected(_ x: Double, _ y: Double) throws -> ImagePoint {
            try XCTUnwrap(G.project(world(x, y), frame: frame))
        }
    }

    private func schema(_ name: String = "bottom8") throws -> BottomLandmarkSchema {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try .init(jsonData: Data(contentsOf:
            repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_\(name).json")))
    }

    private func scene(roll: Double = 0, tilt: Double = 0,
                       maskAt: (Double, Double) -> Bool = {
                           (-0.30...0.25).contains($0) && (-0.4...0.4).contains($1)
                       }) throws -> Scene {
        func rotate(_ point: Point3D) -> Point3D {
            let x = cos(roll) * point.x - sin(roll) * point.y
            let y = sin(roll) * point.x + cos(roll) * point.y
            return .init(x: x, y: cos(tilt) * y - sin(tilt) * point.z,
                         z: sin(tilt) * y + cos(tilt) * point.z)
        }
        let lateral = rotate(.init(x: 1, y: 0, z: 0))
        let vertical = rotate(.init(x: 0, y: 1, z: 0))
        let normal = G.cross(lateral, vertical), center = Point3D(x: 0, y: 0, z: 1.2)
        let offset = -G.dot(normal, center)
        let imageSize = PixelSize(width: 800, height: 600)
        let depthSize = PixelSize(width: 160, height: 120)
        let maskSize = PixelSize(width: 640, height: 480)
        func position(_ x: Double, _ y: Double) -> Point3D {
            let ray = Point3D(x: (x * 800 - 400) / 600, y: (y * 600 - 300) / 600, z: 1)
            return G.scale(ray, -offset / G.dot(normal, ray))
        }
        let depth = (0..<(depthSize.width * depthSize.height)).map {
            Float(position(Double($0 % depthSize.width) / Double(depthSize.width),
                           Double($0 / depthSize.width) / Double(depthSize.height)).z)
        }
        let mask = GarmentMask(size: maskSize, values: (0..<(maskSize.width * maskSize.height)).map {
            let point = position(Double($0 % maskSize.width) / Double(maskSize.width),
                                 Double($0 / maskSize.width) / Double(maskSize.height))
            let delta = G.subtract(point, center)
            return maskAt(G.dot(delta, lateral), G.dot(delta, vertical)) ? 1 : 0
        })
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .distantPast,
            imageSize: imageSize,
            intrinsics: .init(fx: 600, fy: 600, cx: 400, cy: 300, referenceSize: imageSize),
            depth: .init(size: depthSize, values: depth, confidence: Array(repeating: 2, count: depth.count)),
            source: .synthetic, orientation: .up)
        let plane = GarmentPlane(normal: normal, offset: offset, quality: .init(
            interiorCount: 100, candidateCount: 100, inlierCount: 100, orthogonalRMSMeters: 0,
            minorVarianceSquareMeters: 0.04, majorVarianceSquareMeters: 0.06,
            horizontalCoverage: 1, verticalCoverage: 1, viewingRayCosine: normal.z))
        var scene = Scene(frame: frame, landmarks: .init(
            sessionID: frame.sessionID, frameID: frame.frameID, origin: .model,
            modelVersion: AutomaticGarmentKind.bottoms.modelVersion, points: [], mask: mask,
            garmentKind: .bottoms), plane: plane, lateral: lateral, vertical: vertical)
        let coordinates: [(Double, Double)] = [
            (-0.22, -0.30), (0.22, -0.30), (0, 0), (-0.25, 0.36),
            (-0.04, 0.36), (0.04, 0.36), (0.22, 0.36), (0.02, -0.26)
        ]
        scene.landmarks.points = try zip(BottomLandmarkSchema.expectedBottom8Keypoints, coordinates).map {
            .init(id: $0.0, point: try scene.projected($0.1.0, $0.1.1), confidence: 0.95)
        }
        scene.landmarks.points = try schema().calculationPoints(scene.landmarks.points)
        return scene
    }

    private func measure(_ scene: Scene, definitions: [MeasurementDefinition]? = nil) throws -> GarmentMeasurementResult {
        let definitions = try definitions ?? schema().currentMeasurementDefinitions
        return GarmentPlaneMeasurementEngine().measure(
            frame: scene.frame, landmarks: scene.landmarks, definitions: definitions)
    }
    private func thigh(_ scene: Scene) throws -> MeasurementValue {
        try XCTUnwrap(measure(scene).values.first { $0.id == "bottom.thighWidthRight" })
    }
    private func trace(_ scene: Scene, crotch: Point3D? = nil) throws -> Point3D {
        try BottomThighContour.right(waistLeft: scene.world(-0.22, -0.30),
            waistRight: scene.world(0.22, -0.30), crotch: crotch ?? scene.world(0, 0),
            mask: XCTUnwrap(scene.landmarks.mask), frame: scene.frame)
    }
    private func assertContourFailure(_ operation: () throws -> Point3D,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? MeasurementFailure, .contourIntersectionUnavailable, file: file, line: line)
        }
    }

    func testNewDefinitionsAndPointAreOptInWithoutChangingEightModelOutputsOrLegacyDefinitions() throws {
        let current = try schema(), legacy = try schema("bottom7")
        XCTAssertEqual(current.keypoints.count, 8)
        XCTAssertEqual(current.keypoints[7], "waist_front_center")
        XCTAssertEqual(current.measurementDefinitions.count, 8)
        XCTAssertEqual(current.currentMeasurementDefinitions.count, 9)
        XCTAssertEqual(current.currentMeasurementDefinitions.last?.id, "bottom.thighWidthRight")
        XCTAssertEqual(current.currentMeasurementDefinitions.last?.landmarkIDs, ["crotch", "thigh_right"])
        XCTAssertEqual(Array(current.currentMeasurementDefinitions.prefix(8)).map(\.id),
                       current.measurementDefinitions.map(\.id))
        XCTAssertEqual(legacy.currentMeasurementDefinitions.map(\.id), legacy.measurementDefinitions.map(\.id))

        let points = try scene().landmarks.points
        let direct = Array(points.prefix(8)), augmented = current.calculationPoints(direct)
        XCTAssertEqual(augmented.map(\.id), current.keypoints + ["thigh_right"])
        XCTAssertEqual(augmented[7].id, "waist_front_center")
        XCTAssertNil(augmented.last?.derivedFrom)
        XCTAssertNil(augmented.last?.confidence)
        XCTAssertEqual(augmented.last?.isVisible, false)
        XCTAssertEqual(augmented.last?.contourRule, .waistParallelRightThighMaskV1)
        XCTAssertEqual(augmented.last?.contourRule?.sourceLandmarkIDs, ["waist_left", "waist_right", "crotch"])
        XCTAssertEqual(legacy.calculationPoints(direct).count, 8)
        XCTAssertEqual(current.calculationPoints(augmented).count, 9)
        XCTAssertEqual(augmented[2].point, direct[2].point, "The crotch must not receive a 1% shift.")
    }

    func testCalculationHelperPreservesManualOverridesAndDoesNotRepairDuplicateIDs() throws {
        var points = try scene().landmarks.points
        points[8] = .init(id: "thigh_right", point: .init(x: 0.63, y: 0.51),
                          confidence: nil, origin: .manual)
        let retained = BottomLandmarkSchema.addingRightThighCalculationPoint(to: points)
        XCTAssertEqual(retained.count, 9)
        XCTAssertEqual(retained.last?.point, points.last?.point)
        XCTAssertNil(retained.last?.contourRule)
        points.append(points[8])
        XCTAssertEqual(BottomLandmarkSchema.addingRightThighCalculationPoint(to: points).count, 10)
    }

    func testQuarterMeterWidthAndProjectedPointFollowWaistAxisUnderCameraRollAndTilt() throws {
        for (roll, tilt) in [(0.0, 0.0), (0.7, 0.35), (-1.1, 0.45), (1.45, -0.25)] {
            let scene = try scene(roll: roll, tilt: tilt), value = try thigh(scene)
            XCTAssertEqual(value.status, .valid)
            XCTAssertEqual(try XCTUnwrap(value.meters), 0.25, accuracy: 0.005)
            let end = try XCTUnwrap(value.points.last)
            XCTAssertEqual(end.id, "thigh_right")
            XCTAssertEqual(end.quality.method, .contourIntersection)
            XCTAssertEqual(end.sourceLandmarkIDs, ["waist_left", "waist_right", "crotch"])
            let expected = try scene.projected(0.25, 0)
            XCTAssertEqual(end.imagePoint.x, expected.x, accuracy: 0.004)
            XCTAssertEqual(end.imagePoint.y, expected.y, accuracy: 0.004)
            if abs(roll) > 0.5 {
                XCTAssertGreaterThan(abs(end.imagePoint.y - value.points[0].imagePoint.y), 0.04,
                                     "A rotated cross-section must not remain image-horizontal.")
            }
        }
    }

    func testAddingThighDoesNotChangeExistingMeasurements() throws {
        let scene = try scene(roll: 0.3, tilt: 0.25)
        let prior = try measure(scene, definitions: schema().measurementDefinitions)
        let current = try measure(scene)
        XCTAssertEqual(Array(current.values.prefix(8)).map(\.meters), prior.values.map(\.meters))
        XCTAssertEqual(Array(current.values.prefix(8)).map(\.status), prior.values.map(\.status))
        XCTAssertEqual(Array(current.values.prefix(8)).map(\.failure), prior.values.map(\.failure))
        XCTAssertEqual(current.values[8].id, "bottom.thighWidthRight")
    }

    func testFrontCenterPointEightIsNotAThighDependency() throws {
        var scene = try scene()
        scene.landmarks.points.removeAll { $0.id == "waist_front_center" }
        let result = try measure(scene)
        XCTAssertEqual(result.values.first { $0.id == "bottom.crotch.waist_front_center" }?.failure, .missingLandmark)
        XCTAssertEqual(try XCTUnwrap(result.values.last?.meters), 0.25, accuracy: 0.005)
    }

    func testClosedMaskHolesAreIgnoredWithoutMutatingOriginalMask() throws {
        let scene = try scene(roll: 0.4, tilt: 0.2, maskAt: {
            (-0.30...0.25).contains($0) && (-0.4...0.4).contains($1)
                && !((0.07...0.14).contains($0) && (-0.04...0.04).contains($1))
        })
        let before = scene.landmarks.mask?.values
        XCTAssertEqual(try XCTUnwrap(thigh(scene).meters), 0.25, accuracy: 0.005)
        XCTAssertEqual(scene.landmarks.mask?.values, before)
    }

    func testExteriorOpeningStopsAtFirstBoundaryBeforeAnotherGarmentRegion() throws {
        let scene = try scene(maskAt: {
            let garment = (-0.30...0.25).contains($0) && (-0.4...0.4).contains($1)
                && !((0.09...0.14).contains($0) && $1 >= -0.04)
            let other = (0.35...0.45).contains($0) && (-0.3...0.3).contains($1)
            return garment || other
        })
        XCTAssertEqual(try XCTUnwrap(thigh(scene).meters), 0.09, accuracy: 0.005)
    }

    func testSeparateObjectBeyondOuterEdgeCannotExtendTheWidth() throws {
        let scene = try scene(roll: 0.5, tilt: 0.3, maskAt: {
            ((-0.30...0.25).contains($0) || (0.35...0.45).contains($0)) && (-0.4...0.4).contains($1)
        })
        XCTAssertEqual(try XCTUnwrap(thigh(scene).meters), 0.25, accuracy: 0.005)
    }

    func testSingleExteriorNoiseColumnDoesNotCountRepeatedSubpixelVisitsAsStableExit() throws {
        var scene = try scene()
        var mask = try XCTUnwrap(scene.landmarks.mask)
        let column = Int(try scene.projected(0.10, 0).x * Double(mask.size.width))
        for y in 240..<mask.size.height { mask.values[y * mask.size.width + column] = 0 }
        scene.landmarks.mask = mask
        XCTAssertEqual(try XCTUnwrap(thigh(scene).meters), 0.25, accuracy: 0.005)
    }

    func testCrotchNearBoundaryCanEnterButDistantSeedCannotJumpIntoGarment() throws {
        let scene = try scene()
        let near = scene.world(-0.31, 0), distant = scene.world(-0.35, 0)
        XCTAssertEqual(G.length(G.subtract(try trace(scene, crotch: near), near)), 0.56, accuracy: 0.005)
        assertContourFailure { try trace(scene, crotch: distant) }
    }

    func testMissingRightSectionFailsOnlyThighAndDoesNotKeepAHintAsMeasuredPoint() throws {
        let scene = try scene(maskAt: {
            (-0.30...0.25).contains($0) && (-0.4...0.4).contains($1)
                && !($0 >= -0.015 && abs($1) < 0.04)
        })
        let values = try measure(scene).values
        XCTAssertTrue(values.prefix(8).allSatisfy { $0.meters != nil && $0.failure == nil })
        XCTAssertEqual(values.last?.failure, .contourIntersectionUnavailable)
        XCTAssertNil(values.last?.meters)
        XCTAssertFalse(values.last!.points.contains { $0.id == "thigh_right" })
    }

    func testTooShortAxisAndWidthAndMissingOrCroppedEdgeAreRejected() throws {
        let normal = try scene(), mask = try XCTUnwrap(normal.landmarks.mask)
        assertContourFailure {
            try BottomThighContour.right(waistLeft: normal.world(0, -0.3),
                waistRight: normal.world(0.01, -0.3), crotch: normal.world(0, 0), mask: mask, frame: normal.frame)
        }
        let narrow = try scene(maskAt: { (-0.3...0.01).contains($0) && abs($1) <= 0.4 })
        assertContourFailure { try trace(narrow) }
        let noEdgeWithinLimit = try scene(maskAt: { (-0.3...0.7).contains($0) && abs($1) <= 0.4 })
        assertContourFailure { try trace(noEdgeWithinLimit) }
        let cropped = try scene(maskAt: { $0 >= -0.3 && abs($1) <= 0.4 })
        assertContourFailure { try trace(cropped, crotch: cropped.world(0.4, 0)) }
    }

    func testManualThighOverrideUsesItsOwnRayAndNoLongerRequiresWaistParents() throws {
        var scene = try scene()
        let override = try scene.projected(0.18, 0.02)
        scene.landmarks.points.removeAll { ["waist_left", "waist_right", "thigh_right"].contains($0.id) }
        scene.landmarks.points.append(.init(id: "thigh_right", point: override, confidence: nil, origin: .manual))
        let result = try measure(scene, definitions: [BottomLandmarkSchema.thighWidthRightDefinition]).values[0]
        XCTAssertEqual(result.status, .valid)
        XCTAssertEqual(try XCTUnwrap(result.meters), hypot(0.18, 0.02), accuracy: 0.000001)
        XCTAssertEqual(result.points.last?.quality.method, .garmentPlane)
        XCTAssertEqual(result.points.last?.imagePoint, override)
        XCTAssertNil(result.points.last?.sourceLandmarkIDs)
    }

    func testParentConfidenceValidationAndUnknownConfidencePropagateToDerivedPoint() throws {
        var scene = try scene()
        scene.landmarks.points[0].confidence = 0.49
        let failed = try thigh(scene)
        XCTAssertEqual(failed.failure, .lowLandmarkConfidence)
        XCTAssertTrue(failed.pointFailures?.contains { $0.landmarkID == "waist_left" && $0.reason == .lowLandmarkConfidence } == true)
        scene.landmarks.points[0].confidence = nil
        XCTAssertEqual(try thigh(scene).status, .uncertain)
        scene.landmarks.points[0].origin = .manual
        XCTAssertEqual(try thigh(scene).status, .valid)
    }

    func testMissingEndpointDepthStillUsesSharedPlaneRatherThanLocalDepth() throws {
        var scene = try scene()
        for y in 56...64 {
            for x in 76...84 { scene.frame.depth.values[y * 160 + x] = .nan }
        }
        XCTAssertEqual(try XCTUnwrap(thigh(scene).meters), 0.25, accuracy: 0.005)
    }

    func testAmbiguousRuleAndWrongPointIDFailInsteadOfBecomingSpatialAverage() throws {
        var scene = try scene()
        scene.landmarks.points[8].derivedFrom = ["waist_left", "waist_right"]
        XCTAssertEqual(try thigh(scene).failure, .invalidDefinition)
        scene.landmarks.points[8].derivedFrom = nil
        scene.landmarks.points[8].id = "wrong_contour_id"
        let definition = MeasurementDefinition(id: "bad", title: "bad", landmarkIDs: ["crotch", "wrong_contour_id"])
        XCTAssertEqual(try measure(scene, definitions: [definition]).values[0].failure, .invalidDefinition)
    }

    func testMalformedMaskIsRejectedBeforeIndexingAndEmptyMaskCannotInventWidth() throws {
        let scene = try scene()
        var mask = try XCTUnwrap(scene.landmarks.mask)
        mask.values.removeLast()
        XCTAssertThrowsError(try BottomThighContour.right(
            waistLeft: scene.world(-0.22, -0.3), waistRight: scene.world(0.22, -0.3),
            crotch: scene.world(0, 0), mask: mask, frame: scene.frame)) {
            XCTAssertEqual($0 as? MeasurementFailure, .invalidMask)
        }
        let empty = try self.scene(maskAt: { _, _ in false })
        assertContourFailure { try trace(empty) }
    }
}
