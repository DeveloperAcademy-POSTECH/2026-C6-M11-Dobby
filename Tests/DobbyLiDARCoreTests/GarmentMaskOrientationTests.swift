import XCTest
@testable import DobbyLiDARCore

final class GarmentMaskOrientationTests: XCTestCase {
    private let rectangular = GarmentMask(size: .init(width: 4, height: 3), values: [
        1, 0, 1, 0,
        0, 1, 0, 0,
        1, 1, 0, 1
    ])

    func testRectangularMasksRotateBackInTheDeclaredDirection() throws {
        let expected: [(ImageOrientation, PixelSize, [UInt8])] = [
            (.up, .init(width: 4, height: 3), rectangular.values),
            (.right, .init(width: 3, height: 4), [0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 1]),
            (.down, .init(width: 4, height: 3), [1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 1]),
            (.left, .init(width: 3, height: 4), [1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0])
        ]
        for (orientation, size, values) in expected {
            let actual = try GarmentMaskOrientation.originalMask(fromUpright: rectangular, orientation: orientation)
            XCTAssertEqual(actual.size, size, "\(orientation)")
            XCTAssertEqual(actual.values, values, "\(orientation)")
        }
    }

    func testEveryPixelMatchesNormalizedPixelCenterCoordinateContract() throws {
        for size in [PixelSize(width: 4, height: 3), .init(width: 3, height: 5), .init(width: 1, height: 4)] {
            for orientation in ImageOrientation.allCases {
                for index in 0..<(size.width * size.height) {
                    var upright = GarmentMask(size: size, values: .init(repeating: 0, count: size.width * size.height))
                    upright.values[index] = 1
                    let original = try GarmentMaskOrientation.originalMask(fromUpright: upright, orientation: orientation)
                    XCTAssertEqual(original.values.filter { $0 == 1 }.count, 1)
                    for y in 0..<original.size.height {
                        for x in 0..<original.size.width {
                            let center = ImagePoint(x: (Double(x) + 0.5) / Double(original.size.width),
                                                    y: (Double(y) + 0.5) / Double(original.size.height))
                            let display = ImageCoordinateTransform.originalToDisplay(center, orientation: orientation)
                            let sourceX = Int(display.x * Double(size.width))
                            let sourceY = Int(display.y * Double(size.height))
                            XCTAssertEqual(original.values[y * original.size.width + x], upright.values[sourceY * size.width + sourceX],
                                           "\(size)/\(orientation)/\(x),\(y)/source \(index)")
                        }
                    }
                }
            }
        }
    }

    func testHolesAndForegroundAreaArePreservedWithoutInterpolation() throws {
        var mask = GarmentMask(size: .init(width: 5, height: 3), values: .init(repeating: 1, count: 15))
        mask.values[1] = 0; mask.values[6] = 0; mask.values[11] = 0
        for orientation in ImageOrientation.allCases {
            let restored = try GarmentMaskOrientation.originalMask(fromUpright: mask, orientation: orientation)
            XCTAssertEqual(restored.values.filter { $0 == 0 }.count, 3)
            XCTAssertEqual(restored.values.filter { $0 == 1 }.count, 12)
            // Rotate to upright again using the inverse quarter turn.
            let inverse: ImageOrientation
            switch orientation {
            case .up: inverse = .up
            case .right: inverse = .left
            case .down: inverse = .down
            case .left: inverse = .right
            }
            let roundTrip = try GarmentMaskOrientation.originalMask(fromUpright: restored, orientation: inverse)
            XCTAssertEqual(roundTrip, mask)
        }
    }

    func testIdentityReturnsAnIndependentValueAndAllBackgroundRemainsValid() throws {
        var copy = try GarmentMaskOrientation.originalMask(fromUpright: rectangular, orientation: .up)
        copy.values[0] = 0
        XCTAssertEqual(rectangular.values[0], 1)
        for orientation in ImageOrientation.allCases {
            let empty = GarmentMask(size: .init(width: 4, height: 3), values: .init(repeating: 0, count: 12))
            let restored = try GarmentMaskOrientation.originalMask(fromUpright: empty, orientation: orientation)
            XCTAssertEqual(restored.values, empty.values)
        }
    }

    func testMalformedDimensionsBuffersAndNonbinaryValuesAreRejectedBeforeIdentity() {
        let invalid: [GarmentMask] = [
            .init(size: .init(width: 0, height: 4), values: []),
            .init(size: .init(width: -1, height: 4), values: []),
            .init(size: .init(width: Int.max, height: 4), values: []),
            .init(size: .init(width: 16_385, height: 1), values: []),
            .init(size: .init(width: 4, height: 3), values: [0]),
            .init(size: .init(width: 1, height: 1), values: [2]),
            .init(size: .init(width: 1, height: 1), values: [255]),
            .init(size: .init(width: 2049, height: 2049), values: .init(repeating: 0, count: 2049 * 2049))
        ]
        for mask in invalid {
            for orientation in ImageOrientation.allCases {
                XCTAssertThrowsError(try GarmentMaskOrientation.originalMask(fromUpright: mask, orientation: orientation)) {
                    XCTAssertEqual($0 as? GarmentMaskAssociationError, .invalidMask)
                }
            }
        }
    }
}
