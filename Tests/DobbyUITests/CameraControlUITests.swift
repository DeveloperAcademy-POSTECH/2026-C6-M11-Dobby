import XCTest

/// Explicit synthetic control fixtures. These tests do not demonstrate device autofocus,
/// sensor exposure changes, an ultra-wide LiDAR configuration, or physical measurement accuracy.
final class CameraControlUITests: XCTestCase {
    @MainActor
    func testSyntheticControlsKeepFocusSeparateAndCaptureOnlyTheirOneTimesFixture() throws {
        continueAfterFailure = false
        let app = openPreview()
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let provenance = app.staticTexts["garmentPreviewProvenance"]
        XCTAssertTrue(provenance.label.contains("합성 카메라 조절"))
        let ultraWide = app.buttons["cameraZoom_0.5"]
        XCTAssertTrue(ultraWide.exists)
        XCTAssertFalse(ultraWide.isEnabled)
        XCTAssertEqual(ultraWide.value as? String, "지원하지 않음")

        let slider = app.sliders["cameraExposureSlider"]
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.75)
        let exposure = app.staticTexts["cameraExposureValue"]
        waitUntil { exposure.label != "EV +0.0" }
        XCTAssertFalse(focus.exists, "Exposure touches must not submit a preview focus tap")
        app.buttons["cameraExposureReset"].tap()
        waitUntil { exposure.label == "EV +0.0" }
        XCTAssertFalse(focus.exists)

        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let tap = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.45))
        tap.tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.midX, viewport.frame.minX + viewport.frame.width * 0.42, accuracy: 2)
        XCTAssertEqual(focus.frame.midY, viewport.frame.minY + viewport.frame.height * 0.45, accuracy: 2)
        attachScreenshot(name: "synthetic-camera-focus-location")

        app.buttons["cameraZoom_2.0"].tap()
        XCTAssertEqual(app.buttons["cameraZoom_2.0"].value as? String, "선택됨")
        XCTAssertFalse(focus.exists, "A new preview crop must clear the previous focus marker")
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(shutter.isEnabled, "The fixed 1x synthetic inputs must not pretend to produce a 2x capture")
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertTrue(guidance.label.contains("합성 촬영은 1×"))
        app.buttons["cameraZoom_1.0"].tap()
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        shutter.tap()
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertFalse(focus.exists)
        XCTAssertFalse(ultraWide.isEnabled)
    }

    @MainActor
    func testReducedMotionAndRotationKeepControlTargetsReachableAndClearOldFocus() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-reduce-motion"])
        let focus = app.descendants(matching: .any)["cameraFocusIndicator"].firstMatch
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        XCTAssertFalse(focus.exists)
        XCTAssertTrue(app.buttons["cameraZoom_1.0"].isHittable)
        XCTAssertTrue(app.buttons["cameraZoom_2.0"].isHittable)
        XCTAssertTrue(app.sliders["cameraExposureSlider"].isHittable)
        XCTAssertTrue(app.buttons["cameraExposureReset"].isHittable)
        XCTAssertTrue(app.buttons["captureGarment"].isHittable)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)).tap()
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        XCTAssertEqual(focus.frame.width, 64, accuracy: 2)
        XCTAssertEqual(focus.frame.height, 64, accuracy: 2)
        attachScreenshot(name: "synthetic-camera-controls-landscape-reduced-motion")
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
        for _ in 0..<8 where !preview.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["cameraZoom_1.0"].waitForExistence(timeout: 10))
        return app
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
