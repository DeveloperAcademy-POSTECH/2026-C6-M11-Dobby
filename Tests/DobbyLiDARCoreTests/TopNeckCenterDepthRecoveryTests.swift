import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic same-frame depth fixtures, not physical LiDAR or model accuracy evidence.
final class TopNeckCenterDepthRecoveryTests: XCTestCase {
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
        var definitions = TopLandmarkSchema.canonicalMeasurementDefinitions
        var inverseDepthX = 0.0
        var inverseDepthY = 0.0
        var inverseDepthConstant = 1.0 / 1.4
    }

    private func scene(tilted: Bool = false) -> Scene {
        let imageSize = PixelSize(width: 800, height: 800)
        let depthSize = PixelSize(width: 256, height: 256)
        let intrinsics = CameraIntrinsics(fx: 800, fy: 800, cx: 400, cy: 400, referenceSize: imageSize)
        let a = tilted ? 0.35 : 0.0, b = tilted ? -0.2 : 0.0, c = 1.0 / 1.4
        var depths: [Float] = []
        for y in 0..<depthSize.height {
            for x in 0..<depthSize.width {
                let rayX = (Double(x) + 0.5) / Double(depthSize.width) - 0.5
                let rayY = (Double(y) + 0.5) / Double(depthSize.height) - 0.5
                depths.append(Float(1 / (a * rayX + b * rayY + c)))
            }
        }
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1,
            capturedAt: Date(timeIntervalSince1970: 1), imageSize: imageSize, intrinsics: intrinsics,
            depth: .init(size: depthSize, values: depths, confidence: .init(repeating: 2, count: depths.count)),
            source: .synthetic, orientation: .up)
        let direct: [(String, Double, Double)] = [
            ("neck_left", 0.45, 0.3), ("neck_right", 0.55, 0.3),
            ("shoulder_left", 0.3, 0.33), ("shoulder_right", 0.7, 0.33),
            ("armpit_left", 0.32, 0.45), ("armpit_right", 0.68, 0.45),
            ("sleeve_end_left", 0.2, 0.65), ("sleeve_end_right", 0.8, 0.65),
            ("hem_left", 0.33, 0.8), ("hem_center", 0.5, 0.8), ("hem_right", 0.67, 0.8)
        ]
        let points = direct.map { GarmentLandmark(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: 0.99) }
            + [.init(id: "neck_center", point: .init(x: 0.5, y: 0.3), confidence: 0.99,
                     derivedFrom: ["neck_left", "neck_right"])]
        var maskValues = [UInt8](repeating: 0, count: depths.count)
        for y in 20..<236 { for x in 20..<236 { maskValues[y * depthSize.width + x] = 1 } }
        return .init(frame: frame, landmarks: .init(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: AutomaticGarmentKind.top.modelVersion, points: points,
            mask: .init(size: depthSize, values: maskValues), garmentKind: .top),
            inverseDepthX: a, inverseDepthY: b, inverseDepthConstant: c)
    }

    private func point(_ id: String, in scene: Scene) throws -> GarmentLandmark {
        try XCTUnwrap(scene.landmarks.points.first { $0.id == id })
    }

    private func update(_ id: String, in scene: inout Scene, _ edit: (inout GarmentLandmark) -> Void) throws {
        let index = try XCTUnwrap(scene.landmarks.points.firstIndex { $0.id == id })
        edit(&scene.landmarks.points[index])
    }

    private func removeDepth(_ id: String, in scene: inout Scene) throws {
        let point = try point(id, in: scene).point
        let size = scene.frame.depth.size
        let x = Int(point.x * Double(size.width)), y = Int(point.y * Double(size.height))
        for row in (y - 3)...(y + 3) {
            for column in (x - 3)...(x + 3) { scene.frame.depth.values[row * size.width + column] = 0 }
        }
    }

    private func measure(_ scene: Scene, options: MeasurementOptions = .init()) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: options).measure(frame: scene.frame,
            landmarks: scene.landmarks, definitions: scene.definitions)
    }

    private func total(_ result: GarmentMeasurementResult) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == "top.totalLength" })
    }

    private func physicalPoint(_ point: ImagePoint, in scene: Scene) -> Point3D {
        let rayX = point.x - 0.5, rayY = point.y - 0.5
        let z = 1 / (scene.inverseDepthX * rayX + scene.inverseDepthY * rayY + scene.inverseDepthConstant)
        return .init(x: rayX * z, y: rayY * z, z: z)
    }

    private func distance(_ a: Point3D, _ b: Point3D) -> Double {
        hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testOnlyTotalRecoversWhenOneOrBothNeckBoundaryDepthWindowsAreMissing() throws {
        for missing in [["neck_left"], ["neck_left", "neck_right"]] {
            var scene = scene()
            for id in missing { try removeDepth(id, in: &scene) }
            let originalFrame = try canonicalJSON(scene.frame)
            let originalLandmarks = try canonicalJSON(scene.landmarks)
            let result = measure(scene)
            let total = try total(result)
            XCTAssertEqual(total.status, .uncertain)
            XCTAssertNil(total.failure)
            XCTAssertTrue((total.pointFailures ?? []).isEmpty,
                "Successful recovery must not expose the initial neck-depth failure")
            XCTAssertEqual(try XCTUnwrap(total.meters), 0.7, accuracy: 0.00001)
            let center = try XCTUnwrap(total.points.first)
            XCTAssertEqual(center.id, "neck_center")
            XCTAssertEqual(center.imagePoint.x, try point("neck_center", in: scene).point.x, accuracy: 1e-10)
            XCTAssertEqual(center.imagePoint.y, try point("neck_center", in: scene).point.y, accuracy: 1e-10)
            XCTAssertEqual(center.quality.method, .recoveredSpatialAverage)
            XCTAssertEqual(center.sourceLandmarkIDs, ["neck_left", "neck_right"])
            XCTAssertGreaterThanOrEqual(center.quality.validSamples, MeasurementOptions().minimumSamples)
            XCTAssertNotNil(center.quality.planeResidualMeters)
            XCTAssertEqual(center.recoverySourcePositions?.count, 2)
            XCTAssertEqual(center.quality.sampleRadiusPixels, 6)
            XCTAssertTrue(result.values.dropLast().allSatisfy { $0.status == .valid && $0.meters != nil })
            XCTAssertEqual(result.sessionID, scene.frame.sessionID)
            XCTAssertEqual(result.frameID, scene.frame.frameID)
            XCTAssertEqual(result.source, scene.frame.source)
            XCTAssertEqual(try canonicalJSON(scene.frame), originalFrame)
            XCTAssertEqual(try canonicalJSON(scene.landmarks), originalLandmarks)
        }
    }

    func testRecoveredCenterKeepsNormalThreeDimensionalMidpointOnTiltedDepth() throws {
        var scene = scene(tilted: true)
        let baseline = try total(measure(scene))
        try removeDepth("neck_left", in: &scene)
        let centerPoint = try point("neck_center", in: scene).point
        let left = physicalPoint(try point("neck_left", in: scene).point, in: scene)
        let right = physicalPoint(try point("neck_right", in: scene).point, in: scene)
        let expectedCenter = Point3D(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2, z: (left.z + right.z) / 2)
        let expectedHem = physicalPoint(try point("hem_center", in: scene).point, in: scene)
        let total = try total(measure(scene))
        XCTAssertEqual(total.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(total.meters), distance(expectedCenter, expectedHem), accuracy: 0.00001)
        let center = try XCTUnwrap(total.points.first)
        XCTAssertEqual(try XCTUnwrap(total.meters), try XCTUnwrap(baseline.meters), accuracy: 0.00001)
        XCTAssertEqual(center.imagePoint.x, expectedCenter.x / expectedCenter.z + 0.5, accuracy: 0.00001)
        XCTAssertEqual(center.imagePoint.y, expectedCenter.y / expectedCenter.z + 0.5, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(center.imagePoint.x - centerPoint.x), 0.0001)
        XCTAssertEqual(center.position.x, expectedCenter.x, accuracy: 0.00001)
        XCTAssertEqual(center.position.y, expectedCenter.y, accuracy: 0.00001)
        XCTAssertEqual(center.position.z, expectedCenter.z, accuracy: 0.00001)
        XCTAssertEqual(center.quality.method, .recoveredSpatialAverage)
        XCTAssertEqual(total.points.last?.quality.method, .localPlane)
        XCTAssertNil(total.points.last?.sourceLandmarkIDs)
    }

    func testOneAndBothMissingDepthsPreserveNormalMidpointAcrossOppositeTwoAxisSlopes() throws {
        for (a, b) in [(0.65, 0.3), (-0.65, 0.3), (0.45, -0.3), (-0.45, -0.3)] {
            var original = scene()
            original.inverseDepthX = a
            original.inverseDepthY = b
            let size = original.frame.depth.size
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let rx = (Double(x) + 0.5) / Double(size.width) - 0.5
                    let ry = (Double(y) + 0.5) / Double(size.height) - 0.5
                    original.frame.depth.values[y * size.width + x] = Float(1 / (a * rx + b * ry + original.inverseDepthConstant))
                }
            }
            let baseline = try total(measure(original))
            XCTAssertEqual(baseline.status, .valid)
            for missing in [["neck_left"], ["neck_right"], ["neck_left", "neck_right"]] {
                var recovered = original
                for id in missing { try removeDepth(id, in: &recovered) }
                let value = try total(measure(recovered))
                XCTAssertEqual(value.status, .uncertain)
                XCTAssertEqual(try XCTUnwrap(value.meters), try XCTUnwrap(baseline.meters), accuracy: 0.00001)
                XCTAssertEqual(try XCTUnwrap(value.points.first).imagePoint.x,
                               try XCTUnwrap(baseline.points.first).imagePoint.x, accuracy: 0.00001)
                XCTAssertEqual(try XCTUnwrap(value.points.first).imagePoint.y,
                               try XCTUnwrap(baseline.points.first).imagePoint.y, accuracy: 0.00001)
            }
        }
    }

    func testCentralPlaneDoesNotExtrapolateToNeckEndpointsWithoutTheirOwnSupport() throws {
        var scene = scene(tilted: true)
        let originalDepth = scene.frame.depth.values
        scene.frame.depth.values = .init(repeating: 0, count: originalDepth.count)
        let size = scene.frame.depth.size
        for id in ["neck_center", "hem_center"] {
            let point = try point(id, in: scene).point
            let x = Int(point.x * Double(size.width)), y = Int(point.y * Double(size.height))
            for row in (y - 3)...(y + 3) {
                for column in (x - 3)...(x + 3) {
                    scene.frame.depth.values[row * size.width + column] = originalDepth[row * size.width + column]
                }
            }
        }
        let value = try total(measure(scene))
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertNil(value.meters)
    }

    func testRecoveryFitsEachNeckEndpointRatherThanSharingTheCentralClothPlane() throws {
        var scene = scene()
        let size = scene.frame.depth.size
        for y in 0..<size.height {
            for x in 0..<size.width {
                let rx = (Double(x) + 0.5) / Double(size.width) - 0.5
                let ry = (Double(y) + 0.5) / Double(size.height) - 0.5
                if x < 124 {
                    scene.frame.depth.values[y * size.width + x] = Float(1 / (1 / 1.2 + 0.4 * (rx + 0.05) + 0.15 * (ry + 0.2)))
                } else if x > 132 {
                    scene.frame.depth.values[y * size.width + x] = Float(1 / (1 / 1.6 - 0.3 * (rx - 0.05) + 0.2 * (ry + 0.2)))
                }
            }
        }
        let baseline = try total(measure(scene))
        let expected = Point3D(x: (-0.05 * 1.2 + 0.05 * 1.6) / 2,
                               y: (-0.2 * 1.2 - 0.2 * 1.6) / 2, z: (1.2 + 1.6) / 2)
        for id in ["neck_left", "neck_right"] { try removeDepth(id, in: &scene) }
        let value = try total(measure(scene))
        let center = try XCTUnwrap(value.points.first)
        XCTAssertEqual(value.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(value.meters), try XCTUnwrap(baseline.meters), accuracy: 0.00001)
        XCTAssertEqual(center.position.x, expected.x, accuracy: 0.00001)
        XCTAssertEqual(center.position.y, expected.y, accuracy: 0.00001)
        XCTAssertEqual(center.position.z, expected.z, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(center.position.x), 0.005, "The central body plane must not replace either neckline surface")
    }

    func testLegacyCentralPlaneRecoveryArchiveKeepsItsOriginalOverlay() throws {
        let scene = scene(tilted: true)
        var legacy = measure(scene)
        let originalCenter = try point("neck_center", in: scene).point
        var center = try XCTUnwrap(legacy.values[5].points.first)
        center.imagePoint = originalCenter
        center.position = physicalPoint(originalCenter, in: scene)
        center.quality.method = .localPlane
        center.quality.viewingAngleDegrees = nil
        center.quality.sampleRadiusPixels = nil
        center.quality.supportDistancePixels = nil
        center.recoverySourcePositions = nil
        legacy.algorithmVersion = "lidar-unprojection-1.2.0"
        legacy.values[5].points[0] = center
        legacy.values[5].status = .uncertain
        let restored = try JSONDecoder().decode(GarmentMeasurementResult.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(restored.values[5].points[0].recoverySourcePositions)
        let overlay = scene.landmarks.replacingDerivedImagePoints(with: restored)
        let shown = try XCTUnwrap(overlay.points.first { $0.id == "neck_center" })
        XCTAssertTrue(shown.isVisible)
        XCTAssertEqual(shown.point, originalCenter)
    }

    func testSupportedNeckSourcesKeepNormalSpatialAverageOnFlatAndTiltedPlanes() throws {
        for tilted in [false, true] {
            let scene = scene(tilted: tilted)
            let left = physicalPoint(try point("neck_left", in: scene).point, in: scene)
            let right = physicalPoint(try point("neck_right", in: scene).point, in: scene)
            let center = Point3D(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2, z: (left.z + right.z) / 2)
            let hem = physicalPoint(try point("hem_center", in: scene).point, in: scene)
            let total = try total(measure(scene))
            XCTAssertEqual(total.status, .valid)
            XCTAssertEqual(try XCTUnwrap(total.meters), distance(center, hem), accuracy: 0.00001)
            XCTAssertEqual(total.points.first?.quality.method, .spatialAverage)
            XCTAssertEqual(total.points.first?.sourceLandmarkIDs, ["neck_left", "neck_right"])
            var unknownModel = scene
            unknownModel.landmarks.modelVersion = "another-top-model"
            XCTAssertEqual(try XCTUnwrap(try self.total(measure(unknownModel)).meters), try XCTUnwrap(total.meters))
        }
    }

    func testUnsafeModelGeometryAndUnknownSchemasRemainUnavailable() throws {
        let cases: [(String, (inout Scene) throws -> Void, MeasurementFailure)] = [
            ("low confidence", { scene in
                try self.update("neck_right", in: &scene) { $0.confidence = 0.49 }
            }, .insufficientDepth),
            ("unknown confidence", { scene in
                try self.update("neck_right", in: &scene) { $0.confidence = nil }
            }, .insufficientDepth),
            ("occluded source", { scene in
                try self.update("neck_right", in: &scene) { $0.isVisible = false }
            }, .insufficientDepth),
            ("missing source", { $0.landmarks.points.removeAll { $0.id == "neck_right" } }, .insufficientDepth),
            ("duplicate source", { scene in scene.landmarks.points.append(try self.point("neck_right", in: scene)) }, .insufficientDepth),
            ("invalid source coordinate", { scene in
                try self.update("neck_right", in: &scene) { $0.point.x = 1 }
            }, .insufficientDepth),
            ("edited midpoint", { scene in
                try self.update("neck_center", in: &scene) { $0.point.x += 0.01 }
            }, .insufficientDepth),
            ("reversed source graph", { scene in
                try self.update("neck_center", in: &scene) { $0.derivedFrom = ["neck_right", "neck_left"] }
            }, .insufficientDepth),
            ("different source graph", { scene in
                try self.update("neck_center", in: &scene) { $0.derivedFrom = ["shoulder_left", "neck_left"] }
            }, .insufficientDepth),
            ("manual source", { scene in
                try self.update("neck_right", in: &scene) { $0.origin = .manual }
            }, .insufficientDepth),
            ("unknown model", { $0.landmarks.modelVersion = "another-top-model" }, .insufficientDepth),
            ("unknown kind", { $0.landmarks.garmentKind = nil }, .insufficientDepth),
            ("bottom kind", { $0.landmarks.garmentKind = .bottoms }, .insufficientDepth),
            ("synthetic-origin points", { $0.landmarks.origin = .synthetic }, .insufficientDepth),
            ("no mask", { $0.landmarks.mask = nil }, .insufficientDepth),
            ("center in mask hole", { scene in
                let point = try self.point("neck_center", in: scene).point
                let width = try XCTUnwrap(scene.landmarks.mask?.size.width)
                let height = try XCTUnwrap(scene.landmarks.mask?.size.height)
                scene.landmarks.mask?.values[Int(point.y * Double(height)) * width + Int(point.x * Double(width))] = 0
            }, .insufficientDepth),
            ("center depth hole", { try self.removeDepth("neck_center", in: &$0) }, .insufficientDepth),
            ("center low confidence", { scene in
                try self.update("neck_center", in: &scene) { $0.confidence = 0.49 }
            }, .lowLandmarkConfidence),
            ("center occluded", { scene in
                try self.update("neck_center", in: &scene) { $0.isVisible = false }
            }, .occludedLandmark)
        ]
        for (name, edit, failure) in cases {
            var scene = scene()
            try removeDepth("neck_left", in: &scene)
            try edit(&scene)
            let total = try total(measure(scene))
            XCTAssertEqual(total.status, .unavailable, name)
            XCTAssertNil(total.meters, name)
            XCTAssertEqual(total.failure, failure, name)
        }
    }

    func testConfidenceOcclusionAndMissingFailuresAreNotConvertedToDepthRecovery() throws {
        for (name, expectedFailure) in [("confidence", MeasurementFailure.lowLandmarkConfidence),
                                       ("occluded", .occludedLandmark), ("missing", .missingLandmark)] {
            var scene = scene()
            switch name {
            case "confidence": try update("neck_left", in: &scene) { $0.confidence = 0.49 }
            case "occluded": try update("neck_left", in: &scene) { $0.isVisible = false }
            default: scene.landmarks.points.removeAll { $0.id == "neck_left" }
            }
            let total = try total(measure(scene))
            XCTAssertEqual(total.status, .unavailable)
            XCTAssertEqual(total.failure, expectedFailure)
            XCTAssertNil(total.meters)
            XCTAssertTrue(total.pointFailures?.contains(.init(landmarkID: "neck_left", reason: expectedFailure)) == true)
        }
    }

    func testRecoveryRequiresLocalPlaneRatherThanMedianOrCollinearSupport() throws {
        var scene = scene()
        try removeDepth("neck_left", in: &scene)
        var options = MeasurementOptions()
        options.useLocalPlane = false
        XCTAssertEqual(try total(measure(scene, options: options)).failure, .insufficientDepth)
        try removeDepth("neck_center", in: &scene)
        let point = try point("neck_center", in: scene).point
        let width = scene.frame.depth.size.width
        let x = Int(point.x * Double(width)), y = Int(point.y * Double(scene.frame.depth.size.height))
        for row in (y - 3)...(y + 3) { scene.frame.depth.values[row * width + x] = 1.4 }
        XCTAssertEqual(try total(measure(scene)).failure, .insufficientDepth)
        XCTAssertNil(try total(measure(scene)).meters)
    }

    func testHemDepthFailureIsNotRepairedByNeckRecovery() throws {
        for alsoMissingNeck in [false, true] {
            var scene = scene()
            if alsoMissingNeck { try removeDepth("neck_left", in: &scene) }
            try removeDepth("hem_center", in: &scene)
            let total = try total(measure(scene))
            XCTAssertEqual(total.status, .unavailable)
            XCTAssertEqual(total.failure, .insufficientDepth)
            XCTAssertNil(total.meters)
            XCTAssertEqual(total.pointFailures, [.init(landmarkID: "hem_center", reason: .insufficientDepth)],
                "A recovered neck must not be listed as a final failed contributor")
        }
    }

    func testLegacyProjectedTopAndBottomDerivationsKeepOriginalFailureBehavior() throws {
        var projected = scene()
        try removeDepth("neck_left", in: &projected)
        projected.definitions[5].projection = .init(referenceAxisLandmarkIDs: ["neck_left", "neck_right"])
        XCTAssertEqual(try total(measure(projected)).failure, .insufficientDepth)
        var bottom = projected
        bottom.landmarks.garmentKind = .bottoms
        bottom.landmarks.modelVersion = AutomaticGarmentKind.bottoms.modelVersion
        for index in bottom.landmarks.points.indices {
            switch bottom.landmarks.points[index].id {
            case "neck_left": bottom.landmarks.points[index].id = "waist_left"
            case "neck_right": bottom.landmarks.points[index].id = "waist_right"
            case "neck_center":
                bottom.landmarks.points[index].id = "waist_center"
                bottom.landmarks.points[index].derivedFrom = ["waist_left", "waist_right"]
            default: break
            }
        }
        bottom.definitions = [.init(id: "bottom.crotch.waist_center", title: "밑위", landmarkIDs: ["waist_center", "hem_center"])]
        let value = try XCTUnwrap(measure(bottom).values.first)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertNil(value.meters)
    }

    func testFallbackProvenanceAndOriginalDepthRoundTripAndReplay() throws {
        var scene = scene(tilted: true)
        try removeDepth("neck_left", in: &scene)
        let result = measure(scene)
        let record = SavedMeasurement(id: UUID(), savedAt: Date(timeIntervalSince1970: 1),
            snapshot: .init(frame: scene.frame, imageJPEG: Data()), landmarks: scene.landmarks,
            definitions: scene.definitions, result: result, referenceCentimeters: nil, options: .init())
        let restored = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(record))
        let restoredTotal = try total(restored.result)
        XCTAssertEqual(restoredTotal.status, .uncertain)
        XCTAssertEqual(restoredTotal.points.first?.quality.method, .recoveredSpatialAverage)
        XCTAssertEqual(restoredTotal.points.first?.sourceLandmarkIDs, ["neck_left", "neck_right"])
        XCTAssertEqual(restored.landmarks.points.first { $0.id == "neck_center" }?.derivedFrom, ["neck_left", "neck_right"])
        XCTAssertEqual(restored.snapshot.frame.depth.values, scene.frame.depth.values)
        XCTAssertEqual(restored.snapshot.frame.depth.confidence, scene.frame.depth.confidence)
        let replay = LiDARMeasurementEngine().measure(frame: restored.snapshot.frame,
            landmarks: restored.landmarks, definitions: restored.definitions)
        XCTAssertEqual(replay.algorithmVersion, LiDARMeasurementEngine.algorithmVersion)
        XCTAssertEqual(try total(replay).status, .uncertain)
        XCTAssertEqual(try total(replay).meters, restoredTotal.meters)
        XCTAssertEqual(try total(replay).points.first?.sourceLandmarkIDs, ["neck_left", "neck_right"])
        let automatic = AutomaticMeasurement(record: restored)
        let center = try XCTUnwrap(automatic.displayLandmarks.points.first { $0.id == "neck_center" })
        XCTAssertTrue(center.isVisible)
        XCTAssertEqual(center.point, try XCTUnwrap(restoredTotal.points.first).imagePoint)
        XCTAssertTrue(automatic.visibleEditableLandmarks.points.contains { $0.id == "neck_center" && $0.isVisible })
        var manual = try XCTUnwrap(automatic.manualMeasurement(for: "top.totalLength"))
        let manualResult = LiDARMeasurementEngine().measure(frame: manual.snapshot.frame,
            landmarks: manual.landmarks, definitions: [manual.definition])
        XCTAssertTrue(manual.apply(manualResult, for: manual.calculationRevision))
        XCTAssertTrue(manual.displayLandmarks.points.contains { $0.id == "neck_center" && $0.isVisible && $0.point == center.point })
        XCTAssertEqual(manualResult.values.first?.status, .uncertain)
        XCTAssertEqual(manualResult.values.first?.points.first?.quality.method, .recoveredSpatialAverage)
    }

    func testOverlayRecoveryRequiresMatchingFrameAndActualSupportedMidpointProvenance() throws {
        var scene = scene()
        try removeDepth("neck_left", in: &scene)
        let result = measure(scene)
        let shown = scene.landmarks.replacingDerivedImagePoints(with: result)
        XCTAssertTrue(try XCTUnwrap(shown.points.first { $0.id == "neck_center" }).isVisible)
        let cases: [(String, (inout GarmentMeasurementResult) -> Void)] = [
            ("wrong frame", { $0.frameID = UUID() }),
            ("wrong session", { $0.sessionID = UUID() }),
            ("no resolved center", { $0.values[5].points.removeAll { $0.id == "neck_center" } }),
            ("median depth", { $0.values[5].points[0].quality.method = .robustMedian }),
            ("missing source IDs", { $0.values[5].points[0].sourceLandmarkIDs = nil }),
            ("wrong source IDs", { $0.values[5].points[0].sourceLandmarkIDs = ["shoulder_left", "neck_right"] }),
            ("unsupported plane", { $0.values[5].points[0].quality.planeResidualMeters = nil }),
            ("no samples", { $0.values[5].points[0].quality.validSamples = 0 }),
            ("missing recovered source positions", { $0.values[5].points[0].recoverySourcePositions = nil }),
            ("wrong recovered midpoint", { $0.values[5].points[0].position.x += 0.01 }),
            ("moved center", { $0.values[5].points[0].imagePoint.x += 0.01 })
        ]
        for (name, edit) in cases {
            var invalid = result
            edit(&invalid)
            let displayed = scene.landmarks.replacingDerivedImagePoints(with: invalid)
            XCTAssertFalse(try XCTUnwrap(displayed.points.first { $0.id == "neck_center" }).isVisible, name)
        }
        var unknownSchema = scene.landmarks
        unknownSchema.modelVersion = "another-top-model"
        XCTAssertFalse(try XCTUnwrap(unknownSchema.replacingDerivedImagePoints(with: result).points.first {
            $0.id == "neck_center"
        }).isVisible)
        try removeDepth("neck_center", in: &scene)
        let unavailable = measure(scene)
        XCTAssertEqual(try total(unavailable).status, .unavailable)
        XCTAssertFalse(try XCTUnwrap(scene.landmarks.replacingDerivedImagePoints(with: unavailable).points.first {
            $0.id == "neck_center"
        }).isVisible)
    }
}
