import XCTest

/// Explicit synthetic responses exercise the A flow without uploading a photo
/// or spending API credits. Live garment recognition is tested separately.
final class ProductAutofillFlowTests: XCTestCase {
    private let generatedName = "AI 테스트 네이비 집업 후드"
    private let generatedBrand = "TEST BRAND (테스트 브랜드)"
    private let generatedDescription = "네이비 컬러와 전면 지퍼가 돋보이는 후드입니다.\n\n심플한 디자인으로 다양한 하의와 매치하기 좋습니다."

    @MainActor
    func testEnabledNextShowsLoadingAndAutofillsOnlyThreeFields() {
        let app = openSelection(result: "delay")
        defer { app.terminate() }
        XCTAssertEqual(app.switches["product-ai.toggle"].value as? String, "1")
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists,
                       "Changing photo selection or the toggle must not start generation")
        screenshot(app, name: "a-flow-photo-selection-ai-enabled")
        tap(app, "camera.completePhotos")
        XCTAssertTrue(app.descendants(matching: .any)["product-ai.loading"].firstMatch.waitForExistence(timeout: 5))
        screenshot(app, name: "a-flow-generating-information")
        waitForInformation(in: app)
        assertGeneratedFields(in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo.")).count, 2)
        XCTAssertEqual(field("price", in: app).value as? String, "")
        app.swipeUp()
        XCTAssertTrue(field("measurement.shoulderWidth", in: app).exists)
        XCTAssertFalse((field("measurement.shoulderWidth", in: app).value as? String ?? "").isEmpty)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.reviewNotes"].firstMatch.exists)
        screenshot(app, name: "a-flow-generated-fields-and-retained-measurements")
    }

    @MainActor
    func testDisabledNextSkipsGenerationAndKeepsManualFieldsEmpty() {
        // A failure fixture would fail if the disabled flow accidentally called AI.
        let app = openSelection(result: "failure")
        defer { app.terminate() }
        disableProductAutofillIfPresent(in: app)
        tap(app, "camera.completePhotos")
        waitForInformation(in: app)
        assertEmptyFields(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
        XCTAssertFalse(app.buttons["product-ai.retry"].firstMatch.exists)
        screenshot(app, name: "a-flow-ai-disabled-manual-information")
    }

    @MainActor
    func testGenerationFailureCanRetryWithoutLosingSelectedPhotos() {
        let app = openSelection(result: "failure-once")
        defer { app.terminate() }
        tap(app, "camera.completePhotos")
        XCTAssertTrue(app.buttons["product-ai.retry"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["product-ai.manual"].firstMatch.exists)
        screenshot(app, name: "a-flow-generation-failed-retry-or-manual")
        tap(app, "product-ai.retry")
        waitForInformation(in: app)
        assertGeneratedFields(in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo.")).count, 2)
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.reviewNotes"].firstMatch.exists)
    }

    @MainActor
    func testGenerationFailureCanContinueWithManualInput() {
        let app = openSelection(result: "failure")
        defer { app.terminate() }
        tap(app, "camera.completePhotos")
        tap(app, "product-ai.manual")
        waitForInformation(in: app)
        assertEmptyFields(in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo.")).count, 2)
    }

    @MainActor
    func testCancellingGenerationRejectsLateResultAndRetainsSelection() {
        let app = openSelection(result: "delay")
        defer { app.terminate() }
        tap(app, "camera.completePhotos")
        tap(app, "product-ai.cancel")
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["camera.grid.select.0"].value as? String, "1번째 선택")
        XCTAssertEqual(app.buttons["camera.grid.select.1"].value as? String, "2번째 선택")
        XCTAssertFalse(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 6),
                       "A cancelled response must not move the user or fill a later screen")
        disableProductAutofillIfPresent(in: app)
        tap(app, "camera.completePhotos")
        waitForInformation(in: app)
        assertEmptyFields(in: app)
    }

    @MainActor
    private func openSelection(result: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launchEnvironment["DOBBY_AI_FIXTURE_RESULT"] = result
        app.launch()
        tap(app, "product-flow.start")
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        tap(app, "camera.grid.select.1")
        XCTAssertEqual(app.buttons["camera.grid.select.1"].value as? String, "2번째 선택")
        return app
    }

    @MainActor
    private func waitForInformation(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
    }

    @MainActor
    private func assertGeneratedFields(in app: XCUIApplication) {
        XCTAssertEqual(field("name", in: app).value as? String, generatedName)
        XCTAssertEqual(field("detail", in: app).value as? String, generatedDescription)
        XCTAssertEqual(field("brand", in: app).value as? String, generatedBrand)
        XCTAssertFalse(generatedDescription.contains("실물로 확인"), "Review guidance belongs outside sale copy")
        screenshot(app, name: "a-flow-generated-product-information")
    }

    @MainActor
    private func assertEmptyFields(in app: XCUIApplication) {
        // iOS may expose an empty TextField value or its placeholder. Neither
        // represents generated or user-entered product information.
        let name = field("name", in: app)
        XCTAssertTrue(["", "업로드에 사용되는 제품명을 입력해주세요"].contains(name.value as? String ?? "<missing>"))
        XCTAssertEqual(field("detail", in: app).value as? String, "")
        XCTAssertTrue(["", "제품의 브랜드를 적어주세요 (없다면 생략 가능)"].contains(
            field("brand", in: app).value as? String ?? "<missing>"))
    }

    @MainActor
    private func field(_ key: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-info.\(key)"].firstMatch
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ id: String) {
        // Native alert actions contain nested Button nodes sharing the same
        // identifier in iOS 26. Select the outer actionable match explicitly.
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), id)
        button.tap()
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
