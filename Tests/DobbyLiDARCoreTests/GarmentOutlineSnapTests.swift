import XCTest
@testable import DobbyLiDARCore

final class GarmentOutlineSnapTests: XCTestCase {
    private let maskSize = PixelSize(width: 200, height: 100)
    private let imageSize = PixelSize(width: 1200, height: 600)
    private func mask() -> GarmentMask {
        var values = [UInt8](repeating: 0, count: 20_000)
        for y in 20..<80 { for x in 40..<160 { values[y * 200 + x] = 1 } }
        return .init(size: maskSize, values: values)
    }

    func testInternalNearAndDistantPointsPreserveConfidenceAndAutomaticOrigin() throws {
        let points: [GarmentLandmark] = [
            .init(id: "inside", point: .init(x: 0.4, y: 0.4), confidence: 0.91),
            .init(id: "near", point: .init(x: 38.5 / 200, y: 40.5 / 100), confidence: 0.52),
            .init(id: "far", point: .init(x: 30.5 / 200, y: 40.5 / 100), confidence: 0.8),
            .init(id: "outside", point: .init(x: -0.01, y: 0.4), confidence: 0.9)
        ]
        let result = try GarmentOutlineSnap.apply(points: points, mask: mask(), imageSize: imageSize)
        XCTAssertEqual(result.points[0].point, points[0].point)
        XCTAssertEqual(result.points[1].point, .init(x: 40.5 / 200, y: 40.5 / 100))
        XCTAssertEqual(result.points[2].point, points[2].point)
        XCTAssertEqual(result.points[3].point, points[3].point)
        XCTAssertEqual(result.points.map(\.confidence), points.map(\.confidence))
        XCTAssertEqual(result.points.map(\.origin), points.map(\.origin))
        XCTAssertEqual(result.adjustments.count, 1)
        XCTAssertEqual(result.adjustments[0].distancePixels, 12, accuracy: 1e-9)
        XCTAssertEqual(result.adjustments[0].limitPixels, hypot(120, 60) * 0.03 * 6, accuracy: 1e-9)
        XCTAssertEqual(points[1].point.x, 38.5 / 200, "Raw value remains available, unchanged")
    }

    func testOnlyDirectAutomaticPointsMoveAndDerivedHintRefreshesWithoutManualMark() throws {
        let points: [GarmentLandmark] = [
            .init(id: "left", point: .init(x: 38.5 / 200, y: 0.4), confidence: 0.8),
            .init(id: "right", point: .init(x: 0.7, y: 0.4), confidence: 0.9),
            .init(id: "average", point: .init(x: 0.44625, y: 0.4), confidence: 0.8, derivedFrom: ["left", "right"]),
            .init(id: "manual", point: .init(x: 38.5 / 200, y: 0.4), confidence: nil, origin: .manual),
            .init(id: "contour", point: .init(x: 38.5 / 200, y: 0.4), confidence: nil, contourRule: .neckPerpendicularMaskV1)
        ]
        let result = try GarmentOutlineSnap.apply(points: points, mask: mask(), imageSize: imageSize)
        XCTAssertEqual(result.adjustments.map(\.landmarkID), ["left"])
        XCTAssertEqual(result.points[2].point.x, (result.points[0].point.x + 0.7) / 2, accuracy: 1e-12)
        XCTAssertNil(result.points[2].origin)
        XCTAssertEqual(result.points[2].confidence, 0.8)
        XCTAssertEqual(result.points[3].point, points[3].point)
        XCTAssertEqual(result.points[4].point, points[4].point)
    }

    func testEmptyInvalidAndMismatchedMasksFailRatherThanInventingContour() {
        XCTAssertThrowsError(try GarmentOutlineSnap.apply(points: [], mask: .init(size: maskSize,
            values: [UInt8](repeating: 0, count: 20_000)), imageSize: imageSize))
        XCTAssertThrowsError(try GarmentOutlineSnap.apply(points: [], mask: mask(), imageSize: .init(width: 600, height: 1200)))
        XCTAssertThrowsError(try GarmentOutlineSnap.apply(points: [], mask: .init(size: maskSize, values: [1]), imageSize: imageSize))
    }
}
