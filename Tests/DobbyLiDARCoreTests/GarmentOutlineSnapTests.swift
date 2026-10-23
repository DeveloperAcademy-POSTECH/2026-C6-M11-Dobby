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
        XCTAssertEqual(result.adjustments[0].method, "mask-nearest-3pct-v1")
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

    func testOnlyFourBottomHemPointsReceiveFivePercentBound() throws {
        // Six mask pixels are beyond 3% (4.02px), but within 5% (6.71px).
        let ids = ["hem_left_outer", "hem_left_inner", "hem_right_inner", "hem_right_outer",
                   "waist_left", "waist_right", "waist_front_center", "crotch",
                   "hem_left", "hem_right", "sleeve_end_left", "thigh_right"]
        let points = ids.map { GarmentLandmark(id: $0,
            point: .init(x: 34.5 / 200, y: 40.5 / 100), confidence: 0.73, origin: .model) }
        let result = try GarmentOutlineSnap.apply(points: points, mask: mask(), imageSize: imageSize)
        XCTAssertEqual(result.adjustments.map(\.landmarkID), Array(ids.prefix(4)))
        for index in points.indices {
            XCTAssertEqual(result.points[index].point, index < 4
                ? .init(x: 40.5 / 200, y: 40.5 / 100) : points[index].point)
            XCTAssertEqual(result.points[index].confidence, points[index].confidence)
            XCTAssertEqual(result.points[index].origin, points[index].origin)
        }
        for adjustment in result.adjustments {
            XCTAssertEqual(adjustment.distancePixels, 36, accuracy: 1e-9)
            XCTAssertEqual(adjustment.limitPixels, hypot(120, 60) * 0.05 * 6, accuracy: 1e-9)
            XCTAssertEqual(adjustment.method, "mask-nearest-5pct-v1")
        }
    }

    func testFivePercentStillPreservesFarInsideAndManualHemPoints() throws {
        let points: [GarmentLandmark] = [
            .init(id: "hem_left_outer", point: .init(x: 33.5 / 200, y: 40.5 / 100), confidence: 0.9),
            .init(id: "hem_left_inner", point: .init(x: 40.1 / 200, y: 40.1 / 100), confidence: 0.9),
            .init(id: "hem_right_inner", point: .init(x: 34.5 / 200, y: 40.5 / 100), origin: .manual)
        ]
        let result = try GarmentOutlineSnap.apply(points: points, mask: mask(), imageSize: imageSize)
        XCTAssertEqual(result.points.map(\.point), points.map(\.point))
        XCTAssertEqual(result.points.map(\.confidence), points.map(\.confidence))
        XCTAssertEqual(result.points.map(\.origin), points.map(\.origin))
        XCTAssertTrue(result.adjustments.isEmpty)
    }
}
