import XCTest

/// Opt-in reference photos compare presentation, never recognition or sensor
/// accuracy. The production target does not bundle the Figma photograph.
final class GarmentCaptureDesignTests: XCTestCase {
    @MainActor
    func testReferencePhotoCaptureContourProcessingAndResultComposition() throws {
        guard ProcessInfo.processInfo.environment["DOBBY_UI_DESIGN_REFERENCE"] == "1" else {
            throw XCTSkip("Run with DOBBY_UI_DESIGN_REFERENCE=1 to bundle the original Figma photo.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top", "--garment-preview-design-reference",
                               "--garment-preview-processing"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<6 where !preview.isHittable { app.swipeUp() }
        preview.tap()

        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let back = app.buttons["closeGarmentCapture"]
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.width, 44, accuracy: 1)
        XCTAssertEqual(back.frame.height, 44, accuracy: 1)
        XCTAssertTrue(app.frame.contains(back.frame))
        XCTAssertLessThanOrEqual(back.frame.minX, app.frame.minX + 40)
        XCTAssertLessThanOrEqual(back.frame.maxY, viewport.frame.minY)
        if app.frame.width == 402 && app.frame.height == 874 {
            // Native navigation-bar margins vary by SDK. The photo window and
            // its guidance retain the handoff's dimensions below that bar.
            XCTAssertEqual(viewport.frame.width, 402, accuracy: 1)
            XCTAssertEqual(viewport.frame.height, 560, accuracy: 1)
            XCTAssertTrue(app.frame.contains(viewport.frame))
            let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
            XCTAssertEqual(guidance.frame.height, 40, accuracy: 1)
            XCTAssertEqual(guidance.frame.maxY, viewport.frame.maxY - 25, accuracy: 1)
        }
        screenshot(app, "figma32-01-capture")

        app.buttons["previewRecognizeGarment"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["captureGuidance"].firstMatch.label.contains("인식 완료"))
        screenshot(app, "figma32-02-contour")

        shutter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(shutter.isEnabled)
        screenshot(app, "figma32-03-processing")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable && confirm.isEnabled)
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(photo.exists)
        if app.frame.width == 402 && app.frame.height == 874 {
            XCTAssertEqual(photo.frame.minX, 0, accuracy: 1)
            XCTAssertEqual(photo.frame.width, 402, accuracy: 1)
            XCTAssertEqual(photo.frame.height, 560, accuracy: 1)
            XCTAssertEqual(confirm.frame.minX, 32, accuracy: 1)
            XCTAssertEqual(confirm.frame.minY, photo.frame.maxY + 28, accuracy: 1)
            XCTAssertEqual(confirm.frame.width, 335, accuracy: 1)
            XCTAssertEqual(confirm.frame.height, 62, accuracy: 1)
            XCTAssertLessThanOrEqual(confirm.frame.maxY, app.frame.maxY)
        }
        XCTAssertEqual(photo.frame.width / photo.frame.height, 804.0 / 1120.0, accuracy: 0.001,
                       "The reference photograph must preserve its source aspect ratio")
        let shoulder = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(shoulder.isHittable)
        // A tall viewport must not stretch or rebase the photograph's point
        // coordinates. Both source points are normalized in this same photo.
        XCTAssertEqual(shoulder.frame.midX, photo.frame.minX + photo.frame.width * 0.142, accuracy: 1)
        XCTAssertEqual(shoulder.frame.midY, photo.frame.minY + photo.frame.height * 0.302, accuracy: 1)
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertFalse(magnifier.exists, "An idle result must leave the photo unobstructed; the loupe appears only during a point drag.")
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 4)
        XCTAssertEqual(Set(labels.map(\.identifier)), Set(["top.totalLength", "top.shoulderWidth", "top.chestWidth", "top.sleeveLengthLeft"].map {
            "garmentMeasurementLabel_" + $0
        }))
        XCTAssertTrue(app.buttons["garmentMeasurementLabel_top.sleeveLengthLeft"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_top.sleeveLengthRight"].exists)
        XCTAssertTrue(app.buttons["garmentMeasurementPoint_sleeve_end_left"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementPoint_sleeve_end_right"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementPoint_hem_left"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementPoint_hem_right"].exists)
        XCTAssertTrue(app.buttons["garmentMeasurementPoint_hem_center"].exists)
        for (index, label) in labels.enumerated() {
            XCTAssertTrue(label.isHittable)
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame))
            }
        }
        screenshot(app, "figma32-04-result")

        app.buttons["garmentResultActions"].tap()
        app.buttons["openGarmentMeasurementDetails"].tap()
        XCTAssertTrue(app.buttons["closeGarmentMeasurementDetails"].waitForExistence(timeout: 5))
        screenshot(app, "figma32-05-details")
        app.buttons["closeGarmentMeasurementDetails"].tap()
        XCTAssertTrue(confirm.isHittable)
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
    }

