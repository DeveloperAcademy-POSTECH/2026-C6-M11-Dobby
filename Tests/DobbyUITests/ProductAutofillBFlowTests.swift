import XCTest

/// B is the final flow without a Settings choice. All generation responses
/// are explicit local fixtures; these tests never upload photos or spend API credits.
final class ProductAutofillBFlowTests: XCTestCase {
    private let generatedName = "AI 테스트 네이비 집업 후드"
    private let generatedBrand = "TEST BRAND (테스트 브랜드)"
    private let generatedDescription = "네이비 컬러와 전면 지퍼가 돋보이는 후드입니다.\n\n심플한 디자인으로 다양한 하의와 매치하기 좋습니다."

    @MainActor
    func testFinalBFlowHasNoSettingsChoiceAndNextNeverStartsGeneration() {
        let app = makeApp(result: "failure")
        defer { app.terminate() }
        app.launch()
        openSettings(in: app)
        screenshot(app, name: "ai-flow-settings-without-ab-choice")

        app.terminate()
        app.launch()
        openSettings(in: app)
        app.tabBars.buttons["홈"].tap()
        openCaptureAndInformation(in: app)
        XCTAssertFalse(app.switches["product-ai.toggle"].exists)
        XCTAssertFalse(app.scrollViews["camera.selectionGrid"].exists)
    }

    @MainActor
    func testBNextKeepsManualFieldsEmptyAndButtonGeneratesOnlyThreeFields() {
        let app = openInformation(result: "delay")
        defer { app.terminate() }
        assertEmptyFields(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists,
                       "In B, advancing from detail capture must not start generation")
        XCTAssertFalse(app.buttons["product-ai.retry"].firstMatch.exists)
        XCTAssertEqual(selectedPhotoCount(in: app), 3)
        screenshot(app, name: "b-flow-information-before-generation")

        let originalMeasurement = measurementValue(in: app)
        tap(app, "product-ai.generate")
        XCTAssertTrue(app.descendants(matching: .any)["product-ai.loading"].firstMatch.waitForExistence(timeout: 5))
        screenshot(app, name: "b-flow-generating-from-information")
        waitForGeneratedFields(in: app)
        XCTAssertEqual(field("price", in: app).value as? String, "")
        XCTAssertEqual(measurementValue(in: app), originalMeasurement)
        XCTAssertEqual(selectedPhotoCount(in: app), 3)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.reviewNotes"].firstMatch.exists)
        reveal(field("name", in: app), in: app)
        screenshot(app, name: "b-flow-generated-information")
    }

