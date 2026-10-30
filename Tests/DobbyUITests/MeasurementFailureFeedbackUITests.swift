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
            XCTAssertTrue(app.staticTexts["자동으로 실측을 완료했어요"].exists)
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
            let select = app.buttons["camera.selectPhotos"]
            XCTAssertTrue(select.waitForExistence(timeout: 15))
            select.tap()
            let completePhotos = app.buttons["camera.completePhotos"]
            XCTAssertTrue(completePhotos.waitForExistence(timeout: 10))
            disableProductAutofillIfPresent(in: app)
            completePhotos.tap()
            XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["product-info.measurement-warning"].firstMatch.exists)
            attach(app, name: top ? "top-uncertain-number-without-warning" : "bottom-uncertain-number-without-warning")
            app.terminate()
        }
    }

    @MainActor
    func testFoundPointWithDepthFailureExplainsSensorConfidenceAndOffersRetake() {
        continueAfterFailure = false
        let app = launchFixture("--garment-preview-feedback-depth-failure")
        let notice = app.buttons["garmentUnavailableNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains("센서 신뢰도"))
        XCTAssertFalse(notice.label.contains("점을 찾지 못"))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).count, 3)
        notice.tap()
        XCTAssertTrue(app.navigationBars["측정 항목 상세"].waitForExistence(timeout: 5))
        let id = "bottom.waist_left.waist_right"
        let reason = app.staticTexts["measurementFailureReason_" + id].firstMatch
        reveal(reason, in: app)
        XCTAssertTrue(reason.label.contains("센서 신뢰도"))
        XCTAssertFalse(app.buttons["reviewGarmentMeasurement_" + id].exists,
                       "Moving a point cannot restore missing sensor-confidence data")
        let retake = app.buttons["retakeForMeasurementFailure_" + id]
        reveal(retake, in: app)
        XCTAssertTrue(retake.isHittable)
        attach(app, name: "point-present-depth-failure-explained")
        retake.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["captureGarment"].isEnabled)
        XCTAssertEqual(app.buttons["captureGarment"].value as? String, "옷 인식 대기")
    }

    @MainActor
    func testOneCaptureFailureExplainsFourLengthsOnceWithoutManualPointPrompt() {
        continueAfterFailure = false
        let app = launchFixture("--garment-preview-feedback-plane-failure")
        let notice = app.buttons["garmentUnavailableNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains("4개 측정 불가"))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).count, 0)
        notice.tap()
        XCTAssertTrue(app.navigationBars["측정 항목 상세"].waitForExistence(timeout: 5))
        let retakes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retakeForMeasurementFailure_"))
        let retake = retakes.firstMatch
        reveal(retake, in: app)
        XCTAssertEqual(retakes.count, 1)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reviewGarmentMeasurement_")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "옷의 일부에만 모여")).firstMatch.exists)
        attach(app, name: "capture-plane-failure-shared-four-lengths")
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
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
