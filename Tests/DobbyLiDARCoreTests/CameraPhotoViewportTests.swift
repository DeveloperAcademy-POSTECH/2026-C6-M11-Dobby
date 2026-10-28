import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic layout and calibrated synthetic buffers, not physical proof that
/// ARKit's lens field of view matches every Camera app setting or device.
final class CameraPhotoViewportTests: XCTestCase {
    func testPortraitNativeFourByThreeImageFitsTheUnobscuredCameraWindow() throws {
        let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 0.75))
        XCTAssertEqual(viewport, .init(x: 0, y: 146, width: 402, height: 536))
        // Previously fitting the same image to all 874 points rendered it at
        // width 655.5 and made the subject 874/536 times larger on screen.
        XCTAssertEqual(874 * 0.75, 655.5)
        XCTAssertEqual(viewport.width / (874 * 0.75), 536.0 / 874, accuracy: 1e-12)
    }

    func testLandscapeImageIsCenteredBeforeTheTrailingControlsWithoutStretching() throws {
        let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 874,
            containerHeight: 402, photoAspectRatio: 4.0 / 3))
        XCTAssertEqual(viewport, .init(x: 79, y: 0, width: 536, height: 402))
        XCTAssertEqual(viewport.x + viewport.width / 2, (874.0 - 180) / 2)
        XCTAssertEqual(viewport.width / viewport.height, 4.0 / 3, accuracy: 1e-12)
    }

    func testSmallPortraitAndTabletLayoutsPreserveTheWholeImageAndControlRegions() throws {
        let small = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 375,
            containerHeight: 667, photoAspectRatio: 0.75))
        XCTAssertEqual(small, .init(x: 64.125, y: 146, width: 246.75, height: 329))
        let tablet = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 1024,
            containerHeight: 1366, photoAspectRatio: 0.75))
        XCTAssertEqual(tablet, .init(x: 126.5, y: 146, width: 771, height: 1028))
        let wideTablet = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 1366,
            containerHeight: 1024, photoAspectRatio: 4.0 / 3))
        XCTAssertEqual(wideTablet, .init(x: 0, y: 67.25, width: 1186, height: 889.5))
    }

    func testNonNativeFixtureRatioUsesLetterboxingAndTwoXDoesNotChangeTheWindow() throws {
        let fixture = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 800.0 / 1000))
        XCTAssertEqual(fixture, .init(x: 0, y: 162.75, width: 402, height: 502.5))
        let oneX = CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 1440.0 / 1920)
        let twoX = CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 720.0 / 960)
        XCTAssertEqual(oneX, twoX, "Registered 2x dimensions keep the same oriented aspect and UI window")
    }

    func testActualCameraBoundsProduceFullPhotoCropAndCorrectFocusForEveryOrientation() throws {
        let sourceSize = PixelSize(width: 1920, height: 1440)
        let rotations: [(ImageOrientation, CameraAffineTransform, ImagePoint)] = [
            (.up, .identity, .init(x: 0.23, y: 0.71)),
            (.right, .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0), .init(x: 0.29, y: 0.23)),
            (.down, .init(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1), .init(x: 0.77, y: 0.29)),
            (.left, .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1), .init(x: 0.71, y: 0.77))
        ]
        for (orientation, transform, expectedDisplay) in rotations {
            let quarterTurn = orientation == .right || orientation == .left
            let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: quarterTurn ? 0.75 : 4.0 / 3))
            let crop = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: sourceSize,
                orientation: orientation, viewportWidth: viewport.width, viewportHeight: viewport.height,
                visibleRect: .init(x: 0, y: 0, width: 1, height: 1)))
            XCTAssertEqual(crop, .full, "Controls outside the camera must not be applied as another sensor crop")

            let screenPoint = ImagePoint(x: viewport.x + expectedDisplay.x * viewport.width,
                y: viewport.y + expectedDisplay.y * viewport.height)
            let localPoint = ImagePoint(x: screenPoint.x - viewport.x, y: screenPoint.y - viewport.y)
            let sensor = try XCTUnwrap(CameraPreviewGeometry.sensorPoint(viewPoint: localPoint,
                viewportWidth: viewport.width, viewportHeight: viewport.height, displayTransform: transform))
            XCTAssertEqual(sensor.x, 0.23, accuracy: 1e-12)
            XCTAssertEqual(sensor.y, 0.71, accuracy: 1e-12)
            let displayed = try XCTUnwrap(CameraPreviewGeometry.displayPoint(sensorPoint: sensor,
                viewportWidth: viewport.width, viewportHeight: viewport.height, displayTransform: transform))
            XCTAssertEqual(displayed.x + viewport.x, screenPoint.x, accuracy: 1e-10)
            XCTAssertEqual(displayed.y + viewport.y, screenPoint.y, accuracy: 1e-10)
        }
    }

    func testChromeAndLetterboxTapsDoNotClampToAnImageEdge() throws {
        let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 375,
            containerHeight: 667, photoAspectRatio: 0.75))
        let transform = CameraAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        for screenPoint in [ImagePoint(x: 0, y: 200), .init(x: 187.5, y: 100),
                            .init(x: 374, y: 300), .init(x: 187.5, y: 600)] {
            XCTAssertNil(CameraPreviewGeometry.sensorPoint(viewPoint: .init(
                x: screenPoint.x - viewport.x, y: screenPoint.y - viewport.y),
                viewportWidth: viewport.width, viewportHeight: viewport.height, displayTransform: transform))
        }
    }

    func testTwoXPreviewMatchesRegisteredCaptureCoordinatesDepthAndCalibrationWithoutDoubleZoom() throws {
        let imageSize = PixelSize(width: 1920, height: 1440)
        let depthSize = PixelSize(width: 256, height: 192)
        let crop = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: imageSize, depthSize: depthSize, zoomFactor: 2))
        let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 0.75))
        let sourcePoint = ImagePoint(x: 0.4, y: 0.45)
        let localCapturePoint = try XCTUnwrap(crop.croppedPoint(fromSource: sourcePoint))
        XCTAssertEqual(localCapturePoint.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(localCapturePoint.y, 0.4, accuracy: 1e-12)

        // Independently: rotate raw(.4,.45) right ->(.55,.4), draw in the
        // 2x child, then remove its centered visible-window offset.
        let childPoint = ImagePoint(x: 0.55 * viewport.width * 2, y: 0.4 * viewport.height * 2)
        let visiblePoint = ImagePoint(x: childPoint.x - viewport.width / 2,
            y: childPoint.y - viewport.height / 2)
        XCTAssertEqual(visiblePoint.x, 241.2, accuracy: 1e-10)
        XCTAssertEqual(visiblePoint.y, 160.8, accuracy: 1e-10)
        let capturedDisplay = ImageCoordinateTransform.originalToDisplay(localCapturePoint, orientation: .right)
        XCTAssertEqual(capturedDisplay.x * viewport.width, visiblePoint.x, accuracy: 1e-10)
        XCTAssertEqual(capturedDisplay.y * viewport.height, visiblePoint.y, accuracy: 1e-10)
        let sensor = try XCTUnwrap(CameraPreviewGeometry.sensorPoint(viewPoint: childPoint,
            viewportWidth: viewport.width * 2, viewportHeight: viewport.height * 2,
            displayTransform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)))
        XCTAssertEqual(sensor.x, sourcePoint.x, accuracy: 1e-12)
        XCTAssertEqual(sensor.y, sourcePoint.y, accuracy: 1e-12)
        XCTAssertEqual(PhotoDisplayCrop.matchingPreview(imageSize: crop.imageSize, orientation: .right,
            viewportWidth: viewport.width, viewportHeight: viewport.height,
            visibleRect: .init(x: 0, y: 0, width: 1, height: 1)), .full)

        let depth = DepthMap(size: depthSize,
            values: (0..<(256 * 192)).map { 1 + Float($0) / 100_000 },
            confidence: .init(repeating: 2, count: 256 * 192))
        let croppedDepth = try XCTUnwrap(crop.applying(to: depth))
        // raw(.4,.45) samples(102,86); crop(.3,.4) samples(38,38).
        let sourceDepth = depth.values[86 * 256 + 102]
        let newDepth = croppedDepth.values[38 * 128 + 38]
        XCTAssertEqual(sourceDepth.bitPattern, newDepth.bitPattern)
        let intrinsics = CameraIntrinsics(fx: 1500, fy: 1480, cx: 905, cy: 681, referenceSize: imageSize)
        let croppedIntrinsics = try XCTUnwrap(crop.applying(to: intrinsics))
        let oldX = (sourcePoint.x * 1920 - intrinsics.cx) / intrinsics.fx * Double(sourceDepth)
        let oldY = (sourcePoint.y * 1440 - intrinsics.cy) / intrinsics.fy * Double(sourceDepth)
        let newX = (localCapturePoint.x * 960 - croppedIntrinsics.cx) / croppedIntrinsics.fx * Double(newDepth)
        let newY = (localCapturePoint.y * 720 - croppedIntrinsics.cy) / croppedIntrinsics.fy * Double(newDepth)
        XCTAssertEqual(newX, oldX, accuracy: 1e-12)
        XCTAssertEqual(newY, oldY, accuracy: 1e-12)
    }

    func testInvalidUnavailableAndOverflowingLayoutsAreRejected() {
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertNil(CameraPhotoViewport.layout(containerWidth: invalid, containerHeight: 874, photoAspectRatio: 0.75))
            XCTAssertNil(CameraPhotoViewport.layout(containerWidth: 402, containerHeight: invalid, photoAspectRatio: 0.75))
            XCTAssertNil(CameraPhotoViewport.layout(containerWidth: 402, containerHeight: 874, photoAspectRatio: invalid))
        }
        for (width, height) in [(300.0, 338.0), (200, 337), (180, 100), (179, 100)] {
            XCTAssertNil(CameraPhotoViewport.layout(containerWidth: width, containerHeight: height, photoAspectRatio: 0.75))
        }
        XCTAssertNil(CameraPhotoViewport.layout(containerWidth: 402, containerHeight: 874,
            photoAspectRatio: Double.greatestFiniteMagnitude))
        XCTAssertNil(CameraPhotoViewport.layout(containerWidth: 402, containerHeight: 874,
            photoAspectRatio: Double.leastNonzeroMagnitude))
        XCTAssertNil(CameraPhotoViewport.layout(containerWidth: 1e308, containerHeight: 1.6e308,
            photoAspectRatio: 1e308))
    }
}
