import XCTest

/// This exercises the explicitly labelled synthetic preview. It is evidence of
/// navigation, display and persistence, never camera or model accuracy.
final class GarmentCaptureFlowTests: XCTestCase {
    @MainActor
    func testUnsupportedSimulatorDoesNotProduceMeasurements() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Unsupported-camera behavior is specific to the simulator")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let capture = app.buttons["openGarmentCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        reveal(capture, in: app)
        capture.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "LiDAR가 있는 iPhone")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).firstMatch.exists)
        attachScreenshot(app, name: "garment-camera-unsupported-simulator")
    }

    @MainActor
    func testLandscapePreviewKeepsCaptureControlsReachable() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recognize.isHittable)
        recognize.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-preview-landscape-recognized")
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].isHittable)
        attachScreenshot(app, name: "garment-preview-landscape-result")
    }

    @MainActor
    func testPartialPreviewPreservesValidValuesAndExplainsMissingMeasurements() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-partial"]
        app.launch()
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["garmentMeasurementLabel_bottom.waist_left.waist_right"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_bottom.crotch.hem_right_inner"].exists)
        let unavailable = app.staticTexts["garmentUnavailableSummary"]
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.label.contains("2개 항목"))
        let details = app.buttons["측정 항목 상세"]
        reveal(details, in: app)
        details.tap()
        let missing = app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_right_inner"].firstMatch
        reveal(missing, in: app)
        XCTAssertTrue(missing.exists)
        XCTAssertTrue(missing.label.contains("측정 불가"))
        XCTAssertFalse(missing.label.contains("cm"))
        missing.tap()
        XCTAssertTrue(app.navigationBars["오른쪽 인심(직선)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["측정 불가"].exists)
        attachScreenshot(app, name: "garment-preview-missing-measurement-detail")
    }

    @MainActor
    func testPreviewRecognitionResultRetakeAndConfirmedSave() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "garment-preview-camera")
        recognize.tap()
        let silhouette = app.descendants(matching: .any)["garmentSilhouette"].firstMatch
        XCTAssertTrue(silhouette.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "garment-preview-recognized-outline")

        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let waist = app.buttons["garmentMeasurementLabel_bottom.waist_left.waist_right"]
        XCTAssertTrue(waist.exists)
        XCTAssertTrue(waist.label.contains("cm"))
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 8)
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Measurement labels must not cover each other: \(label.identifier), \(other.identifier)")
            }
        }
        attachScreenshot(app, name: "garment-preview-measurement-result")

        app.buttons["enlargeGarmentPhoto"].tap()
        XCTAssertTrue(app.navigationBars["촬영 사진"].waitForExistence(timeout: 5))
        app.buttons["확대"].tap()
        XCTAssertTrue(app.buttons["축소"].exists)
        app.buttons["닫기"].tap()
        XCTAssertTrue(waist.waitForExistence(timeout: 5))
        waist.tap()
        XCTAssertTrue(app.navigationBars["허리 단면"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "별도 기록")).firstMatch.exists)
        app.buttons["닫기"].tap()

        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.exists)
        recognize.tap()
        XCTAssertTrue(silhouette.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Only a successful archive save should dismiss the result")
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "허리 단면 · 데모")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.exists)
        record.tap()
        let replayedWaist = app.staticTexts["automaticValue_bottom.waist_left.waist_right"]
        XCTAssertTrue(replayedWaist.waitForExistence(timeout: 10))
        XCTAssertTrue(replayedWaist.label.contains("cm"))
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        // The full display avoids XCTest cropping a rotated app using its
        // portrait-coordinate bounds on some simulator runtimes.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
