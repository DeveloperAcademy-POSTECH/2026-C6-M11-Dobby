import XCTest

final class LiDARFlowTests: XCTestCase {
    @MainActor
    func testBundledBottomModelOffersPhotoRecognitionWithoutLiDAR() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let open = app.buttons["openBottomRecognition"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Bundled model and schema must load")
        reveal(open, in: app)
        open.tap()
        XCTAssertTrue(app.buttons["pickBottomPhoto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["바지·반바지 인식 테스트"].exists)
        XCTAssertTrue(app.otherElements["bottomRecognitionEmpty"].exists || app.staticTexts["하의 사진을 선택해 주세요"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "cm 치수는 계산하지 않습니다")).firstMatch.exists)
        app.buttons["완료"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
    @MainActor
    func testAutomaticFixturePreservesPartialResultsAndReopensAllItems() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let demo = app.buttons["openAutomaticDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        reveal(demo, in: app)
        demo.tap()
        let first = app.staticTexts["automaticValue_test"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(first.label, "50.00 cm")
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
        let half = app.staticTexts["automaticValue_half"]
        reveal(half, in: app)
        XCTAssertEqual(half.label, "25.00 cm")
        let missing = app.staticTexts["automaticValue_missing"]
        reveal(missing, in: app)
        XCTAssertEqual(missing.label, "측정 불가")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "automatic-fixture-partial-results"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let reference = app.textFields["automaticReference_test"]
        reveal(reference, in: app)
        reference.tap()
        reference.typeText("50")
        let save = app.buttons["saveAutomaticMeasurement"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["automaticMeasurementSaved"].waitForExistence(timeout: 10))
        app.buttons["완료"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "두 점 사이 · 데모")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        reveal(record, in: app)
        record.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(first.label, "50.00 cm")
        reveal(reference, in: app)
        XCTAssertEqual(reference.value as? String, "50.00")
        reveal(missing, in: app)
        XCTAssertEqual(missing.label, "측정 불가")
    }

    @MainActor
    func testAutomaticReferenceValidationAndEditedSaveState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let demo = app.buttons["openAutomaticDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        reveal(demo, in: app)
        demo.tap()
        XCTAssertTrue(app.staticTexts["automaticValue_test"].waitForExistence(timeout: 10))
        let reference = app.textFields["automaticReference_test"]
        replaceText(in: reference, with: "0", app: app)
        let save = app.buttons["saveAutomaticMeasurement"]
        reveal(save, in: app)
        save.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0보다 큰 숫자")).firstMatch.exists)
        let saved = app.staticTexts["automaticMeasurementSaved"]
        let share = app.buttons["사진·깊이·전체 측정점 공유"]
        XCTAssertFalse(saved.exists)
        XCTAssertFalse(share.exists)
        alert.buttons["확인"].tap()

        replaceText(in: reference, with: "50", app: app)
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(share.waitForExistence(timeout: 5))

        // A saved URL belongs to the exact inputs that were persisted. Editing
        // the reference must not leave a stale success badge or share action.
        replaceText(in: reference, with: "51", app: app)
        reveal(save, in: app)
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.waitForNonExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(share.waitForExistence(timeout: 5))
    }

    @MainActor
    func testManualReferenceValidationAndEditedContextSaveState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let demo = app.buttons["openDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        reveal(demo, in: app)
        demo.tap()
        XCTAssertTrue(app.staticTexts["measurementValue"].waitForExistence(timeout: 10))
        let reference = app.textFields["referenceCentimeters"]
        replaceText(in: reference, with: "0", app: app)
        let save = app.buttons["saveMeasurement"]
        reveal(save, in: app)
        save.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0보다 큰 숫자")).firstMatch.exists)
        let saved = app.staticTexts["measurementSaved"]
        let share = app.buttons["사진·깊이·측정점 JSON 공유"]
        XCTAssertFalse(saved.exists)
        XCTAssertFalse(share.exists)
        alert.buttons["확인"].tap()

        replaceText(in: reference, with: "50", app: app)
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(share.waitForExistence(timeout: 5))

        // Context edits also invalidate the saved presentation, even though the
        // geometry and its calculated 50 cm result have not changed.
        replaceText(in: app.textFields["testSpecimen"], with: "MV edited specimen", app: app)
        reveal(save, in: app)
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.waitForNonExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(share.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFinalValidationSeparatesSyntheticAndPhysicalEvidence() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let button = app.buttons["openValidationReport"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        reveal(button, in: app)
        button.tap()
        XCTAssertTrue(app.staticTexts["validationEmpty"].waitForExistence(timeout: 10))
        let attempts = app.staticTexts["physicalAttemptsEmpty"]
        reveal(attempts, in: app)
        XCTAssertTrue(attempts.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "final-validation-awaiting-physical-evidence"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testDemoMeasurementSaveAndReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let demo = app.buttons["openDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        reveal(demo, in: app)
        demo.tap()
        let value = app.staticTexts["measurementValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.label, "50.00")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "50cm-demo-result"
        image.lifetime = .keepAlways
        add(image)
        let save = app.buttons["saveMeasurement"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["measurementSaved"].waitForExistence(timeout: 10))
        app.buttons["완료"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "두 점 사이 · 데모")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        reveal(record, in: app)
        record.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.label, "50.00")
        XCTAssertEqual(app.textFields["referenceCentimeters"].value as? String, "50.00")
    }

    @MainActor
    func testMissingDepthShowsUnavailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let missing = app.buttons["깊이 결손"]
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        reveal(missing, in: app)
        missing.tap()
        app.buttons["openDemo"].tap()
        let value = app.staticTexts["measurementValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.label, "—")
        XCTAssertTrue(app.staticTexts["측정 불가"].exists)
    }

    @MainActor
    func testLiveReadinessPreviewTransitions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let preview = app.buttons["openReadinessDemo"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let status = app.staticTexts["liveReadinessTitle"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        func expect(_ text: String) {
            let predicate = NSPredicate(format: "label == %@", text)
            expectation(for: predicate, evaluatedWith: status)
            waitForExpectations(timeout: 15)
        }
        expect("깊이 확보 · 촬영 가능")
        XCTAssertEqual(status.label, "깊이 확보 · 촬영 가능")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "live-readiness-ready-demo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let missing = app.buttons["readinessDemo_missing"]
        reveal(missing, in: app)
        missing.tap()
        expect("LiDAR 깊이를 기다리는 중")
        let moving = app.buttons["readinessDemo_moving"]
        reveal(moving, in: app)
        moving.tap()
        expect("카메라를 잠시 멈춰 주세요")
        let multiple = app.buttons["readinessDemo_multiple"]
        if !multiple.isHittable { app.swipeDown() }
        multiple.tap()
        expect("여러 대상이 보여요")
    }

    @MainActor
    func testBaselineReportDoesNotClaimAccuracyForSyntheticRecords() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let button = app.buttons["openBaselineReport"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        reveal(button, in: app)
        button.tap()
        XCTAssertTrue(app.staticTexts["baselineEmpty"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "baseline-awaiting-physical-measurements"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testBottomsPresetClearsPreviousReferenceAndPoints() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let demo = app.buttons["openDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        reveal(demo, in: app)
        demo.tap()
        let category = app.buttons["garmentCategory"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        reveal(category, in: app)
        category.tap()
        XCTAssertTrue(app.buttons["바지"].waitForExistence(timeout: 5))
        app.buttons["바지"].tap()
        let definition = app.buttons["measurementDefinition"]
        definition.tap()
        app.buttons["허리 단면"].tap()
        let value = app.staticTexts["measurementValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.label, "—")
        XCTAssertTrue(app.staticTexts["측정 불가"].exists)
        let reference = app.textFields["referenceCentimeters"]
        reveal(reference, in: app)
        XCTAssertNotEqual(reference.value as? String, "50.00")
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        // Tap the trailing side so the insertion point follows the current text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(field.value as? String, text)
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
            let bottom = scroll.frame.maxY - 20
            if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
            // Small, directed swipes prevent overshooting a control beneath the
            // navigation bar in iPad sheets (isHittable alone can be misleading).
            let goingDown = element.frame.minY < top
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: goingDown ? 0.45 : 0.72))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: goingDown ? 0.65 : 0.52))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
}
