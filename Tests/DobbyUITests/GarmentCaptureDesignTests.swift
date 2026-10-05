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
        if app.frame.width == 402 && app.frame.height == 874 {
            let back = app.buttons["closeGarmentCapture"]
            XCTAssertEqual(back.frame.minX, 16, accuracy: 1)
            XCTAssertEqual(back.frame.minY, 62, accuracy: 1)
            XCTAssertEqual(back.frame.width, 44, accuracy: 1)
            XCTAssertEqual(back.frame.height, 44, accuracy: 1)
            XCTAssertEqual(viewport.frame.minY, 131, accuracy: 1)
            XCTAssertEqual(viewport.frame.height, 560, accuracy: 1)
            let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
            XCTAssertEqual(guidance.frame.minY, 626, accuracy: 1)
            XCTAssertEqual(guidance.frame.height, 40, accuracy: 1)
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
            XCTAssertEqual(photo.frame.minY, 190, accuracy: 1)
            XCTAssertEqual(photo.frame.width, 402, accuracy: 1)
            XCTAssertEqual(photo.frame.height, 560, accuracy: 1)
            XCTAssertEqual(confirm.frame.minX, 32, accuracy: 1)
            XCTAssertEqual(confirm.frame.minY, 778, accuracy: 1)
            XCTAssertEqual(confirm.frame.width, 335, accuracy: 1)
            XCTAssertEqual(confirm.frame.height, 62, accuracy: 1)
        }
        let shoulder = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(shoulder.isHittable)
        // A tall viewport must not stretch or rebase the photograph's point
        // coordinates. Both source points are normalized in this same photo.
        XCTAssertEqual(shoulder.frame.midX, photo.frame.minX + photo.frame.width * 0.142, accuracy: 1)
        XCTAssertEqual(shoulder.frame.midY, photo.frame.minY + photo.frame.height * 0.302, accuracy: 1)
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertTrue(magnifier.exists)
        XCTAssertTrue(photo.frame.contains(magnifier.frame))
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 6)
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

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
