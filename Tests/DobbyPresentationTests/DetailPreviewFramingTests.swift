// Created by mason on 10/27/26.
import CoreGraphics
import XCTest
@testable import Dobby

final class DetailPreviewFramingTests: XCTestCase {
    func testSensorRectangleRotatesToUprightPhotoInEveryDeviceOrientation() throws {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for (angle, expected) in [(0.0, rect),
            (90, CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.3)),
            (180, CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.4)),
            (270, CGRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3))] {
            let actual = try XCTUnwrap(DetailPreviewCropMapping.uprightRect(rect, rotationAngle: angle))
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001)
        }
    }

    func testInvalidPreviewGeometryCannotProduceCaptureCrop() {
        XCTAssertNil(DetailPreviewCropMapping.uprightRect(.zero, rotationAngle: 90))
        XCTAssertNil(DetailPreviewCropMapping.uprightRect(CGRect(x: 2, y: 2, width: 1, height: 1), rotationAngle: 90))
        XCTAssertNil(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
            orientation: .right, aspectRatio: .square,
            normalizedPreviewCrop: CGRect(x: -0.1, y: 0, width: 1, height: 1)))
    }

    func testVisibleOffCenterAreaIsSavedInsteadOfWholeSensorCenter() throws {
        let region = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5)
        let crop = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4000, pixelHeight: 3000,
            orientation: .right, aspectRatio: .fourThree, normalizedPreviewCrop: region))
        XCTAssertEqual(crop.cropRect, CGRect(x: 750, y: 400, width: 1500, height: 2000))
        XCTAssertNotEqual(crop.cropRect.midY, crop.uprightPixelSize.height / 2)
    }

    func testEachRatioStaysInsideVisiblePixelsAfterOrientationAndRounding() throws {
        let region = CGRect(x: 0.17, y: 0.21, width: 0.64, height: 0.55)
        for raw in 1...8 {
            for ratio in DetailPhotoAspectRatio.allCases {
                let crop = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4033, pixelHeight: 3025,
                    orientation: try XCTUnwrap(CapturedAsset.Orientation(rawValue: raw)),
                    aspectRatio: ratio, normalizedPreviewCrop: region))
                let bounds = CGRect(x: region.minX * crop.uprightPixelSize.width,
                    y: region.minY * crop.uprightPixelSize.height,
                    width: region.width * crop.uprightPixelSize.width,
                    height: region.height * crop.uprightPixelSize.height)
                XCTAssertTrue(bounds.contains(crop.cropRect))
                XCTAssertEqual(crop.cropRect.width / crop.cropRect.height,
                    ratio.previewRatio(isLandscape: crop.uprightPixelSize.width > crop.uprightPixelSize.height),
                    accuracy: 0.0001)
            }
        }
    }
}
