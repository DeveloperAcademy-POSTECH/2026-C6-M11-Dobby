import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic camera-space fixtures, not real sensor or trained-model accuracy evidence.
final class DerivedLandmarkGeometryTests: XCTestCase {
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
        var definitions: [MeasurementDefinition]
    }

    private func scene(yawDegrees: Double = 45) throws -> Scene {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf:
            repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_bottom7.json")))
        let size = PixelSize(width: 800, height: 600)
        let geometry = try BottomLetterboxGeometry(originalSize: size, orientation: .up)
        let intrinsics = CameraIntrinsics(fx: 600, fy: 600, cx: 400, cy: 300, referenceSize: size)
        let angle = yawDegrees * .pi / 180
        let centerDepth = 0.6
        let halfWidth = 0.3
        let waistY = -0.1
        let positions: [Point3D] = [
            .init(x: -halfWidth * cos(angle), y: waistY, z: centerDepth - halfWidth * sin(angle)),
            .init(x: halfWidth * cos(angle), y: waistY, z: centerDepth + halfWidth * sin(angle)),
            .init(x: 0, y: 0.2, z: centerDepth),
            .init(x: -0.1, y: 0.25, z: centerDepth - 0.1 * tan(angle)),
            .init(x: -0.04, y: 0.25, z: centerDepth - 0.04 * tan(angle)),
            .init(x: 0.04, y: 0.25, z: centerDepth + 0.04 * tan(angle)),
            .init(x: 0.1, y: 0.25, z: centerDepth + 0.1 * tan(angle))
        ]
        let depthSize = PixelSize(width: 256, height: 192)
        var depths: [Float] = []
        for _ in 0..<depthSize.height {
            for x in 0..<depthSize.width {
                let imageX = (Double(x) + 0.5) * Double(size.width) / Double(depthSize.width)
                let rayX = (imageX - intrinsics.cx) / intrinsics.fx
                depths.append(Float(centerDepth / (1 - tan(angle) * rayX)))
            }
        }
        let sessionID = UUID(), frameID = UUID()
        let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 1,
            capturedAt: Date(timeIntervalSince1970: 1), imageSize: size, intrinsics: intrinsics,
            depth: .init(size: depthSize, values: depths,
                         confidence: .init(repeating: 2, count: depths.count)),
            source: .synthetic, orientation: .up)
        // Exact projected keypoints enter through the production decoder and bundled schema.
        var tensor = Array(repeating: 0.0, count: 26)
        tensor[0] = 320; tensor[1] = 320; tensor[2] = 400; tensor[3] = 400; tensor[4] = 0.99
        for (index, position) in positions.enumerated() {
            let point = project(position, frame: frame)
            tensor[5 + 3 * index] = Double(geometry.padLeft) + point.x * Double(geometry.resizedSize.width)
            tensor[6 + 3 * index] = Double(geometry.padTop) + point.y * Double(geometry.resizedSize.height)
            tensor[7 + 3 * index] = 0.99
        }
        let prediction = try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 26, 1], geometry: geometry) { channel, _ in
            tensor[channel]
        }
        return .init(frame: frame, landmarks: .init(sessionID: sessionID, frameID: frameID,
            origin: .model, modelVersion: "analytic-perfect-keypoints", points: prediction.points, mask: nil),
            definitions: Array(schema.measurementDefinitions.prefix(2)))
    }

    private func project(_ point: Point3D, frame: MeasurementFrame) -> ImagePoint {
        let k = frame.intrinsics
        return .init(x: (k.fx * point.x / point.z + k.cx) / Double(frame.imageSize.width),
                     y: (k.fy * point.y / point.z + k.cy) / Double(frame.imageSize.height))
    }

    private func measure(_ scene: Scene, options: MeasurementOptions = .init()) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: options).measure(frame: scene.frame,
            landmarks: scene.landmarks, definitions: scene.definitions)
    }

    private func rise(_ result: GarmentMeasurementResult) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == "bottom.crotch.waist_center" })
    }

    private func center(_ result: GarmentMeasurementResult) throws -> ResolvedLandmark {
        try XCTUnwrap(try rise(result).points.first { $0.id == "waist_center" })
    }

    private func update(_ id: String, in scene: inout Scene, _ edit: (inout GarmentLandmark) -> Void) throws {
        let index = try XCTUnwrap(scene.landmarks.points.firstIndex { $0.id == id })
        edit(&scene.landmarks.points[index])
    }

    private func removeDepth(around point: ImagePoint, from frame: inout MeasurementFrame) {
        let width = frame.depth.size.width, height = frame.depth.size.height
        let centerX = Int(point.x * Double(width)), centerY = Int(point.y * Double(height))
        for y in max(0, centerY - 5)...min(height - 1, centerY + 5) {
            for x in max(0, centerX - 5)...min(width - 1, centerX + 5) {
                frame.depth.values[y * width + x] = 0
            }
        }
    }

    func testSpatialWaistCenterKeepsThirtyCentimetreRiseOnFlatAndOppositelyTiltedPlanes() throws {
        for angle in [-45.0, -30, 0, 30, 45] {
            let scene = try scene(yawDegrees: angle)
            let result = measure(scene)
            XCTAssertEqual(result.algorithmVersion, "lidar-unprojection-1.0.2")
            XCTAssertEqual(try XCTUnwrap(result.values[0].meters), 0.6, accuracy: 0.00001, "yaw \(angle)")
            XCTAssertEqual(try XCTUnwrap(try rise(result).meters), 0.3, accuracy: 0.00001, "yaw \(angle)")
            XCTAssertEqual(try rise(result).status, .valid)
            XCTAssertNil(try rise(result).failure)
        }
    }

    func testKnownReviewCounterexampleDistinguishesImageMidpointFromSpatialMidpoint() throws {
        var old = try scene()
        let corrected = measure(old)
        try update("waist_center", in: &old) { $0.derivedFrom = nil }
        let oldResult = measure(old)
        // Removing explicit provenance deliberately reproduces the old 2D calculation.
        XCTAssertEqual(try XCTUnwrap(try rise(oldResult).meters), 0.318198, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(try rise(corrected).meters), 0.30, accuracy: 0.00001)
    }

    func testSpatialDerivationUsesBothSamplingModesOnTheSameFrozenFrame() throws {
        let scene = try scene(yawDegrees: 30)
        var baselineOptions = MeasurementOptions()
        baselineOptions.useLocalPlane = false
        let baseline = measure(scene, options: baselineOptions)
        let plane = measure(scene)
        XCTAssertEqual(baseline.frameID, plane.frameID)
        XCTAssertEqual(baseline.sessionID, plane.sessionID)
        XCTAssertEqual(try center(baseline).quality.method, .spatialAverage)
        XCTAssertEqual(try center(plane).quality.method, .spatialAverage)
        XCTAssertEqual(try rise(baseline).status, .uncertain)
        XCTAssertEqual(try rise(plane).status, .valid)
        // Median sampling retains pixel quantization; plane fitting resolves this
        // analytic plane exactly. Both paths must use the endpoint-derived center.
        XCTAssertEqual(try XCTUnwrap(try rise(baseline).meters), 0.3, accuracy: 0.003)
        XCTAssertEqual(try XCTUnwrap(try rise(plane).meters), 0.3, accuracy: 0.00001)
        // At 45 degrees, the far endpoint exceeds the unchanged median depth-spread
        // limit. The comparison must keep that unavailable outcome, not count it as
        // a valid measurement or relax a sensor threshold to obtain a number.
        let steep = try self.scene()
        let unavailableBaseline = measure(steep, options: baselineOptions)
        let steepPlane = measure(steep)
        XCTAssertEqual(unavailableBaseline.frameID, steepPlane.frameID)
        XCTAssertEqual(try rise(unavailableBaseline).failure, .insufficientDepth)
        XCTAssertNil(try rise(unavailableBaseline).meters)
        XCTAssertEqual(try XCTUnwrap(try rise(steepPlane).meters), 0.3, accuracy: 0.00001)
    }

    func testDerivedPointReprojectsItsSpatialPositionAndRecordsSourceIDs() throws {
        let scene = try scene()
        let placeholder = try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_center" })
        XCTAssertEqual(placeholder.derivedFrom, ["waist_left", "waist_right"])
        let resolved = try center(measure(scene))
        XCTAssertEqual(resolved.position.x, 0, accuracy: 0.00001)
        XCTAssertEqual(resolved.position.y, -0.1, accuracy: 0.00001)
        XCTAssertEqual(resolved.position.z, 0.6, accuracy: 0.00001)
        let expectedImagePoint = project(.init(x: 0, y: -0.1, z: 0.6), frame: scene.frame)
        XCTAssertEqual(resolved.imagePoint.x, expectedImagePoint.x, accuracy: 0.00001)
        XCTAssertEqual(resolved.imagePoint.y, expectedImagePoint.y, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(placeholder.point.x - resolved.imagePoint.x), 0.05)
        XCTAssertEqual(resolved.quality.method, .spatialAverage)
        XCTAssertEqual(resolved.sourceLandmarkIDs, ["waist_left", "waist_right"])
    }

    func testDerivedCenterDoesNotRequireDepthAtEitherImageMidpoint() throws {
        var scene = try scene()
        let placeholder = try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_center" })
        let spatialProjection = project(.init(x: 0, y: -0.1, z: 0.6), frame: scene.frame)
        removeDepth(around: placeholder.point, from: &scene.frame)
        removeDepth(around: spatialProjection, from: &scene.frame)
        let result = measure(scene)
        XCTAssertEqual(try rise(result).status, .valid)
        XCTAssertEqual(try XCTUnwrap(try rise(result).meters), 0.3, accuracy: 0.00001)
        // The unchanged direct sampler cannot obtain the old image midpoint from this frame.
        try update("waist_center", in: &scene) { $0.derivedFrom = nil }
        XCTAssertEqual(try rise(measure(scene)).failure, .insufficientDepth)
    }

    func testMissingDerivedSourceDoesNotFallBackToPlausibleImageDepthOrBreakWaistWidth() throws {
        var scene = try scene()
        try update("waist_center", in: &scene) { $0.derivedFrom = ["waist_left", "missing"] }
        let result = measure(scene)
        XCTAssertEqual(try rise(result).failure, .missingLandmark)
        XCTAssertNil(try rise(result).meters)
        XCTAssertEqual(result.values[0].status, .valid)
        XCTAssertEqual(try XCTUnwrap(result.values[0].meters), 0.6, accuracy: 0.00001)
    }

    func testBadSourceConfidenceVisibilityAndDepthPropagateWithoutBreakingIndependentMeasurement() throws {
        let cases: [(MeasurementFailure, (inout Scene) throws -> Void)] = [
            (.lowLandmarkConfidence, { scene in try self.update("waist_left", in: &scene) { $0.confidence = 0.1 } }),
            (.occludedLandmark, { scene in try self.update("waist_left", in: &scene) { $0.isVisible = false } }),
            (.insufficientDepth, { scene in
                let source = try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_left" })
                self.removeDepth(around: source.point, from: &scene.frame)
            })
        ]
        for (expectedFailure, edit) in cases {
            var scene = try scene()
            scene.definitions.append(.init(id: "independent", title: "Independent segment",
                                           landmarkIDs: ["crotch", "hem_left_inner"]))
            try edit(&scene)
            let result = measure(scene)
            XCTAssertEqual(try rise(result).failure, expectedFailure)
            XCTAssertEqual(try rise(result).status, .unavailable)
            XCTAssertNil(try rise(result).meters)
            XCTAssertEqual(result.values.last?.status, .valid)
            XCTAssertNotNil(result.values.last?.meters)
        }
    }

    func testMissingConfidenceOnOneSourceCannotBecomeAValidDerivedMeasurement() throws {
        var scene = try scene()
        try update("waist_left", in: &scene) { $0.confidence = nil }
        // The derived placeholder still has 0.99 confidence; source uncertainty must survive it.
        let result = measure(scene)
        XCTAssertEqual(try rise(result).status, .uncertain)
        XCTAssertNotNil(try rise(result).meters)
        XCTAssertNil(try rise(result).failure)
    }

    func testMissingSensorConfidenceOnSourcesRemainsUncertain() throws {
        var scene = try scene()
        scene.frame.depth.confidence = nil
        let result = measure(scene)
        XCTAssertEqual(try rise(result).status, .uncertain)
        XCTAssertFalse(try center(result).quality.confidenceAvailable)
        XCTAssertEqual(try center(result).quality.method, .spatialAverage)
    }

    func testNonfiniteOrOutOfBoundsSourceCannotProduceDerivedResult() throws {
        for badConfidence in [false, true] {
            var scene = try scene()
            try update("waist_left", in: &scene) {
                if badConfidence { $0.confidence = .nan }
                else { $0.point = .init(x: -0.1, y: 0.5) }
            }
            let result = measure(scene)
            XCTAssertEqual(try rise(result).failure, badConfidence ? .lowLandmarkConfidence : .outOfBounds)
            XCTAssertNil(try rise(result).meters)
            XCTAssertNoThrow(try JSONEncoder().encode(result))
        }
    }

    func testMalformedDerivedConfidenceIsNotIgnored() throws {
        var scene = try scene()
        try update("waist_center", in: &scene) { $0.confidence = .nan }
        XCTAssertEqual(try rise(measure(scene)).failure, .lowLandmarkConfidence)
    }

    func testNestedDerivedPointsAverageEachLevelInThreeDimensions() throws {
        var scene = try scene()
        scene.landmarks.points.append(.init(id: "half_rise", point: .init(x: 0.25, y: 0.25),
            confidence: 0.99, derivedFrom: ["waist_center", "crotch"]))
        scene.definitions.append(.init(id: "half", title: "Half rise", landmarkIDs: ["half_rise", "crotch"]))
        let result = measure(scene)
        let value = try XCTUnwrap(result.values.last)
        XCTAssertEqual(value.status, .valid)
        XCTAssertEqual(try XCTUnwrap(value.meters), 0.15, accuracy: 0.00001)
        let point = try XCTUnwrap(value.points.first)
        XCTAssertEqual(point.position.x, 0, accuracy: 0.00001)
        XCTAssertEqual(point.position.y, 0.05, accuracy: 0.00001)
        XCTAssertEqual(point.position.z, 0.6, accuracy: 0.00001)
        XCTAssertEqual(point.sourceLandmarkIDs, ["waist_center", "crotch"])
    }

    func testMalformedDerivedSourceListsFailWithoutInventingWeights() throws {
        for sources in [[], ["waist_left"], ["waist_left", "waist_left"], ["", "waist_right"]] {
            var scene = try scene()
            try update("waist_center", in: &scene) { $0.derivedFrom = sources }
            let result = measure(scene)
            XCTAssertEqual(try rise(result).status, .unavailable, "sources \(sources)")
            XCTAssertEqual(try rise(result).failure, .invalidDefinition, "sources \(sources)")
            XCTAssertNil(try rise(result).meters)
            XCTAssertEqual(result.values[0].status, .valid)
        }
    }

    func testSelfAndIndirectCyclesAreRejectedWithoutRecursingForever() throws {
        for indirect in [false, true] {
            var scene = try scene()
            if indirect {
                scene.landmarks.points.append(.init(id: "loop", point: .init(x: 0.5, y: 0.5),
                    confidence: 0.99, derivedFrom: ["waist_center", "crotch"]))
                try update("waist_center", in: &scene) { $0.derivedFrom = ["loop", "waist_left"] }
            } else {
                try update("waist_center", in: &scene) { $0.derivedFrom = ["waist_center", "waist_left"] }
            }
            let result = measure(scene)
            XCTAssertEqual(try rise(result).failure, .invalidDefinition)
            XCTAssertEqual(try rise(result).status, .unavailable)
            XCTAssertNil(try rise(result).meters)
            XCTAssertEqual(result.values[0].status, .valid)
        }
    }

    func testDuplicatedSourceLandmarkIsNotSilentlySelected() throws {
        var scene = try scene()
        scene.landmarks.points.append(try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_left" }))
        let result = measure(scene)
        XCTAssertEqual(try rise(result).failure, .duplicateLandmark)
        XCTAssertNil(try rise(result).meters)
    }

    func testExcessiveSourceCountAndDependencyDepthAreBounded() throws {
        var excessiveSources = try scene()
        let source = try XCTUnwrap(excessiveSources.landmarks.points.first { $0.id == "waist_left" })
        let ids = (0..<65).map { "source_\($0)" }
        for id in ids {
            excessiveSources.landmarks.points.append(.init(id: id, point: source.point, confidence: 0.99))
        }
        try update("waist_center", in: &excessiveSources) { $0.derivedFrom = ids }
        XCTAssertEqual(try rise(measure(excessiveSources)).failure, .invalidDefinition)

        var deep = try scene()
        for index in 0..<70 {
            let next = index == 69 ? "waist_left" : "level_\(index + 1)"
            deep.landmarks.points.append(.init(id: "level_\(index)", point: source.point,
                confidence: 0.99, derivedFrom: [next, "waist_right"]))
        }
        try update("waist_center", in: &deep) { $0.derivedFrom = ["level_0", "waist_right"] }
        let result = measure(deep)
        XCTAssertEqual(try rise(result).failure, .invalidDefinition)
        XCTAssertNil(try rise(result).meters)
        XCTAssertEqual(result.values[0].status, .valid)
        // A recursion budget is contextual: exhausting it while resolving a deep
        // graph must not poison a perfectly usable endpoint needed by a later item.
        deep.definitions.reverse()
        deep.definitions.append(.init(id: "shallow_dependency", title: "Valid shallower dependency",
                                      landmarkIDs: ["level_60", "crotch"]))
        let reversed = measure(deep)
        XCTAssertEqual(try rise(reversed).failure, .invalidDefinition)
        XCTAssertEqual(reversed.values[1].status, .valid)
        XCTAssertEqual(try XCTUnwrap(reversed.values[1].meters), 0.6, accuracy: 0.00001)
        XCTAssertEqual(reversed.values[2].status, .valid)
        XCTAssertNotNil(reversed.values[2].meters)
    }

    func testDerivedMetadataAndResolvedProvenanceRoundTripThroughJSON() throws {
        var scene = try scene()
        scene.landmarks = try JSONDecoder().decode(GarmentLandmarkSet.self,
            from: JSONEncoder().encode(scene.landmarks))
        let input = try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_center" })
        XCTAssertEqual(input.derivedFrom, ["waist_left", "waist_right"])
        let result = measure(scene)
        let restored = try JSONDecoder().decode(GarmentMeasurementResult.self,
            from: JSONEncoder().encode(result))
        XCTAssertEqual(try center(restored).sourceLandmarkIDs, ["waist_left", "waist_right"])
        XCTAssertEqual(try center(restored).quality.method, .spatialAverage)
        XCTAssertEqual(try XCTUnwrap(try rise(restored).meters), 0.3, accuracy: 0.00001)
    }

    func testLegacyBottomModelWithoutDerivedFieldsRecomputesSpatialMidpoint() throws {
        var scene = try scene()
        scene.landmarks.modelVersion = "bottom7-976144d4d652"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.landmarks)) as? [String: Any])
        var points = try XCTUnwrap(object["points"] as? [[String: Any]])
        for index in points.indices { points[index].removeValue(forKey: "derivedFrom") }
        object["points"] = points
        scene.landmarks = try JSONDecoder().decode(GarmentLandmarkSet.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(try XCTUnwrap(scene.landmarks.points.first { $0.id == "waist_center" }).derivedFrom)
        XCTAssertEqual(try XCTUnwrap(try rise(measure(scene)).meters), 0.3, accuracy: 0.00001)
        XCTAssertEqual(try center(measure(scene)).sourceLandmarkIDs, ["waist_left", "waist_right"])
    }

    func testLegacyDerivationIsRestrictedToKnownModelVersionAndOrigin() throws {
        for (origin, version) in [(LandmarkOrigin.manual, "bottom7-976144d4d652"),
                                  (.synthetic, "bottom7-976144d4d652"), (.model, "another-model")] {
            var scene = try scene()
            scene.landmarks.origin = origin
            scene.landmarks.modelVersion = version
            try update("waist_center", in: &scene) { $0.derivedFrom = nil }
            let result = measure(scene)
            XCTAssertEqual(try XCTUnwrap(try rise(result).meters), 0.318198, accuracy: 0.00001)
            XCTAssertNotEqual(try center(result).quality.method, .spatialAverage)
            XCTAssertNil(try center(result).sourceLandmarkIDs)
        }
    }

    func testOldResolvedPointJSONStillDecodesWithoutSourceIDs() throws {
        let scene = try scene(yawDegrees: 0)
        let point = try XCTUnwrap(measure(scene).values.first?.points.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as? [String: Any])
        object.removeValue(forKey: "sourceLandmarkIDs")
        let restored = try JSONDecoder().decode(ResolvedLandmark.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.sourceLandmarkIDs)
        XCTAssertEqual(restored.position, point.position)
        XCTAssertEqual(restored.quality.method, .localPlane)
    }
}
