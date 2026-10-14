import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic synthetic depth and known surface normals only. These regressions
/// verify geometry and provenance, never physical iPhone accuracy or supported angles.
final class MeasurementAngleStabilityTests: XCTestCase {
    private struct Scene {
        var frame: MeasurementFrame
        var landmarks: GarmentLandmarkSet
    }

    private func ray(_ point: ImagePoint) -> Point3D {
        // Independent fixture camera: 800 x 600 RGB, focal lengths 600 px.
        .init(x: (point.x * 800 - 400) / 600,
              y: (point.y * 600 - 300) / 600, z: 1)
    }

    private func dot(_ first: Point3D, _ second: Point3D) -> Double {
        first.x * second.x + first.y * second.y + first.z * second.z
    }

    private func unit(_ point: Point3D) -> Point3D {
        let length = hypot(hypot(point.x, point.y), point.z)
        return .init(x: point.x / length, y: point.y / length, z: point.z / length)
    }

    private func planeDepth(normal: Point3D, through point: Point3D, at imagePoint: ImagePoint) -> Double {
        // Intersect the known 3D plane n . P = n . P0 with an unnormalized
        // optical ray. The returned value is axial Z, not a ray's range.
        dot(normal, point) / dot(normal, ray(imagePoint))
    }

    private func scene(
        first: ImagePoint = .init(x: 0.5, y: 0.5),
        second: ImagePoint = .init(x: 0.5, y: 0.7),
        foreground: (Int, Int) -> Bool = { _, _ in true },
        depthAt: (ImagePoint) -> Double
    ) -> Scene {
        let fixture = SyntheticFixtures.scene()
        var frame = fixture.frame, landmarks = fixture.landmarks
        let size = frame.depth.size
        var depths: [Float] = [], mask: [UInt8] = []
        for y in 0..<size.height {
            for x in 0..<size.width {
                let point = ImagePoint(x: (Double(x) + 0.5) / Double(size.width),
                                       y: (Double(y) + 0.5) / Double(size.height))
                depths.append(Float(depthAt(point)))
                mask.append(foreground(x, y) ? 1 : 0)
            }
        }
        frame.depth = .init(size: size, values: depths,
                            confidence: .init(repeating: 2, count: depths.count))
        landmarks.points = [.init(id: "A", point: first, confidence: 1),
                            .init(id: "B", point: second, confidence: 1)]
        landmarks.mask = .init(size: size, values: mask)
        return .init(frame: frame, landmarks: landmarks)
    }

    private func measure(_ scene: Scene, options: MeasurementOptions = .init()) throws -> MeasurementValue {
        let result = LiDARMeasurementEngine(options: options).measure(
            frame: scene.frame, landmarks: scene.landmarks, definitions: [.testDistance])
        XCTAssertEqual(result.source, .synthetic)
        return try XCTUnwrap(result.values.first)
    }

    func testSyntheticOneSidedMedianReducesTargetDepthBiasWithoutClaimingPlaneSupport() throws {
        let target = ImagePoint(x: 0.5, y: 0.5)
        let normal = Point3D(x: -0.2, y: 0, z: 1)
        let anchor = Point3D(x: 0, y: 0, z: 1.2)
        let scene = scene(first: target, second: .init(x: 0.6, y: 0.5),
                          foreground: { x, _ in x >= 80 }) {
            self.planeDepth(normal: normal, through: anchor, at: $0)
        }
        // Increasing a one-sided window must not move its fallback depth
        // farther into the sloping cloth. A full-window median would do so.
        for radius in [3, 6] {
            var options = MeasurementOptions()
            options.useLocalPlane = false
            options.sampleRadius = radius
            let value = try measure(scene, options: options)
            let first = try XCTUnwrap(value.points.first)
            let targetDepth = planeDepth(normal: normal, through: anchor, at: target)
            var wholeWindow: [Double] = []
            for y in (60 - radius)...(60 + radius) {
                for x in 80...(80 + radius) {
                    wholeWindow.append(Double(scene.frame.depth.values[y * 160 + x]))
                }
            }
            let sorted = wholeWindow.sorted(), middle = sorted.count / 2
            let wholeMedian = sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            XCTAssertLessThan(abs(first.position.z - targetDepth), 0.0015)
            XCTAssertLessThan(abs(first.position.z - targetDepth), abs(wholeMedian - targetDepth) / 2)
            XCTAssertEqual(value.status, .uncertain)
            XCTAssertEqual(first.quality.method, .robustMedian)
            XCTAssertEqual(first.quality.validSamples, options.minimumSamples)
            XCTAssertNil(first.quality.viewingAngleDegrees)
            XCTAssertEqual(first.quality.sampleRadiusPixels, radius)
            XCTAssertEqual(try XCTUnwrap(first.quality.supportDistancePixels), sqrt(0.5), accuracy: 1e-12)
        }
    }

    func testSyntheticKnownLocalNormalsReportFrontAndTwentyFiveDegreeViewAngles() throws {
        for degrees in [0.0, 25.0] {
            let radians = degrees * .pi / 180
            let normal = Point3D(x: sin(radians), y: 0, z: cos(radians))
            let scene = scene {
                self.planeDepth(normal: normal, through: .init(x: 0, y: 0, z: 1.2), at: $0)
            }
            let value = try measure(scene)
            let point = try XCTUnwrap(value.points.first)
            XCTAssertEqual(value.status, .valid)
            XCTAssertEqual(point.quality.method, .localPlane)
            XCTAssertEqual(try XCTUnwrap(point.quality.viewingAngleDegrees), degrees, accuracy: 0.01)
            XCTAssertEqual(point.position.z, 1.2, accuracy: 0.000002)
        }
    }

