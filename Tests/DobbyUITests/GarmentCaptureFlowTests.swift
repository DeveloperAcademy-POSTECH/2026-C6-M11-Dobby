import XCTest

/// This exercises the explicitly labelled synthetic preview. It is evidence of
/// navigation, display and persistence, never camera or model accuracy.
final class GarmentCaptureFlowTests: XCTestCase {
    @MainActor
    func testReducedMotionPreviewKeepsRecognitionCaptureAndRetakeUsable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-reduce-motion"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(shutter.isEnabled)
        recognize.tap()
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        shutter.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-reduced-motion-retake")
    }

    @MainActor
    func testAutomaticTopPreviewUsesDetectedKindAndSixMeasurements() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        launchLiDARLab(app)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists)
        XCTAssertTrue(app.staticTexts["automaticGarmentRecognitionHelp"].exists)

        let photoCheck = app.buttons["openTopRecognition"]
        reveal(photoCheck, in: app)
        XCTAssertTrue(photoCheck.exists)
        XCTAssertTrue(app.buttons["openBottomRecognition"].exists, "Both manual models remain available only as photo diagnostics")
        photoCheck.tap()
        XCTAssertTrue(app.navigationBars["상의 사진 인식"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pickTopPhoto"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cm 치수는 계산하지 않습니다")).firstMatch.exists)
        app.buttons["완료"].tap()

        let preview = app.buttons["openGarmentPreview"]
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        XCTAssertTrue(app.descendants(matching: .any)["captureGuidance"].firstMatch.label.hasPrefix("상의 인식 완료"))
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-top-preview-recognized-outline")
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 6)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_bottom.")).firstMatch.exists)
        XCTAssertTrue(app.buttons["garmentMeasurementLabel_top.totalLength"].label.contains("cm"))
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Top measurement labels must not cover each other")
            }
        }
        attachScreenshot(app, name: "garment-top-preview-measurement-result")
        let shoulderValue = app.buttons["garmentMeasurementLabel_top.shoulderWidth"].label
        let reviewMenu = app.buttons["reviewAllGarmentMeasurementPoints"]
        reveal(reviewMenu, in: app)
        XCTAssertTrue(reviewMenu.exists)
        reviewMenu.tap()
        app.buttons["reviewGarmentItem_top.shoulderWidth"].tap()
        XCTAssertTrue(app.navigationBars["측정 테스트"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["A 지정됨"].exists)
        XCTAssertTrue(app.buttons["B 지정됨"].exists)
        app.buttons["완료"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["garmentMeasurementLabel_top.shoulderWidth"].label, shoulderValue,
                       "Reviewing valid model points must preserve the automatic result")
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["confirmGarmentMeasurement"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "어깨너비 · 데모")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.exists)
        record.tap()
        XCTAssertTrue(app.staticTexts["automaticValue_top.totalLength"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
    }

    @MainActor
    func testUnsupportedSimulatorDoesNotProduceMeasurements() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Unsupported-camera behavior is specific to the simulator")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists,
                       "Normal capture must not require a model selection")
        let capture = app.buttons["openGarmentCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        reveal(capture, in: app)
        capture.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists)
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
        launchLiDARLab(app)
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
        launchLiDARLab(app)
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
        attachScreenshot(app, name: "garment-preview-missing-row-before-detail")
        missing.tap()
        attachScreenshot(app, name: "garment-preview-missing-row-after-tap")
        XCTAssertTrue(app.navigationBars["오른쪽 인심(직선)"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["측정 불가"].exists)
        attachScreenshot(app, name: "garment-preview-missing-measurement-detail")
    }

    @MainActor
    func testMissingMeasurementCanBeReviewedDirectlyWithoutOpeningDetails() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-partial"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        let review = app.buttons["reviewGarmentMeasurement_bottom.crotch.hem_right_inner"]
        reveal(review, in: app)
        XCTAssertTrue(review.exists)
        review.tap()
        XCTAssertTrue(app.navigationBars["측정 테스트"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["B 위치 지정"].exists)
        let save = app.buttons["saveMeasurement"]
        reveal(save, in: app)
        XCTAssertTrue(save.exists)
        XCTAssertFalse(app.staticTexts["measurementSaved"].exists)
        attachScreenshot(app, name: "garment-missing-measurement-direct-review")
        app.buttons["완료"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_bottom.crotch.hem_right_inner"].exists,
                       "Opening manual review must not replace an unavailable automatic value")
    }

    @MainActor
    func testPreviewRecognitionResultRetakeAndConfirmedSave() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)

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
        XCTAssertTrue(app.descendants(matching: .any)["captureGuidance"].firstMatch.label.hasPrefix("하의 인식 완료"))
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
        app.navigationBars["촬영 사진"].buttons["닫기"].tap()
        XCTAssertTrue(waist.waitForExistence(timeout: 5))
        waist.tap()
        XCTAssertTrue(app.navigationBars["허리 단면"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "별도 기록")).firstMatch.exists)
        app.navigationBars["허리 단면"].buttons["닫기"].tap()

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
        for _ in 0..<12 {
            let scrollViews = app.scrollViews
            let scroll = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
            guard scroll.exists else { return }
            let bars = app.navigationBars
            let bar = bars.element(boundBy: max(0, bars.count - 1))
            let top = max(scroll.frame.minY, bar.exists ? bar.frame.maxY : scroll.frame.minY) + 16
            let confirm = app.buttons["confirmGarmentMeasurement"]
            let bottom = min(scroll.frame.maxY - 20,
                             confirm.exists && confirm.isHittable ? confirm.frame.minY - 12 : scroll.frame.maxY - 20)
            if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
            // Returning from a lower photo diagnostic must also reach the
            // normal capture entry above it without resetting the lab state.
            let goingDown = element.frame.minY < top
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: goingDown ? 0.45 : 0.72))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: goingDown ? 0.65 : 0.52))
            start.press(forDuration: 0.05, thenDragTo: end)
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
