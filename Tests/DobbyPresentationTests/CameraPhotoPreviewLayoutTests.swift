// Created by mason on 11/9/26.
import CoreGraphics
import XCTest
@testable import Dobby

final class CameraPhotoPreviewLayoutTests: XCTestCase {
    func testMeasurementPhotoStartsBelowHeaderWithoutChangingPhotoSize() throws {
        for (size, top) in [(CGSize(width: 402, height: 874), CGFloat(146)),
                            (CGSize(width: 375, height: 667), CGFloat(108))] {
            let original = CameraPhotoPreviewLayout(containerSize: size, photoAspectRatio: 0.75)
            let placed = CameraPhotoPreviewLayout(containerSize: size, photoAspectRatio: 0.75,
                portraitPhotoTop: top)
            XCTAssertEqual(placed.photoFrame.minY, top)
            XCTAssertEqual(placed.photoFrame.size, original.photoFrame.size)
            XCTAssertEqual(placed.photoFrame.minX, original.photoFrame.minX)
            XCTAssertNotNil(placed.controls(in: size, bottomSafeAreaInset: 34))
            let detail = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .fourThree,
                prefersBottomAlignedPortrait: true, portraitPhotoTop: top)
            assertRect(placed.photoFrame, detail.photoFrame)
        }
        let tall = CameraPhotoPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            photoAspectRatio: 9.0 / 16, prefersBottomAlignedPortrait: true, portraitPhotoTop: 146)
        XCTAssertTrue(tall.isBottomAligned)
        XCTAssertEqual(tall.photoFrame.maxY, 874)
    }

    func testResultSquareUsesFigmaCenterWhileOtherRatiosKeepTheirHeaderGap() {
        let aspects: [CGFloat] = [0.75, 1, 9.0 / 16]
        for aspect in aspects {
            let layout = MeasurementResultLayout(size: CGSize(width: 402, height: 812),
                bottomSafeArea: 34, aspect: aspect, summaryHeight: 111, topSafeArea: 62)
            XCTAssertEqual(layout.photo.minY, aspect == 1 ? 156 : 84)
            XCTAssertEqual(layout.photo.width / layout.photo.height, aspect, accuracy: 0.000001)
        }
    }

    func testSquareResultCompositionUsesCaptureRatioWhenPresentationCropExpands() {
        let size = CGSize(width: 402, height: 812)
        let selected = MeasurementResultLayout(size: size, bottomSafeArea: 34,
            aspect: 1, summaryHeight: 111, captureAspect: 1, topSafeArea: 62, usesSheet: false)
        let expandedAspects: [CGFloat] = [3.0 / 4, 9.0 / 16, 0.8]
        for expandedAspect in expandedAspects {
            let expanded = MeasurementResultLayout(size: size, bottomSafeArea: 34,
                aspect: expandedAspect, summaryHeight: 111,
                captureAspect: 1, topSafeArea: 62, usesSheet: false)
            assertRect(expanded.photo, selected.photo)
            assertRect(expanded.summary, selected.summary)
            XCTAssertNil(expanded.sheetTop)
            XCTAssertEqual(expanded.magnifierBottomInset, 0)
        }
    }

    func testUpdatedShutterFitsSafeAreaAndDoesNotOverlapOtherControls() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956),
                     CGSize(width: 874, height: 402)] {
            for inset in [CGFloat(0), 34] {
                for ratio in DetailPhotoAspectRatio.allCases {
                    let layout = DetailCameraPreviewLayout(containerSize: size,
                        aspectRatio: ratio, prefersBottomAlignedPortrait: true)
                    let controls = try XCTUnwrap(layout.controls(in: size, bottomSafeAreaInset: inset))
                    let frames = [controls.shutter, controls.more, controls.accessory].map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    }
                    XCTAssertEqual(frames[0].size, CGSize(width: 98, height: 98))
                    XCTAssertEqual(frames[1].size, CGSize(width: 48, height: 48))
                    XCTAssertEqual(frames[2].size, CGSize(width: 48, height: 48))
                    let safeBounds = CGRect(x: 0, y: 0, width: size.width, height: size.height - inset)
                    for frame in frames { XCTAssertTrue(safeBounds.contains(frame)) }
                    for i in frames.indices {
                        for j in frames.indices where j > i {
                            XCTAssertFalse(frames[i].intersects(frames[j]))
                        }
                    }
                    let photo = layout.photoFrame
                    let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(
                        containerWidth: size.width, containerHeight: size.height,
                        photo: .init(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height),
                        shutter: controls.shutter))
                    let zoom = chrome.zoomFrame
                    let zoomRect = CGRect(x: zoom.x, y: zoom.y, width: zoom.width, height: zoom.height)
                    for frame in frames { XCTAssertFalse(zoomRect.intersects(frame)) }
                    if size.width <= size.height {
                        XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 0.001)
                        XCTAssertEqual(frames[0].midY, frames[2].midY, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testMeasurementSourceCropAndDetailSharePhotoAndControlPlacementForEveryRatio() throws {
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
                assertRect(detail.previewFrame, detail.photoFrame)
                XCTAssertEqual(Double(detail.photoFrame.width / detail.photoFrame.height),
                    sourceRatio * crop.width / crop.height, accuracy: 0.000001)
                assertRect(measurement.photoFrame, detail.photoFrame)
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

    func testMeasurementAndDetailSquareMatchTheSameFigmaPhotoAndControls() throws {
        let size = CGSize(width: 402, height: 874)
        let detail = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .square,
            prefersBottomAlignedPortrait: true, portraitPhotoTop: 146)
        assertRect(detail.photoFrame, CGRect(x: 0, y: 236, width: 402, height: 402))
        assertRect(detail.previewFrame, detail.photoFrame)
        assertRect(detail.photoRectInPreview, CGRect(x: 0, y: 0, width: 402, height: 402))
        XCTAssertFalse(detail.isBottomAligned)

        let measurement = CameraPhotoPreviewLayout(containerSize: size,
            photoAspectRatio: 1, portraitPhotoTop: 146)
        assertRect(measurement.photoFrame, CGRect(x: 0, y: 236, width: 402, height: 402))
        XCTAssertFalse(measurement.isBottomAligned)

        let controls = try XCTUnwrap(detail.controls(in: size, bottomSafeAreaInset: 34))
        let measurementControls = try XCTUnwrap(measurement.controls(in: size, bottomSafeAreaInset: 34))
        XCTAssertEqual(measurementControls, controls)
        func rect(_ frame: CameraPhotoViewport) -> CGRect {
            CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        assertRect(rect(controls.shutter), CGRect(x: 152, y: 712, width: 98, height: 98))
        assertRect(rect(controls.accessory), CGRect(x: 48, y: 737, width: 48, height: 48))
        assertRect(rect(controls.more), CGRect(x: 306, y: 737, width: 48, height: 48))

        let photo = detail.photoFrame
        let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(
            containerWidth: size.width, containerHeight: size.height,
            photo: .init(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height),
            guidanceHeight: 0, shutter: controls.shutter))
        assertRect(rect(chrome.zoomFrame), CGRect(x: 177, y: 574, width: 48, height: 48))
    }

    func testBothSquareCamerasAdaptToHeadersAndSafeAreasWithoutChangingTheirAspect() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            for headerTop in [CGFloat(108), 146, 180] {
                let detail = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .square,
                    portraitPhotoTop: headerTop)
                let measurement = CameraPhotoPreviewLayout(containerSize: size, photoAspectRatio: 1,
                    portraitPhotoTop: headerTop)
                let photo = detail.photoFrame
                assertRect(measurement.photoFrame, photo)
                XCTAssertGreaterThanOrEqual(photo.minY, headerTop)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(photo))
                XCTAssertEqual(photo.midX, size.width / 2, accuracy: 0.001)
                XCTAssertEqual(photo.width, photo.height, accuracy: 0.001)
                if (size.height - size.width) / 2 >= headerTop {
                    XCTAssertEqual(photo.midY, size.height / 2, accuracy: 0.001)
                    XCTAssertEqual(photo.width, size.width, accuracy: 0.001)
                }
                for inset in [CGFloat(0), 34] {
                    let controls = try XCTUnwrap(detail.controls(in: size, bottomSafeAreaInset: inset))
                    let measurementControls = try XCTUnwrap(measurement.controls(in: size,
                        bottomSafeAreaInset: inset))
                    XCTAssertEqual(measurementControls, controls)
                    let frames = [controls.shutter, controls.more, controls.accessory].map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    }
                    let safeBounds = CGRect(x: 0, y: headerTop, width: size.width,
                                            height: size.height - inset - headerTop)
                    for frame in frames { XCTAssertTrue(safeBounds.contains(frame)) }
                    for left in frames.indices {
                        for right in frames.indices where right > left {
                            XCTAssertFalse(frames[left].intersects(frames[right]))
                        }
                    }
                    // Compact screens place the complete row inside the photo;
                    // larger screens place it wholly below the photo.
                    let shutter = frames[0]
                    XCTAssertTrue(photo.contains(shutter) || shutter.minY >= photo.maxY + 16)
                }
            }
        }
        let compact = DetailCameraPreviewLayout(containerSize: CGSize(width: 320, height: 568),
            aspectRatio: .square, portraitPhotoTop: 300)
        assertRect(compact.photoFrame, CGRect(x: 26, y: 300, width: 268, height: 268))
    }

    func testSourceDerivedSquareRoundingKeepsTheSameCenteredPhotoAndControls() throws {
        let size = CGSize(width: 402, height: 874)
        let detail = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .square,
            portraitPhotoTop: 146)
        let detailControls = try XCTUnwrap(detail.controls(in: size, bottomSafeAreaInset: 34))
        // Measurement derives its ratio from sensor dimensions and crop
        // fractions. A floating-point residual must not select an older layout.
        for aspect in [1.0, 1 - 1e-12, 1 + 1e-12] {
            let measurement = CameraPhotoPreviewLayout(containerSize: size, photoAspectRatio: aspect,
                portraitPhotoTop: 146)
            assertRect(measurement.photoFrame, detail.photoFrame)
            XCTAssertEqual(Double(measurement.photoFrame.width / measurement.photoFrame.height),
                aspect, accuracy: 1e-9)
            let controls = try XCTUnwrap(measurement.controls(in: size, bottomSafeAreaInset: 34))
            XCTAssertEqual(controls.shutter.x, detailControls.shutter.x, accuracy: 0.001)
            XCTAssertEqual(controls.shutter.y, detailControls.shutter.y, accuracy: 0.001)
            XCTAssertEqual(controls.more.y, detailControls.more.y, accuracy: 0.001)
        }
    }

    func testCenteredSquareKeepsTheSameSensorCropAndSavedPhotoAspect() throws {
        let detail = DetailCameraPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            aspectRatio: .square, portraitPhotoTop: 146)
        let measurement = CameraPhotoPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            photoAspectRatio: 1, portraitPhotoTop: 146)
        assertRect(measurement.photoFrame, detail.previewFrame)
        let source = CGSize(width: 3024, height: 4032)
        let scale = max(detail.previewFrame.width / source.width, detail.previewFrame.height / source.height)
        let visible = CGSize(width: detail.previewFrame.width / scale, height: detail.previewFrame.height / scale)
        let region = CGRect(x: (source.width - visible.width) / (2 * source.width),
            y: (source.height - visible.height) / (2 * source.height),
            width: visible.width / source.width, height: visible.height / source.height)
        assertRect(region, CGRect(x: 0, y: 0.125, width: 1, height: 0.75))
        let saved = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
            orientation: .right, aspectRatio: .square, normalizedPreviewCrop: region))
        XCTAssertEqual(saved.outputPixelSize.width, saved.outputPixelSize.height)
        XCTAssertEqual(saved.outputPixelSize.width, 3024)
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