    @MainActor
    func testBGenerationFailureRetriesOnTheInformationScreen() {
        let app = openInformation(result: "failure-once")
        defer { app.terminate() }
        tap(app, "product-ai.generate")
        XCTAssertTrue(app.buttons["product-ai.retry"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        XCTAssertTrue(app.buttons["product-ai.manual"].firstMatch.exists)
        screenshot(app, name: "b-flow-generation-failure")
        tap(app, "product-ai.retry")
        waitForGeneratedFields(in: app)
        XCTAssertEqual(selectedPhotoCount(in: app), 3)
        XCTAssertTrue(app.buttons["product-ai.generate"].exists)
    }

    @MainActor
    func testBGenerationFailureContinuesManualEditingWithoutLeavingInformation() {
        let app = openInformation(result: "failure")
        defer { app.terminate() }
        tap(app, "product-ai.generate")
        tap(app, "product-ai.manual")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        XCTAssertTrue(app.buttons["product-ai.generate"].isEnabled)
        assertEmptyFields(in: app)
        XCTAssertEqual(selectedPhotoCount(in: app), 3)
        replaceText(in: field("name", in: app), with: "Manual after AI failure", app: app)
        dismissKeyboard(in: app)
        XCTAssertEqual(field("name", in: app).value as? String, "Manual after AI failure")
    }

    @MainActor
    func testBCancellingGenerationKeepsInputAndRejectsTheLateResult() {
        let app = openInformation(result: "delay")
        defer { app.terminate() }
        let manualName = "Keep my manually entered name"
        replaceText(in: field("name", in: app), with: manualName, app: app)
        dismissKeyboard(in: app)
        tap(app, "product-ai.generate")
        tap(app, "product-ai.cancel")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        XCTAssertTrue(app.buttons["product-ai.generate"].isEnabled)
        XCTAssertEqual(field("name", in: app).value as? String, manualName)
        XCTAssertEqual(selectedPhotoCount(in: app), 3)
        let lateOverwrite = expectation(for: NSPredicate(format: "value == %@", generatedName),
                                        evaluatedWith: field("name", in: app))
        lateOverwrite.isInverted = true
        wait(for: [lateOverwrite], timeout: 6)
        XCTAssertEqual(field("name", in: app).value as? String, manualName)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
        screenshot(app, name: "b-flow-cancelled-generation-retains-input")
    }

    @MainActor
    func testBReplacingInformationStartsImmediatelyAndPreservesPriceAndMeasurement() {
        let app = openInformation(result: "success")
        defer { app.terminate() }
        screenshot(app, name: "b-flow-information-idle-before-manual-input")
        replaceText(in: field("name", in: app), with: "My product name", app: app)
        replaceText(in: field("detail", in: app), with: "My product description", app: app)
        replaceText(in: field("brand", in: app), with: "MY BRAND", app: app)
        replaceText(in: field("price", in: app), with: "40000", app: app)
        // The in-progress decimal text must survive generation, in addition to
        // the persisted automatic measurement behind it.
        replaceText(in: field("measurement.shoulderWidth", in: app), with: "67.25", app: app)
        dismissKeyboard(in: app)
        tap(app, "product-ai.generate")
        XCTAssertFalse(app.sheets["작성한 정보를 AI 내용으로 바꿀까요?"].exists)
        XCTAssertFalse(app.buttons["product-ai.replace"].firstMatch.exists)
        waitForGeneratedFields(in: app)
        XCTAssertEqual(field("price", in: app).value as? String, "40,000")
        XCTAssertEqual(measurementValue(in: app), "67.25")
        XCTAssertEqual(selectedPhotoCount(in: app), 3)

        // Adding the AI failure alert must not suppress the existing save
        // validation alert. Keep the same unfinished product on screen.
        let shoulder = field("measurement.shoulderWidth", in: app)
        replaceText(in: shoulder, with: "0", app: app)
        tap(app, "product-info.done")
        let invalidValue = app.alerts["제품 정보를 저장하지 못했어요"]
        XCTAssertTrue(invalidValue.waitForExistence(timeout: 5))
        XCTAssertTrue(invalidValue.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "어깨에", "0보다 큰 숫자")).firstMatch.exists)
        screenshot(app, name: "b-flow-existing-measurement-validation-after-ai")
        invalidValue.buttons["확인"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0")
        replaceText(in: shoulder, with: "67.25", app: app)
        XCTAssertEqual(shoulder.value as? String, "67.25")
        XCTAssertEqual(field("name", in: app).value as? String, generatedName)
        XCTAssertFalse(app.buttons["product-complete.export"].exists)
    }

    @MainActor
    private func makeApp(result: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launchEnvironment["DOBBY_AI_FIXTURE_RESULT"] = result
        return app
    }

    @MainActor
    private func openInformation(result: String) -> XCUIApplication {
        let app = makeApp(result: result)
        app.launch()
        openCaptureAndInformation(in: app)
        XCTAssertFalse(app.switches["product-ai.toggle"].exists,
                       "B generation belongs to information entry, not photo selection")
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["product-ai.generate"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["기본 설정"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.aiFlow.a"].firstMatch.exists)
        XCTAssertFalse(app.buttons["settings.aiFlow.b"].firstMatch.exists)
    }

    @MainActor
    private func openCaptureAndInformation(in app: XCUIApplication) {
        tap(app, "product-flow.start")
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func waitForGeneratedFields(in app: XCUIApplication) {
        waitForValue(generatedName, of: field("name", in: app), timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        XCTAssertEqual(field("name", in: app).value as? String, generatedName)
        XCTAssertEqual(field("detail", in: app).value as? String, generatedDescription)
        XCTAssertEqual(field("brand", in: app).value as? String, generatedBrand)
    }

    @MainActor
    private func assertEmptyFields(in app: XCUIApplication) {
        XCTAssertTrue(["", "업로드에 사용되는 제품명을 입력해주세요"].contains(
            field("name", in: app).value as? String ?? "<missing>"))
        XCTAssertEqual(field("detail", in: app).value as? String, "")
        XCTAssertTrue(["", "제품의 브랜드를 적어주세요 (없다면 생략 가능)"].contains(
            field("brand", in: app).value as? String ?? "<missing>"))
    }

    @MainActor
    private func selectedPhotoCount(in app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo.")).count
    }

    @MainActor
    private func measurementValue(in app: XCUIApplication) -> String {
        let measurement = field("measurement.shoulderWidth", in: app)
        reveal(measurement, in: app)
        let value = measurement.value as? String ?? ""
        XCTAssertFalse(value.isEmpty)
        return value
    }

    @MainActor
    private func field(_ key: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "product-info.\(key)"
        return key == "detail" ? app.textViews[identifier].firstMatch : app.textFields[identifier].firstMatch
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        if id == "product-ai.generate" { reveal(button, in: app) }
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), id)
        button.tap()
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        if field.identifier == "product-info.detail" {
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 100
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let visibleTop = max(field.frame.minY, top + 12)
            let visibleBottom = min(field.frame.maxY, keyboardTop - 12)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: field.frame.midX,
                dy: (visibleTop + min(visibleBottom, visibleTop + 44)) / 2)).tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
            count: current == placeholder ? 0 : current.count) + text)
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        // The information ScrollView explicitly dismisses the keyboard while
        // scrolling. Keep the gesture away from editable text and toolbar actions.
        let top = app.navigationBars["제품 정보 입력"].frame.maxY + 16
        let bottom = app.keyboards.firstMatch.frame.minY - 16
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.97, dy: top + (bottom - top) * 0.3))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.97, dy: top + (bottom - top) * 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval) {
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: timeout), .completed)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            let top = (app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 68) + 12
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY - 12 : app.frame.maxY - 60
            if element.isHittable {
                if element.identifier == "product-info.detail",
                   min(element.frame.maxY, bottom) - max(element.frame.minY, top) >= 44 { return }
                if element.frame.minY >= top, element.frame.maxY <= bottom { return }
            }
            let frame = element.frame
            let isAbove = element.exists && !frame.isEmpty && !frame.isNull && !frame.isInfinite && frame.minY < top
            let height = max(40, bottom - top)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (isAbove ? 0.30 : 0.80) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (isAbove ? 0.80 : 0.30) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
