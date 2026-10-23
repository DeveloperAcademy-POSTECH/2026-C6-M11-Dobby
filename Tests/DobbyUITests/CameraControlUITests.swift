import XCTest

/// Exercises the explicitly synthetic preview and its real UIKit tap recognizer.
/// Marker movement proves event routing, never optical autofocus or image sharpness.
final class CameraControlUITests: XCTestCase {
    @MainActor
    func testTapsMoveFocusAndDoNotBlockImmediateCaptureOrRetake() throws {
        continueAfterFailure = false
        let app = openPreview()
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(focus.exists)
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        assertBottomControlsAreAbsent(app)

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
            XCTAssertTrue(shutter.isEnabled, "Autofocus must not become a shutter gate.")
        }
        XCTAssertTrue(app.descendants(matching: .any)["cameraExposureControl"].firstMatch.exists)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55)).tap()
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3)).tap()
        waitUntil {
            focus.exists && abs(focus.frame.midX - (viewport.frame.minX + viewport.frame.width * 0.65)) <= 2
                && abs(focus.frame.midY - (viewport.frame.minY + viewport.frame.height * 0.3)) <= 2
        }
        attachScreenshot(name: "synthetic-camera-immediate-focus-exposure")
        shutter.tap()
        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 10))
        retake.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertFalse(focus.exists)
        assertBottomControlsAreAbsent(app)
    }

    @MainActor
    func testDragAnywhereAdjustsExposureAndNextTapResetsItWithoutBlockingCapture() throws {
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
        assertBottomControlsAreAbsent(app)
        XCTAssertTrue(app.buttons["captureGarment"].isEnabled)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)).tap()
        waitUntil { exposure.value as? String == "EV +0.0" }
        XCTAssertEqual(focus.frame.midX, viewport.frame.minX + viewport.frame.width * 0.35, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, viewport.frame.minY + viewport.frame.height * 0.55, accuracy: 2)
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
        assertBottomControlsAreAbsent(app)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.midX, viewport.frame.minX + viewport.frame.width * 0.45, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, viewport.frame.minY + viewport.frame.height * 0.42, accuracy: 2)
        XCTAssertEqual(focus.frame.width, 64, accuracy: 2)
        XCTAssertEqual(focus.frame.height, 64, accuracy: 2)
        XCTAssertTrue(app.buttons["captureGarment"].isHittable)
        app.buttons["closeGarmentCapture"].coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["captureGarment"].exists)
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
    private func assertBottomControlsAreAbsent(_ app: XCUIApplication) {
        for id in ["cameraZoom_0.5", "cameraZoom_1.0", "cameraZoom_2.0", "cameraExposureReset"] {
            XCTAssertFalse(app.buttons[id].exists)
        }
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
