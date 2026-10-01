import XCTest
@testable import DobbyLiDARCore

final class GarmentSilhouetteGeometryTests: XCTestCase {
    func testEmptyMaskHasNoContours() throws {
        let mask = GarmentMask(size: .init(width: 4, height: 3), values: .init(repeating: 0, count: 12))
        XCTAssertEqual(try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: mask)), [])
    }

    func testFullMaskUsesOriginalImageEdgesWithoutClosingPointDuplication() throws {
        let mask = GarmentMask(size: .init(width: 2, height: 3), values: .init(repeating: 1, count: 6))
        let contours = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: mask))
        XCTAssertEqual(contours, [[
            .init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)
        ]])
    }

    func testOffsetPixelRetainsOriginalCoordinatesAndAspectRatio() throws {
        var values = [UInt8](repeating: 0, count: 20)
        values[1 * 5 + 2] = 1
        let mask = GarmentMask(size: .init(width: 5, height: 4), values: values)
        let contours = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: mask))
        XCTAssertEqual(contours, [[
            .init(x: 0.4, y: 0.25), .init(x: 0.6, y: 0.25),
            .init(x: 0.6, y: 0.5), .init(x: 0.4, y: 0.5)
        ]])
    }

    func testMalformedMasksAreRejectedBeforeIndexing() {
        let masks: [GarmentMask] = [
            .init(size: .init(width: 0, height: 1), values: []),
            .init(size: .init(width: -1, height: 1), values: []),
            .init(size: .init(width: 1, height: -1), values: []),
            .init(size: .init(width: Int.max, height: Int.max), values: []),
            .init(size: .init(width: 513, height: 1), values: .init(repeating: 1, count: 513)),
            .init(size: .init(width: 1, height: 513), values: .init(repeating: 1, count: 513)),
            .init(size: .init(width: 2, height: 2), values: [1, 0, 1]),
            .init(size: .init(width: 2, height: 2), values: [1, 0, 1, 0, 1]),
            .init(size: .init(width: 1, height: 1), values: [2]),
            .init(size: .init(width: 1, height: 1), values: [255])
        ]
        for mask in masks {
            XCTAssertNil(GarmentSilhouetteGeometry.contours(from: mask))
        }
    }

    func testMaximumSizedSolidMaskCollapsesToFourCorners() throws {
        let mask = GarmentMask(size: .init(width: 512, height: 512),
                               values: .init(repeating: 1, count: 512 * 512))
        let contours = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: mask))
        XCTAssertEqual(contours.count, 1)
        XCTAssertEqual(contours[0].count, 4)
    }

    func testExcessivelyFragmentedMaskIsRejectedInsteadOfTruncated() {
        let size = 512
        let values = (0..<(size * size)).map { index -> UInt8 in
            (index % size + index / size).isMultiple(of: 2) ? 1 : 0
        }
        let mask = GarmentMask(size: .init(width: size, height: size), values: values)
        XCTAssertNil(GarmentSilhouetteGeometry.contours(from: mask))
    }
}
