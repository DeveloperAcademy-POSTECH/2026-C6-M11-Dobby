// Created by mason on 10/21/26.
import XCTest
import CoreGraphics
@testable import Dobby

final class DetailPhotoCropGeometryTests: XCTestCase {
    func testLandscapeKnownPixelCropsAndUnspecifiedRatio() throws {
        let expected: [(DetailPhotoAspectRatio?, CGRect)] = [
            (nil, CGRect(x: 0, y: 0, width: 4032, height: 3024)),
            (.fourThree, CGRect(x: 0, y: 0, width: 4032, height: 3024)),
            (.sixteenNine, CGRect(x: 0, y: 378, width: 4032, height: 2268)),
            (.square, CGRect(x: 504, y: 0, width: 3024, height: 3024))
        ]
        for (ratio, rect) in expected {
            let plan = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
                orientation: .up, aspectRatio: ratio))
            XCTAssertEqual(plan.cropRect, rect)
            XCTAssertEqual(plan.outputPixelSize, rect.size)
        }
    }
    func testAllEightEXIFOrientationsUseUprightCoordinatesIncludingMirrors() throws {
        for raw in 1...8 {
            let orientation = try XCTUnwrap(CapturedAsset.Orientation(rawValue: raw))
            let swapped = raw >= 5
            for ratio in DetailPhotoAspectRatio.allCases {
                let plan = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
                    orientation: orientation, aspectRatio: ratio))
                let reference = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: swapped ? 3024 : 4032,
                    pixelHeight: swapped ? 4032 : 3024, orientation: .up, aspectRatio: ratio))
                XCTAssertEqual(plan, reference)
                XCTAssertEqual(plan.uprightPixelSize, CGSize(width: swapped ? 3024 : 4032, height: swapped ? 4032 : 3024))
                if swapped, ratio == .sixteenNine {
                    XCTAssertEqual(plan.cropRect, CGRect(x: 378, y: 0, width: 2268, height: 4032))
                }
            }
        }
    }
    func testOddDimensionsStayInsideImageOnIntegerPixelsWithExactRatio() throws {
        for (width, height) in [(4031, 3023), (3023, 4031), (301, 301)] {
            for ratio in DetailPhotoAspectRatio.allCases {
                let plan = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: width, pixelHeight: height,
                    orientation: .up, aspectRatio: ratio))
                let rect = plan.cropRect
                XCTAssertTrue(CGRect(origin: .zero, size: plan.uprightPixelSize).contains(rect))
                XCTAssertEqual(rect, rect.integral)
                XCTAssertLessThanOrEqual(abs(rect.midX - CGFloat(width) / 2), 0.5)
                XCTAssertLessThanOrEqual(abs(rect.midY - CGFloat(height) / 2), 0.5)
                let parts: (CGFloat, CGFloat) = ratio == .fourThree ? (4, 3) : ratio == .sixteenNine ? (16, 9) : (1, 1)
                let horizontal = width > height ? parts.0 : parts.1
                let vertical = width > height ? parts.1 : parts.0
                XCTAssertEqual(rect.width * vertical, rect.height * horizontal)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(plan.normalizedCropRect))
                XCTAssertEqual(plan.normalizedCropRect.width * CGFloat(width), rect.width, accuracy: 1e-9)
                XCTAssertEqual(plan.normalizedCropRect.minY * CGFloat(height), rect.minY, accuracy: 1e-9)
            }
        }
    }
    func testUnspecifiedRatioPreservesOddDimensionsAndRotatedFullFrame() throws {
        let plan = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4031, pixelHeight: 3023,
            orientation: .rightMirrored, aspectRatio: nil))
        XCTAssertEqual(plan.cropRect, CGRect(x: 0, y: 0, width: 3023, height: 4031))
        XCTAssertEqual(plan.normalizedCropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func testInvalidAndTooSmallInputsDoNotUpscaleOrProduceInvalidRects() {
        for (width, height) in [(0, 3024), (4032, 0), (-1, 20), (Int.max, 20), (20, Int.max), (2, 2)] {
            XCTAssertNil(DetailPhotoCropGeometry(pixelWidth: width, pixelHeight: height,
                orientation: .up, aspectRatio: .sixteenNine))
        }
        XCTAssertNotNil(DetailPhotoCropGeometry(pixelWidth: 1, pixelHeight: 1, orientation: .up, aspectRatio: .square))
    }
}