    func testSyntheticFrontPlaneAngleUsesTheOffAxisPointRay() throws {
        let first = ImagePoint(x: 0.72, y: 0.61)
        let scene = scene(first: first, second: .init(x: 0.65, y: 0.7)) { _ in 1.2 }
        let value = try measure(scene)
        let point = try XCTUnwrap(value.points.first)
        let opticalRay = ray(first)
        let expected = atan(hypot(opticalRay.x, opticalRay.y)) * 180 / .pi
        XCTAssertGreaterThan(expected, 15)
        XCTAssertEqual(point.quality.method, .localPlane)
        XCTAssertEqual(try XCTUnwrap(point.quality.viewingAngleDegrees), expected, accuracy: 0.00001)
    }

    func testSyntheticPlaneSupportDistanceExcludesTheRejectedClosestDepthSample() throws {
        let target = ImagePoint(x: 80.5 / 160, y: 60.5 / 120)
        let opticalRay = ray(target)
        let anchor = Point3D(x: opticalRay.x * 1.2, y: opticalRay.y * 1.2, z: 1.2)
        let normal = Point3D(x: -0.6, y: 0, z: 1)
        var scene = scene(first: target, second: .init(x: 0.65, y: 0.5)) {
            self.planeDepth(normal: normal, through: anchor, at: $0)
        }
        let baseline = try XCTUnwrap(measure(scene).points.first)
        XCTAssertEqual(baseline.quality.validSamples, 49)
        XCTAssertEqual(try XCTUnwrap(baseline.quality.supportDistancePixels), 0, accuracy: 1e-12)

        var originalWindow: [Float] = []
        for y in 57...63 {
            for x in 77...83 { originalWindow.append(scene.frame.depth.values[y * 160 + x]) }
        }
        let closestIndex = 60 * 160 + 80
        scene.frame.depth.values[closestIndex] += 0.006
        let corruptedDepth = scene.frame.depth.values[closestIndex]
        let orderedWindow = originalWindow.sorted()
        // The corruption lies in the middle half of the sloping window's raw
        // Z range. It is not a raw-depth tail; its departure from the local
        // surface, rather than its absolute depth, identifies it as an outlier.
        XCTAssertGreaterThan(corruptedDepth, orderedWindow[12])
        XCTAssertLessThan(corruptedDepth, orderedWindow[36])

        let value = try measure(scene)
        let point = try XCTUnwrap(value.points.first)
        XCTAssertEqual(value.status, .valid)
        XCTAssertEqual(point.quality.method, .localPlane)
        XCTAssertEqual(point.quality.validSamples, 48)
        XCTAssertEqual(point.position.z, 1.2, accuracy: 0.000002)
        // The rejected pixel lies exactly on the target ray. The nearest
        // retained supporting pixels are now one depth pixel away.
        XCTAssertEqual(try XCTUnwrap(point.quality.supportDistancePixels), 1, accuracy: 1e-12)
    }

    func testSyntheticTwoClothPatchesKeepIndependentLocalViewingAngles() throws {
        let first = ImagePoint(x: 0.375, y: 0.5), second = ImagePoint(x: 0.625, y: 0.5)
        let firstNormal = unit(ray(first)), secondRay = unit(ray(second))
        let radians = 25.0 * Double.pi / 180
        let secondNormal = Point3D(x: cos(radians) * secondRay.x + sin(radians) * secondRay.z,
                                  y: 0, z: -sin(radians) * secondRay.x + cos(radians) * secondRay.z)
        let firstAnchor = Point3D(x: ray(first).x * 1.2, y: 0, z: 1.2)
        let secondAnchor = Point3D(x: ray(second).x * 1.5, y: 0, z: 1.5)
        let scene = scene(first: first, second: second) { point in
            point.x < 0.5
                ? self.planeDepth(normal: firstNormal, through: firstAnchor, at: point)
                : self.planeDepth(normal: secondNormal, through: secondAnchor, at: point)
        }
        let value = try measure(scene)
        XCTAssertEqual(value.status, .valid)
        XCTAssertEqual(value.points.count, 2)
        for (point, degrees) in zip(value.points, [0.0, 25.0]) {
            XCTAssertEqual(point.quality.method, .localPlane)
            XCTAssertEqual(try XCTUnwrap(point.quality.viewingAngleDegrees), degrees, accuracy: 0.01)
        }
        let expected = hypot(firstAnchor.x - secondAnchor.x, firstAnchor.z - secondAnchor.z)
        XCTAssertEqual(try XCTUnwrap(value.meters), expected, accuracy: 0.000002)
    }

    func testLegacyPointQualityWithoutAngleOrSupportMetadataDecodesAsUnknown() throws {
        let legacy = Data("""
        {"validSamples":8,"candidateSamples":49,"confidenceAvailable":true,
         "depthSpreadMeters":0.001,"planeResidualMeters":0.0002,"method":"localPlane"}
        """.utf8)
        let quality = try JSONDecoder().decode(PointQuality.self, from: legacy)
        XCTAssertEqual(quality.method, .localPlane)
        XCTAssertEqual(quality.validSamples, 8)
        XCTAssertNil(quality.viewingAngleDegrees)
        XCTAssertNil(quality.sampleRadiusPixels)
        XCTAssertNil(quality.supportDistancePixels)
        let replay = try JSONDecoder().decode(PointQuality.self, from: JSONEncoder().encode(quality))
        XCTAssertNil(replay.viewingAngleDegrees)
        XCTAssertNil(replay.sampleRadiusPixels)
        XCTAssertNil(replay.supportDistancePixels)
    }
}
