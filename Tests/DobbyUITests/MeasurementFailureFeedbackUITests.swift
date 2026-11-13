import XCTest

/// Synthetic states verify failure presentation and navigation, not physical
/// garment recognition, camera optics, or centimeter accuracy.
final class MeasurementFailureFeedbackUITests: XCTestCase {
    @MainActor
    func testUsableUncertainNumbersHaveNoWarningsOrValueSheetInResultAndProductInput() throws {
        continueAfterFailure = false
        for top in [true, false] {
            let app = launchFixture("--garment-preview-feedback-uncertain", top: top)
            let confirm = app.buttons["confirmGarmentMeasurement"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["garmentUnavailableNotice"].exists)
            XCTAssertFalse(app.buttons["garmentUncertainNotice"].exists)
            XCTAssertTrue(app.navigationBars["실측 결과"].exists)
            // Synthetic fixtures show the point tutorial only with its explicit opt-in flag.
            XCTAssertFalse(app.buttons["dismissGarmentResultTutorial"].exists)
            let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_"))
            XCTAssertEqual(labels.count, 4)
            for label in labels.allElementsBoundByIndex {
                XCTAssertTrue(label.label.contains("cm"))
                XCTAssertFalse(label.label.contains("확인 필요"))
            }
            labels.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars["실측 결과"].exists)
            XCTAssertFalse(app.staticTexts["계산 완료"].exists)
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "measurementFailureFeedback_")).firstMatch.exists)
            XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
            confirm.tap()
            let guide = app.buttons["camera.startDetailCapture"]
            if guide.waitForExistence(timeout: 2) { guide.tap() }
            let select = app.buttons["camera.selectPhotos"]
            XCTAssertTrue(select.waitForExistence(timeout: 15))
            select.tap()
            XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["product-info.measurement-warning"].firstMatch.exists)
            attach(app, name: top ? "top-uncertain-number-without-warning" : "bottom-uncertain-number-without-warning")
            app.terminate()
        }
    }

    @MainActor
    func testFoundPointWithDepthFailureKeepsPhotoClearAndAllowsRetake() {
        continueAfterFailure = false
        let app = launchFixture("--garment-preview-feedback-depth-failure")
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["garmentUnavailableNotice"].exists)
        XCTAssertTrue(app.buttons["garmentMeasurementPoint_waist_left"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).count, 3)
        attach(app, name: "point-present-depth-failure-without-banner")
        app.buttons["product-flow.back"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["captureGarment"].isEnabled)
        XCTAssertEqual(app.buttons["captureGarment"].value as? String, "옷 인식 대기")
    }

    @MainActor
    func testCaptureFailureKeepsExistingPointsWithoutFailureBannerOrInventedLengths() {
        continueAfterFailure = false
        let app = launchFixture("--garment-preview-feedback-plane-failure")
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["garmentUnavailableNotice"].exists)
        XCTAssertTrue(app.buttons["garmentMeasurementPoint_waist_left"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).count, 0)
        attach(app, name: "capture-plane-failure-points-without-banner")
    }

    @MainActor
    private func launchFixture(_ argument: String, top: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, argument]
        if top { app.launchArguments.append("--garment-preview-top") }
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertFalse(shutter.isEnabled, "A synthetic failure fixture must still obtain recognition before capture")
        armSyntheticGarmentCapture(in: app)
        shutter.tap()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
