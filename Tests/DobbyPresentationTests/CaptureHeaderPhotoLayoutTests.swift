import CoreGraphics
import XCTest
@testable import Dobby

final class CaptureHeaderPhotoLayoutTests: XCTestCase {
    func testFourThreeStartsBelowTheFigmaHeaderWithoutChangingItsAspectOrWidth() {
        let layout = CameraPhotoPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            photoAspectRatio: 3.0 / 4, minimumPhotoTop: 146)
        assertRect(layout.photoFrame, CGRect(x: 0, y: 146, width: 402, height: 536))
        XCTAssertFalse(layout.isBottomAligned)
    }

    func testAnAlreadyClearSquareOrBottomAlignedTallPhotoKeepsItsComposition() {
        let size = CGSize(width: 402, height: 874)
        let square = CameraPhotoPreviewLayout(containerSize: size,
            photoAspectRatio: 1, minimumPhotoTop: 146)
        assertRect(square.photoFrame, CGRect(x: 0, y: 177.25, width: 402, height: 402))

        let tall = CameraPhotoPreviewLayout(containerSize: size,
            photoAspectRatio: 9.0 / 16, prefersBottomAlignedPortrait: true, minimumPhotoTop: 146)
        XCTAssertTrue(tall.isBottomAligned)
        assertRect(tall.photoFrame, CGRect(x: 0, y: 874 - 402.0 * 16 / 9,
                                           width: 402, height: 402.0 * 16 / 9))
    }

    func testHeaderClearanceFitsTheWholePhotoAndKeepsCaptureControlsUsableOnSmallPhones() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            for aspect in [1.0, 3.0 / 4, 9.0 / 16] {
                let layout = CameraPhotoPreviewLayout(containerSize: size, photoAspectRatio: aspect,
                    prefersBottomAlignedPortrait: aspect == 9.0 / 16, minimumPhotoTop: 146)
                let photo = layout.photoFrame
                XCTAssertGreaterThan(photo.width, 0)
                XCTAssertGreaterThan(photo.height, 0)
                XCTAssertGreaterThanOrEqual(photo.minY, 146)
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(photo))
                XCTAssertEqual(photo.width / photo.height, aspect, accuracy: 0.000_001,
                               "Header clearance must scale the complete photograph rather than stretch or crop it")
                XCTAssertEqual(photo.midX, size.width / 2, accuracy: 0.001)

                let controls = try XCTUnwrap(layout.controls(in: size, bottomSafeAreaInset: 34))
                let frames = [controls.shutter, controls.more, controls.accessory].map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                }
                let usable = CGRect(x: 0, y: 0, width: size.width, height: size.height - 34)
                XCTAssertEqual(frames[0].size, CGSize(width: 98, height: 98))
                XCTAssertEqual(frames[1].size, CGSize(width: 48, height: 48))
                XCTAssertEqual(frames[2].size, CGSize(width: 48, height: 48))
                for frame in frames { XCTAssertTrue(usable.contains(frame)) }
                for left in frames.indices {
                    for right in frames.indices where right > left {
                        XCTAssertFalse(frames[left].intersects(frames[right]))
                    }
                }

                let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(
                    containerWidth: size.width, containerHeight: size.height,
                    photo: .init(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height),
                    shutter: controls.shutter))
                let zoom = chrome.zoomFrame
                let zoomRect = CGRect(x: zoom.x, y: zoom.y, width: zoom.width, height: zoom.height)
                XCTAssertTrue(photo.contains(zoomRect))
                for frame in frames { XCTAssertFalse(frame.intersects(zoomRect)) }
            }
        }
    }

    func testCompactHeaderClearanceScalesBothPhotoAxesByTheSameFactor() {
        let size = CGSize(width: 320, height: 568)
        let layout = CameraPhotoPreviewLayout(containerSize: size,
            photoAspectRatio: 3.0 / 4, minimumPhotoTop: 146)
        // A 320×426⅔ photo would extend below the 568pt canvas from y=146.
        // Preserve all source content by fitting it into the remaining 422pt.
        assertRect(layout.photoFrame, CGRect(x: 1.75, y: 146, width: 316.5, height: 422))
    }

    func testResultPhotoUsesTheSameReferenceHeaderAndPreservesTheTallSheetLayout() {
        // Result coordinates begin below the 62pt status safe area.
        let size = CGSize(width: 402, height: 874 - 62)
        let standard = MeasurementResultLayout(size: size, bottomSafeArea: 34,
            aspect: 3.0 / 4, summaryHeight: 111)
        assertRect(standard.photo, CGRect(x: 0, y: 84, width: 402, height: 536))
        XCTAssertEqual(standard.photo.minY + 62, 146, accuracy: 0.001)
        XCTAssertNil(standard.sheetTop)

        let tall = MeasurementResultLayout(size: size, bottomSafeArea: 34,
            aspect: 9.0 / 16, summaryHeight: 111)
        XCTAssertEqual(tall.photo.minY, 96, accuracy: 0.001)
        XCTAssertEqual(tall.photo.width, 402, accuracy: 0.001)
        XCTAssertEqual(tall.photo.height, 402.0 * 16 / 9, accuracy: 0.001)
        XCTAssertNotNil(tall.sheetTop)
        XCTAssertLessThanOrEqual(tall.photo.maxY, size.height)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
