// Created by mason on 11/9/26.
import CoreGraphics
import XCTest
@testable import Dobby

final class CameraPhotoPreviewLayoutTests: XCTestCase {
    func testMeasurementSourceCropAndDetailSharePhotoAndControlPlacement() throws {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 390, height: 844),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956),
                     CGSize(width: 874, height: 402)] {
            let landscape = size.width > size.height
            let orientation: ImageOrientation = landscape ? .up : .right
            let source = PixelSize(width: 1920, height: 1440)
            let sourceRatio = landscape ? 4.0 / 3 : 3.0 / 4
            for ratio in DetailPhotoAspectRatio.allCases {
                let measurementRatio = try XCTUnwrap(MeasurementPhotoAspectRatio(rawValue: ratio.rawValue))
                let crop = try XCTUnwrap(measurementRatio.displayCrop(imageSize: source, orientation: orientation))
                let measurement = CameraPhotoPreviewLayout(containerSize: size,
                    photoAspectRatio: sourceRatio * crop.width / crop.height,
                    prefersBottomAlignedPortrait: ratio == .sixteenNine)
                let detail = DetailCameraPreviewLayout(containerSize: size, aspectRatio: ratio,
                    prefersBottomAlignedPortrait: true)
                assertRect(measurement.photoFrame, detail.photoFrame)
                assertRect(detail.previewFrame, detail.photoFrame)
                let lhs = try XCTUnwrap(measurement.controls(in: size, bottomSafeAreaInset: 34))
                let rhs = try XCTUnwrap(detail.controls(in: size, bottomSafeAreaInset: 34))
                for (a, b) in [(lhs.shutter, rhs.shutter), (lhs.more, rhs.more), (lhs.accessory, rhs.accessory)] {
                    XCTAssertEqual(a.x, b.x, accuracy: 0.001)
                    XCTAssertEqual(a.y, b.y, accuracy: 0.001)
                    XCTAssertEqual(a.width, b.width, accuracy: 0.001)
                    XCTAssertEqual(a.height, b.height, accuracy: 0.001)
                }
            }
        }
    }

    func testPortraitSixteenNinePreservesFullSensorHeightWithoutHeaderCrop() throws {
        let size = CGSize(width: 402, height: 874)
        let layout = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .sixteenNine,
            prefersBottomAlignedPortrait: true)
        // Synthetic upright 4:3 sensor: independently derive aspect-fill's visible region.
        // This checks geometry only, not a live lens or AVFoundation photo output.
        let source = CGSize(width: 3024, height: 4032)
        let scale = max(layout.previewFrame.width / source.width, layout.previewFrame.height / source.height)
        let visible = CGSize(width: layout.previewFrame.width / scale, height: layout.previewFrame.height / scale)
        let region = CGRect(x: (source.width - visible.width) / (2 * source.width),
            y: (source.height - visible.height) / (2 * source.height),
            width: visible.width / source.width, height: visible.height / source.height)
        XCTAssertEqual(region.minY, 0, accuracy: 0.000001)
        XCTAssertEqual(region.height, 1, accuracy: 0.000001)
        XCTAssertEqual(region.minX, 0.125, accuracy: 0.000001)
        XCTAssertEqual(region.width, 0.75, accuracy: 0.000001)
        let saved = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
            orientation: .right, aspectRatio: .sixteenNine, normalizedPreviewCrop: region))
        XCTAssertEqual(saved.cropRect, CGRect(x: 378, y: 0, width: 2268, height: 4032))
    }

    func testNavigationRoomThresholdAndNonNativeMeasurementRatio() {
        let photoHeight = 402.0 * 16 / 9
        for (room, expected) in [(119.0, false), (120.0, true)] {
            let layout = CameraPhotoPreviewLayout(containerSize: CGSize(width: 402, height: photoHeight + room),
                photoAspectRatio: 9.0 / 16, prefersBottomAlignedPortrait: true)
            XCTAssertEqual(layout.isBottomAligned, expected)
        }
        // Measurement's 4:3 option keeps a non-native source uncropped.
        let nonNative = CameraPhotoPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            photoAspectRatio: 0.8)
        XCTAssertFalse(nonNative.isBottomAligned)
        XCTAssertEqual(nonNative.photoFrame.width / nonNative.photoFrame.height, 0.8, accuracy: 0.000001)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
