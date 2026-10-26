import XCTest

/// Exercises the explicitly synthetic preview and its real UIKit tap recognizer.
/// Marker movement proves event routing, never optical autofocus or image sharpness.
final class CameraControlUITests: XCTestCase {
    @MainActor
    func testTapsMoveFocusBeforeRecognitionAndCaptureWorksOnceRecognized() throws {
        continueAfterFailure = false
        let app = openPreview()
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(focus.exists)
        assertRecognitionGate(in: app, ready: false)
        assertOnlyCompactZoomIsPersistent(app)

        for site in [CGVector(dx: 0.25, dy: 0.35), CGVector(dx: 0.72, dy: 0.65), CGVector(dx: 0.72, dy: 0.65)] {
            viewport.coordinate(withNormalizedOffset: site).tap()
            waitUntil {
                focus.exists
                    && abs(focus.frame.midX - (viewport.frame.minX + viewport.frame.width * site.dx)) <= 2
                    && abs(focus.frame.midY - (viewport.frame.minY + viewport.frame.height * site.dy)) <= 2
            }
            XCTAssertEqual(focus.value as? String, "초점 조절 요청")
            // The visible square animates; its semantic target remains stable.
            XCTAssertEqual(focus.frame.width, 64, accuracy: 2)
            XCTAssertEqual(focus.frame.height, 64, accuracy: 2)
            XCTAssertFalse(shutter.isEnabled, "Focus remains available while the shutter waits for garment recognition.")
        }
        XCTAssertTrue(app.descendants(matching: .any)["cameraExposureControl"].firstMatch.exists)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55)).tap()
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3)).tap()
        waitUntil {
            focus.exists && abs(focus.frame.midX - (viewport.frame.minX + viewport.frame.width * 0.65)) <= 2
                && abs(focus.frame.midY - (viewport.frame.minY + viewport.frame.height * 0.3)) <= 2
        }
        attachScreenshot(name: "synthetic-camera-immediate-focus-exposure")
        app.buttons["previewRecognizeGarment"].tap()
        assertRecognitionGate(in: app, ready: true)
        shutter.tap()
        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 10))
        retake.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        assertRecognitionGate(in: app, ready: false)
        XCTAssertFalse(focus.exists)
        assertOnlyCompactZoomIsPersistent(app)
    }

    @MainActor
    func testDragAnywhereAdjustsExposureAndNextTapResetsItWhileAwaitingRecognition() throws {
        continueAfterFailure = false
        let app = openPreview()
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let exposure = app.descendants(matching: .any)["cameraExposureControl"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.4)).tap()
        XCTAssertTrue(exposure.waitForExistence(timeout: 2))
        XCTAssertEqual(exposure.value as? String, "EV +0.0")
        let originalFrame = focus.frame
        let dragPoint = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.7))
        dragPoint.press(forDuration: 0.01, thenDragTo: dragPoint.withOffset(CGVector(dx: 0, dy: -70)))
        waitUntil { (exposure.value as? String)?.hasPrefix("EV +") == true && exposure.value as? String != "EV +0.0" }
        XCTAssertEqual(focus.frame.midX, originalFrame.midX, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, originalFrame.midY, accuracy: 2)
        assertOnlyCompactZoomIsPersistent(app)
        assertRecognitionGate(in: app, ready: false)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)).tap()
        waitUntil { exposure.value as? String == "EV +0.0" }
        XCTAssertEqual(focus.frame.midX, viewport.frame.minX + viewport.frame.width * 0.35, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, viewport.frame.minY + viewport.frame.height * 0.55, accuracy: 2)
        app.buttons["previewRecognizeGarment"].tap()
        assertRecognitionGate(in: app, ready: true)
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testRotationClearsOldFocusAndNewTapWorksWithReducedMotion() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-reduce-motion"])
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        XCTAssertFalse(focus.exists)
        assertOnlyCompactZoomIsPersistent(app)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.midX, viewport.frame.minX + viewport.frame.width * 0.45, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, viewport.frame.minY + viewport.frame.height * 0.42, accuracy: 2)
        XCTAssertEqual(focus.frame.width, 64, accuracy: 2)
        XCTAssertEqual(focus.frame.height, 64, accuracy: 2)
        assertRecognitionGate(in: app, ready: false)
        XCTAssertTrue(app.frame.contains(app.buttons["captureGarment"].frame),
                      "The waiting shutter must remain visible after rotation")
        app.buttons["closeGarmentCapture"].coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["captureGarment"].exists)
    }

    @MainActor
    func testCompactZoomButtonTogglesScalesWithOneTapAndRequiresFreshRecognition() throws {
        continueAfterFailure = false
        let app = openPreview()
        let zoom = app.buttons["cameraZoomSelector"]
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(zoom.isHittable)
        XCTAssertEqual(zoom.value as? String, "1x")
        assertRecognitionGate(in: app, ready: false)
        app.buttons["previewRecognizeGarment"].tap()
        assertRecognitionGate(in: app, ready: true)

        zoom.tap()
        waitUntil { zoom.value as? String == "2x" }
        XCTAssertFalse(app.buttons["cameraZoom_2.0"].exists,
                       "Tapping the zoom button must switch directly, without opening a menu")
        XCTAssertFalse(app.buttons["cameraZoom_0.5"].exists,
                       "The aligned LiDAR path must not offer an unsupported ultra-wide capture")
        attachScreenshot(name: "liquid-glass-zoom-two-x")
        // This synthetic fixture contains a calibrated 1x snapshot only. Its
        // disabled 2x shutter cannot be treated as physical zoom validation.
        XCTAssertFalse(shutter.isEnabled)
        assertRecognitionGate(in: app, ready: false)
        app.buttons["previewRecognizeGarment"].tap()
        assertRecognitionGate(in: app, ready: false)
        zoom.tap()
        waitUntil { zoom.value as? String == "1x" }
        assertRecognitionGate(in: app, ready: false)
        attachScreenshot(name: "liquid-glass-zoom-one-x")
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        app.buttons["previewRecognizeGarment"].tap()
        assertRecognitionGate(in: app, ready: true)
        shutter.tap()
        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 10))
        retake.tap()
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertEqual(zoom.value as? String, "1x")
        assertRecognitionGate(in: app, ready: false)
        assertOnlyCompactZoomIsPersistent(app)
    }

    @MainActor
    private func openPreview(arguments: [String] = ["--garment-preview-top"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)
        return app
    }

    @MainActor
    private func assertRecognitionGate(in app: XCUIApplication, ready: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let shutter = app.buttons["captureGarment"]
        let expectedValue = ready ? "촬영 가능" : "옷 인식 대기"
        waitUntil {
            shutter.isEnabled == ready && shutter.value as? String == expectedValue
        }
        XCTAssertEqual(shutter.isEnabled, ready, file: file, line: line)
        XCTAssertEqual(shutter.value as? String, expectedValue, file: file, line: line)
    }

    @MainActor
    private func assertOnlyCompactZoomIsPersistent(_ app: XCUIApplication) {
        let zoom = app.buttons["cameraZoomSelector"]
        XCTAssertTrue(zoom.exists && zoom.isHittable)
        XCTAssertFalse(app.buttons["cameraZoom_0.5"].exists)
        XCTAssertFalse(app.buttons["cameraExposureReset"].exists)
        XCTAssertFalse(app.sliders["cameraExposureSlider"].exists)
        XCTAssertFalse(app.staticTexts["cameraExposureValue"].exists)
        XCTAssertFalse(app.staticTexts["cameraAEAFLockStatus"].exists)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) {
        expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