    /// Issue #90 verifies the result editor on the reference photograph without
    /// asserting the unrelated capture screen's fixed Figma height. Geometry
    /// tests cover the compact loupe size. XCTest's press-and-drag call returns
    /// only after finger-up, so held-drag visibility needs separate recording.
    @MainActor
    func testReferencePhotoResultMagnifierOnlyAppearsWhileMoving() throws {
        guard ProcessInfo.processInfo.environment["DOBBY_UI_DESIGN_REFERENCE"] == "1" else {
            throw XCTSkip("Run with DOBBY_UI_DESIGN_REFERENCE=1 to bundle the original Figma photo.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top", "--garment-preview-design-reference"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<6 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        shutter.tap()

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["촬영한 옷과 측정점"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(photo.frame.width / photo.frame.height, 804.0 / 1120.0, accuracy: 0.001)
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(point.isHittable)
        XCTAssertGreaterThanOrEqual(point.frame.width, 56 - 0.001)
        XCTAssertGreaterThanOrEqual(point.frame.height, 56 - 0.001)
        XCTAssertEqual(point.frame.midX, photo.frame.minX + photo.frame.width * 0.142, accuracy: 1)
        XCTAssertEqual(point.frame.midY, photo.frame.minY + photo.frame.height * 0.302, accuracy: 1)
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertFalse(magnifier.exists, "The reference result starts idle without a persistent loupe.")
        let originalPoint = try XCTUnwrap(point.value as? String)
        point.tap()
        XCTAssertEqual(point.value as? String, originalPoint, "Selection must not change the point.")
        XCTAssertFalse(magnifier.exists, "Selection alone must not show the loupe.")
        screenshot(app, "issue90-reference-result-idle")

        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.025, dy: photo.frame.height * 0.015)))
        expectation(for: NSPredicate(format: "value != %@", originalPoint), evaluatedWith: point)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(magnifier.exists, "Finger-up must hide the loupe while keeping the moved point.")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        screenshot(app, "issue90-reference-result-after-drag")

        app.buttons["garmentResultActions"].tap()
        let enlarge = app.buttons["enlargeGarmentPhoto"]
        XCTAssertTrue(enlarge.waitForExistence(timeout: 5))
        enlarge.tap()
        let enlargedPhoto = app.navigationBars["촬영 사진"]
        XCTAssertTrue(enlargedPhoto.waitForExistence(timeout: 5))
        XCTAssertFalse(magnifier.exists)
        let originalPhoto = app.images["촬영한 원본 사진"].firstMatch
        XCTAssertTrue(originalPhoto.waitForExistence(timeout: 5))
        originalPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(magnifier.exists, "Tapping the enlarged photograph must not create a measurement loupe.")
        enlargedPhoto.buttons["닫기"].tap()
        expectation(for: NSPredicate { _, _ in confirm.isHittable }, evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(magnifier.exists, "Closing the photograph must not revive a completed drag's loupe.")
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
