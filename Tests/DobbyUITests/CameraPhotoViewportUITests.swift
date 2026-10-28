import XCTest
import UIKit

/// Test-owned 800×1000 photos exercise framing and event coordinates only.
/// No test below establishes optical zoom, LiDAR alignment or physical accuracy.
final class CameraPhotoViewportUITests: XCTestCase {
    @MainActor
    func testTranslucentSurroundingsFollowTheCameraWithoutMovingThePhotoOrAcceptingFocus() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-no-outline"])
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let frame = viewport.frame
        let screen = app.frame
        let initial = XCUIScreen.main.screenshot()
        let upper = position(CGPoint(x: 0.80, y: 0.14), in: screen)
        let lower = position(CGPoint(x: 0.10, y: 0.95), in: screen)
        let topColor = try rgbSample(in: initial.image, at: upper, screen: screen)
        for site in [upper, lower] {
            XCTAssertFalse(frame.contains(site))
            let color = try rgbSample(in: initial.image, at: site, screen: screen)
            XCTAssertGreaterThan(color.max() ?? 0, 15, "Surroundings must show camera color rather than solid black")
            XCTAssertGreaterThan(color.reduce(0, +), 45,
                                 "Native adaptive regular glass must retain the camera underneath")
        }
        attach(initial, name: "camera-translucent-surroundings-one-x")

        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.14))
        outside.tap()
        XCTAssertFalse(focus.exists, "The decorative backdrop cannot create focus requests outside the photograph")
        let zoom = app.buttons["cameraZoomSelector"]
        zoom.tap()
        waitUntil { zoom.value as? String == "2x" }
        assertFrame(viewport.frame, equals: frame)
        let zoomed = XCUIScreen.main.screenshot()
        let changed = try rgbSample(in: zoomed.image, at: upper, screen: screen)
        XCTAssertGreaterThan(zip(topColor, changed).map { abs($0.0 - $0.1) }.max() ?? 0, 8,
                             "Surroundings must follow camera content, not a constant gray fill")
        attach(zoomed, name: "camera-translucent-surroundings-two-x")
        zoom.tap()
        waitUntil { zoom.value as? String == "1x" }
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.midX, frame.minX + frame.width * 0.65, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, frame.minY + frame.height * 0.55, accuracy: 2)
    }

    @MainActor
    func testFullSourcePixelsStayInPlaceFromPreviewThroughProcessingAndResult() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-processing",
            "--garment-preview-no-outline", "--garment-preview-matched-framing"])
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let shutter = app.buttons["captureGarment"]
        let expected = expectedPhotoRect(in: app.frame)
        assertFrame(viewport.frame, equals: expected)
        XCTAssertEqual(viewport.frame.width / viewport.frame.height, 0.8, accuracy: 0.001)
        if app.frame.width == 402 && app.frame.height == 874 {
            assertFrame(viewport.frame, equals: CGRect(x: app.frame.minX, y: app.frame.minY + 139.5625,
                width: 402, height: 502.5))
        }

        armSyntheticGarmentCapture(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists,
            "Only the opt-in tint-free fixture can compare camera source pixels")
        let liveRect = viewport.frame
        let liveScreenshot = XCUIScreen.main.screenshot()
        attach(liveScreenshot, name: "photo-viewport-full-source-before-capture")
        shutter.tap()
        let frozen = app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch
        XCTAssertTrue(frozen.waitForExistence(timeout: 5))
        let frozenRect = frozen.frame
        // Capture immediately: the fixture holds this stage for a bounded time.
        let frozenScreenshot = XCUIScreen.main.screenshot()
        attach(frozenScreenshot, name: "photo-viewport-full-source-during-processing")
        assertFrame(frozenRect, equals: liveRect)

        // Independent source landmarks: upper background, both sleeves, torso,
        // and side background. A blank or aspect-filled image cannot pass all.
        let sites = [CGPoint(x: 0.05, y: 0.28), CGPoint(x: 0.15, y: 0.46),
            CGPoint(x: 0.85, y: 0.46), CGPoint(x: 0.42, y: 0.60),
            CGPoint(x: 0.08, y: 0.64), CGPoint(x: 0.92, y: 0.64)]
        var sourceColors: [[Int]] = []
        for site in sites {
            let source = try rgbSample(in: liveScreenshot.image, at: position(site, in: liveRect), screen: app.frame)
            let processing = try rgbSample(in: frozenScreenshot.image,
                at: position(site, in: frozenRect), screen: app.frame)
            sourceColors.append(source)
            assertColor(processing, equals: source,
                message: "Source pixel \(site) moved when the photo was frozen")
        }
        XCTAssertGreaterThan(sourceColors[0][0] - sourceColors[1][0], 40,
            "The exposed upper background and sleeve must both remain visible")
        XCTAssertGreaterThan(sourceColors[4][0] - sourceColors[3][0], 40,
            "Verify the garment and its background, not matching blank frames")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let resultViewport = app.descendants(matching: .any)["garmentResultPhotoViewport"].firstMatch
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(photo.exists && resultViewport.exists)
        let resultRect = assertAspectFitPhoto(photo, in: resultViewport,
            sourceSize: CGSize(width: 800, height: 1000))
        let shoulder = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(shoulder.isHittable)
        XCTAssertEqual(shoulder.frame.midX, resultRect.minX + resultRect.width * 0.30, accuracy: 1)
        XCTAssertEqual(shoulder.frame.midY, resultRect.minY + resultRect.height * 0.23, accuracy: 1,
            "The result must preserve full-source coordinates even with the legacy framing flag")
        XCTAssertFalse(frozen.exists)
        attach(XCUIScreen.main.screenshot(), name: "photo-viewport-full-source-result")
    }

    @MainActor
    func testTwoXUsesOneCenteredCropWithoutResizingThePhotoViewport() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-no-outline"])
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let zoom = app.buttons["cameraZoomSelector"]
        let oneXRect = viewport.frame
        assertFrame(oneXRect, equals: expectedPhotoRect(in: app.frame))
        XCTAssertEqual(zoom.value as? String, "1x")
        let oneX = XCUIScreen.main.screenshot()
        zoom.tap()
        waitUntil { zoom.value as? String == "2x" }
        let twoXRect = viewport.frame
        let twoX = XCUIScreen.main.screenshot()
        assertFrame(twoXRect, equals: oneXRect)

        // At 2× these side probes see background (source x=.29/.71),
        // whereas accidental 4× scaling sees the torso. Upper probes see
        // garment at 2× (source .35/.65,.35), but background at 1×.
        let sites = [CGPoint(x: 0.08, y: 0.70), CGPoint(x: 0.92, y: 0.70),
            CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.80, y: 0.20)]
        var zoomedColors: [[Int]] = []
        for site in sites {
            let originalSite = CGPoint(x: 0.5 + (site.x - 0.5) / 2,
                y: 0.5 + (site.y - 0.5) / 2)
            let source = try rgbSample(in: oneX.image, at: position(originalSite, in: oneXRect), screen: app.frame)
            let zoomed = try rgbSample(in: twoX.image, at: position(site, in: twoXRect), screen: app.frame)
            zoomedColors.append(zoomed)
            assertColor(zoomed, equals: source, message: "2× must apply the centered source crop exactly once at \(site)")
        }
        XCTAssertGreaterThan(zoomedColors[0][0] - zoomedColors[2][0], 40,
            "Side background and upper garment distinguish 2× from both 1× and accidental 4×")
        XCTAssertFalse(app.buttons["captureGarment"].isEnabled,
            "Synthetic crop presentation is not a calibrated 2× sensor capture")
        attach(oneX, name: "photo-viewport-one-x-source")
        attach(twoX, name: "photo-viewport-two-x-single-crop")

        zoom.tap()
        waitUntil { zoom.value as? String == "1x" }
        let returned = XCUIScreen.main.screenshot()
        assertFrame(viewport.frame, equals: oneXRect)
        for site in sites {
            let original = try rgbSample(in: oneX.image, at: position(site, in: oneXRect), screen: app.frame)
            let restored = try rgbSample(in: returned.image, at: position(site, in: viewport.frame), screen: app.frame)
            assertColor(restored, equals: original, message: "Returning to 1× must restore source pixels")
        }
    }

    @MainActor
    func testRotationFitsTheFullPhotoBesideLandscapeControls() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-no-outline"])
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        assertFrame(viewport.frame, equals: expectedPhotoRect(in: app.frame))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        let expected = expectedPhotoRect(in: app.frame)
        waitUntil { abs(viewport.frame.width - expected.width) <= 1 && abs(viewport.frame.minX - expected.minX) <= 1 }
        assertFrame(viewport.frame, equals: expected)
        XCTAssertEqual(viewport.frame.width / viewport.frame.height, 0.8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(viewport.frame.maxX, app.frame.maxX - 180 + 1,
            "The photograph must fit beside the landscape control column")
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.midX, expected.minX + expected.width * 0.65, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, expected.minY + expected.height * 0.55, accuracy: 2)
        attach(XCUIScreen.main.screenshot(), name: "photo-viewport-landscape-source-and-focus")
    }

    /// Expected visible source area comes from the UI specification, not the
    /// production helper: fit the 4:5 test photo in the full camera canvas.
    private func expectedPhotoRect(in screen: CGRect) -> CGRect {
        if screen.width > screen.height {
            let area = CGRect(x: screen.minX, y: screen.minY, width: screen.width - 180, height: screen.height)
            let scale = min(area.width / 800, area.height / 1000)
            return CGRect(x: area.midX - 400 * scale, y: area.midY - 500 * scale,
                width: 800 * scale, height: 1000 * scale)
        }
        let maximumHeight = min(screen.width * 16 / 9, screen.height - 120)
        let height = min(maximumHeight, screen.width / 0.8)
        let width = height * 0.8
        return CGRect(x: screen.midX - width / 2,
            y: screen.minY + 60 + (maximumHeight - height) * 0.375, width: width, height: height)
    }

    private func position(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func assertColor(_ actual: [Int], equals expected: [Int], message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 8, message, file: file, line: line)
        }
    }

    @MainActor
    private func rgbSample(in image: UIImage, at point: CGPoint, screen: CGRect,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let scaleX = CGFloat(cgImage.width) / screen.width
        let scaleY = CGFloat(cgImage.height) / screen.height
        let x = (point.x - screen.minX) * scaleX
        let y = (point.y - screen.minY) * scaleY
        let patch = CGRect(x: x - 1.5 * scaleX, y: y - 1.5 * scaleY,
            width: 3 * scaleX, height: 3 * scaleY).integral.intersection(
                CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let pixels = try XCTUnwrap(cgImage.cropping(to: patch), file: file, line: line)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.interpolationQuality = .medium
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba.prefix(3).map(Int.init)
    }

    @MainActor
    private func openPreview(arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        wait(for: [ready], timeout: 5)
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
