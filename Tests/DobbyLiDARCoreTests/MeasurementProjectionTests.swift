import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Exact analytic planes and landmarks, not physical cm-accuracy evidence.
final class MeasurementProjectionTests: XCTestCase {
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
        var definitions: [MeasurementDefinition]
        var projectedEnd: Point3D
    }

    private func schema() throws -> TopLandmarkSchema {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try .init(jsonData: Data(contentsOf: repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_top.json")))
    }

    private func scene(yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                       translation: Point3D = .init(x: 0, y: 0, z: 1.4)) throws -> Scene {
        func rotate(_ p: Point3D) -> Point3D {
            let a = yaw * .pi / 180, b = pitch * .pi / 180, c = roll * .pi / 180
            let q = Point3D(x: cos(a) * p.x + sin(a) * p.z, y: p.y, z: -sin(a) * p.x + cos(a) * p.z)
            let r = Point3D(x: q.x, y: cos(b) * q.y - sin(b) * q.z, z: sin(b) * q.y + cos(b) * q.z)
            return .init(x: cos(c) * r.x - sin(c) * r.y, y: sin(c) * r.x + cos(c) * r.y, z: r.z)
        }
        func transform(_ p: Point3D) -> Point3D {
            let p = rotate(p)
            return .init(x: p.x + translation.x, y: p.y + translation.y, z: p.z + translation.z)
        }
        let size = PixelSize(width: 800, height: 800)
        let k = CameraIntrinsics(fx: 500, fy: 500, cx: 400, cy: 400, referenceSize: size)
        let normal = rotate(.init(x: 0, y: 0, z: 1))
        let planeDistance = normal.x * translation.x + normal.y * translation.y + normal.z * translation.z
        let depthSize = PixelSize(width: 256, height: 256)
        var depths: [Float] = []
        for y in 0..<depthSize.height {
            for x in 0..<depthSize.width {
                let rayX = ((Double(x) + 0.5) * Double(size.width) / Double(depthSize.width) - k.cx) / k.fx
                let rayY = ((Double(y) + 0.5) * Double(size.height) / Double(depthSize.height) - k.cy) / k.fy
                let z = planeDistance / (normal.x * rayX + normal.y * rayY + normal.z)
                depths.append(z.isFinite && z >= 0.15 && z <= 3 ? Float(z) : 0)
            }
        }
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1,
            capturedAt: Date(timeIntervalSince1970: 1), imageSize: size, intrinsics: k,
            depth: .init(size: depthSize, values: depths, confidence: .init(repeating: 2, count: depths.count)),
            source: .synthetic, orientation: .up)
        let local: [Point3D] = [
            .init(x: -0.1, y: -0.2, z: 0), .init(x: 0.1, y: -0.2, z: 0),
            .init(x: -0.22, y: -0.17, z: 0), .init(x: 0.22, y: -0.17, z: 0),
            .init(x: -0.21, y: -0.06, z: 0), .init(x: 0.21, y: -0.06, z: 0),
            .init(x: -0.36, y: 0.06, z: 0), .init(x: 0.36, y: 0.06, z: 0),
            .init(x: -0.2, y: 0.3, z: 0), .init(x: 0.16, y: 0.3, z: 0), .init(x: 0.2, y: 0.3, z: 0)
        ]
        let schema = try schema()
        let geometry = try BottomLetterboxGeometry(originalSize: size, orientation: .up)
        var tensor = Array(repeating: 0.0, count: 38)
        tensor[0] = 320; tensor[1] = 320; tensor[2] = 400; tensor[3] = 500; tensor[4] = 0.99
        for (index, p) in local.enumerated() {
            let point = project(transform(p), frame: frame)
            tensor[5 + 3 * index] = point.x * Double(geometry.resizedSize.width)
            tensor[6 + 3 * index] = point.y * Double(geometry.resizedSize.height)
            tensor[7 + 3 * index] = 0.99
        }
        let prediction = try BottomLandmarkDecoder(schema: schema.decoderSchema).decode(shape: [1, 38, 1], geometry: geometry) { channel, _ in tensor[channel] }
        return .init(frame: frame, landmarks: .init(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: "analytic-perfect-top-keypoints", points: prediction.points, mask: nil),
            definitions: schema.measurementDefinitions, projectedEnd: transform(.init(x: 0, y: 0.3, z: 0)))
    }

    private func project(_ p: Point3D, frame: MeasurementFrame) -> ImagePoint {
        let k = frame.intrinsics
        return .init(x: (k.fx * p.x / p.z + k.cx) / Double(frame.imageSize.width),
                     y: (k.fy * p.y / p.z + k.cy) / Double(frame.imageSize.height))
    }

    private func result(_ scene: Scene, options: MeasurementOptions = .init()) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: options).measure(frame: scene.frame, landmarks: scene.landmarks, definitions: scene.definitions)
    }

    private func total(_ result: GarmentMeasurementResult) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == "top.totalLength" })
    }

    func testTotalLengthRemovesSidewaysHemDriftAndReprojectsPhysicalEndpoint() throws {
        let scene = try scene(yaw: 35, pitch: 20, roll: 25)
        let result = result(scene)
        let total = try total(result)
        XCTAssertEqual(try XCTUnwrap(total.meters), 0.5, accuracy: 0.00001)
        XCTAssertEqual(total.status, .valid)
        let end = try XCTUnwrap(total.points.last)
        XCTAssertEqual(end.id, "hem_center")
        XCTAssertEqual(end.quality.method, .axisProjection)
        XCTAssertEqual(end.sourceLandmarkIDs, ["neck_center", "hem_center", "neck_left", "neck_right"])
        XCTAssertEqual(end.position.x, scene.projectedEnd.x, accuracy: 0.00001)
        XCTAssertEqual(end.position.y, scene.projectedEnd.y, accuracy: 0.00001)
        XCTAssertEqual(end.position.z, scene.projectedEnd.z, accuracy: 0.00001)
        let projected = project(scene.projectedEnd, frame: scene.frame)
        XCTAssertEqual(end.imagePoint.x, projected.x, accuracy: 0.00001)
        XCTAssertEqual(end.imagePoint.y, projected.y, accuracy: 0.00001)
        var straight = scene
        straight.definitions[5].projection = nil
        XCTAssertEqual(try XCTUnwrap(try self.total(self.result(straight)).meters), hypot(0.5, 0.16), accuracy: 0.00001)
        XCTAssertGreaterThan(try XCTUnwrap(try self.total(self.result(straight)).meters), try XCTUnwrap(total.meters))
    }

    func testTotalLengthAndOtherMeasurementsAreInvariantUnderRigidCameraTransforms() throws {
        let expected = [0.44, 0.42, 0.4, hypot(0.14, 0.23), hypot(0.14, 0.23), 0.5]
        for (yaw, pitch, roll, translation) in [
            (0.0, 0.0, 0.0, Point3D(x: 0, y: 0, z: 1.4)),
            (35, 20, 25, .init(x: 0.05, y: -0.04, z: 1.5)),
            (-35, -20, -40, .init(x: -0.07, y: 0.06, z: 1.3)),
            (20, -30, 70, .init(x: 0, y: 0, z: 1.6))
        ] {
            let values = result(try scene(yaw: yaw, pitch: pitch, roll: roll, translation: translation)).values
            for (actual, expected) in zip(values, expected) {
                XCTAssertEqual(actual.status, .valid, "\(actual.id)/\(yaw),\(pitch),\(roll)")
                XCTAssertEqual(try XCTUnwrap(actual.meters), expected, accuracy: 0.00001)
            }
        }
    }

    func testInvalidReferenceAxisAffectsOnlyProjectedDefinition() throws {
        for scenario in 0..<5 {
            var scene = try scene()
            switch scenario {
            case 0: scene.definitions[5].projection?.referenceAxisLandmarkIDs = ["neck_left", "missing"]
            case 1: scene.definitions[5].projection?.referenceAxisLandmarkIDs = ["neck_left", "neck_left"]
            case 2: scene.definitions[5].projection?.referenceAxisLandmarkIDs = ["neck_left"]
            case 3:
                let left = try XCTUnwrap(scene.landmarks.points.first { $0.id == "neck_left" })
                let right = try XCTUnwrap(scene.landmarks.points.firstIndex { $0.id == "neck_right" })
                scene.landmarks.points[right].point = left.point
            default:
                let left = try XCTUnwrap(scene.landmarks.points.firstIndex { $0.id == "neck_left" })
                scene.landmarks.points[left].confidence = 0.49
            }
            let values = result(scene)
            XCTAssertEqual(try total(values).status, .unavailable)
            XCTAssertNil(try total(values).meters)
            XCTAssertEqual(try total(values).failure, scenario == 0 ? .missingLandmark : scenario == 4 ? .lowLandmarkConfidence : .invalidDefinition)
            XCTAssertTrue(values.values.dropLast().allSatisfy { $0.status == .valid && $0.meters != nil })
        }
    }

    func testProjectionPreservesUncertainDepthAndUnknownAxisConfidence() throws {
        var scene = try scene()
        let left = try XCTUnwrap(scene.landmarks.points.firstIndex { $0.id == "neck_left" })
        scene.landmarks.points[left].confidence = nil
        let unknown = try total(result(scene))
        XCTAssertEqual(unknown.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(unknown.meters), 0.5, accuracy: 0.00001)
        var options = MeasurementOptions(); options.useLocalPlane = false
        let median = try total(result(scene, options: options))
        XCTAssertEqual(median.status, .uncertain)
        XCTAssertEqual(try XCTUnwrap(median.meters), 0.5, accuracy: 0.00001)
        XCTAssertNil(median.points.last?.quality.planeResidualMeters)
    }

    func testOldDefinitionsDecodeAsStraightAndProjectionMetadataRoundTrips() throws {
        let oldJSON = Data("{\"id\":\"test\",\"title\":\"두 점 사이\",\"landmarkIDs\":[\"A\",\"B\"]}".utf8)
        let old = try JSONDecoder().decode(MeasurementDefinition.self, from: oldJSON)
        XCTAssertNil(old.projection)
        let definition = try XCTUnwrap(schema().measurementDefinitions.last)
        let restored = try JSONDecoder().decode(MeasurementDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(restored.projection, definition.projection)
        XCTAssertEqual(restored.landmarkIDs, definition.landmarkIDs)
        let scene = try scene(yaw: 25)
        let saved = SavedMeasurement(id: UUID(), savedAt: Date(timeIntervalSince1970: 1),
            snapshot: .init(frame: scene.frame, imageJPEG: Data()), landmarks: scene.landmarks,
            definitions: scene.definitions, result: result(scene), referenceCentimeters: nil, options: .init())
        let record = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(record.definitions.last?.projection, definition.projection)
        XCTAssertEqual(record.result.values.last?.points.last?.quality.method, .axisProjection)
        let replay = LiDARMeasurementEngine().measure(frame: record.snapshot.frame, landmarks: record.landmarks, definitions: record.definitions)
        XCTAssertEqual(try XCTUnwrap(try total(replay).meters), 0.5, accuracy: 0.00001)
    }
}
