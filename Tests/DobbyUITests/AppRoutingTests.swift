import XCTest

/// Checks the actual capture/library home and URL delivery. Every test has an
/// isolated, empty product store; none copies data, starts a Live Activity,
/// captures a real photo, or opens an external marketplace.
final class AppRoutingTests: XCTestCase {
    @MainActor
    func testCaptureAndEmptyLibraryRemainReachableWithLabHidden() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        expectHome(in: app)

        // This launches the explicitly labelled synthetic creation flow. Exit
        // before shutter/confirmation, so no product or measurement is stored.
        app.buttons["product-flow.start"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["captureGarment"].isEnabled)
        XCTAssertEqual(app.buttons["captureGarment"].value as? String, "옷 인식 대기")
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].exists)
        app.buttons["closeGarmentCapture"].tap()
        expectHome(in: app)

        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        let editLibrary = app.buttons["library.edit-mode"]
        XCTAssertTrue(editLibrary.waitForExistence(timeout: 5))
        XCTAssertEqual(editLibrary.label, "수정")
        XCTAssertFalse(editLibrary.isEnabled)
        attachScreenshot(app, name: "routing-empty-library-start-measurement")
        app.buttons["library.empty.start-measurement"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].exists)
        app.buttons["closeGarmentCapture"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertFalse(editLibrary.isEnabled)
        XCTAssertTrue(app.tabBars.buttons["보관함"].isSelected)
        app.tabBars.buttons["홈"].tap()
        expectHome(in: app)
        attachScreenshot(app, name: "routing-home-capture-library")
    }

    @MainActor
    func testColdCopyHomeWithoutSessionShowsGuidanceAndKeepsLibraryEmpty() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        app.terminate()

        // The route requests the current helper, with no copy field or foreign
        // destination. An absent/expired helper must not construct a demo item.
        // XCUIApplication.open launches/relaunches the app in this runner. Use
        // an explicit cold launch; this does not verify warm tab preservation.
        // The production nil-session guard only sets its alert and returns.
        app.open(URL(string: "dobby-copy://home")!)
        let alert = app.alerts["내보내기를 열 수 없어요"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "진행 중인 복사 도우미가 없어요")).firstMatch.exists)
        XCTAssertFalse(app.buttons["export.close"].exists)
        XCTAssertFalse(app.navigationBars["내보내기"].exists)
        XCTAssertFalse(app.navigationBars["상품 정보 복사"].exists)
        attachScreenshot(app, name: "routing-cold-url-empty-helper-guidance")
        alert.buttons["확인"].tap()

        expectHome(in: app)
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected)
        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertTrue(app.tabBars.buttons["보관함"].isSelected)
        XCTAssertFalse(app.buttons["export.close"].exists)
        XCTAssertFalse(app.buttons["closeLiDARLab"].exists)
        app.tabBars.buttons["홈"].tap()
        expectHome(in: app)
    }

    @MainActor
    func testDebugExportSampleOpensRealLibraryExportFlowWithoutDuplicates() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)

        let sampleButton = app.buttons["debug.export-sample"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 5))
        sampleButton.tap()

        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let photos = app.descendants(matching: .any)["product-detail.photos"].firstMatch
        let name = app.descendants(matching: .any)["product-detail.name"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertTrue(name.exists)
        XCTAssertLessThanOrEqual(photos.frame.maxY, name.frame.minY)
        XCTAssertTrue(name.staticTexts["90s 나이키 트랙탑"].exists)

        let exportButton = app.buttons["library.export"]
        XCTAssertTrue(exportButton.isHittable, "The upload action stays fixed below the detail content")
        attachScreenshot(app, name: "debug-library-detail-top")

        let photo = app.buttons["제품 사진 확대"].firstMatch
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        XCTAssertTrue(app.navigationBars["제품 사진"].waitForExistence(timeout: 5))
        app.buttons["닫기"].tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))

        app.buttons["library.edit"].tap()
        let information = app.navigationBars["제품 정보 입력"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        information.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))

        let price = app.descendants(matching: .any)["product-detail.price"].firstMatch
        reveal(price, in: app)
        XCTAssertTrue(price.staticTexts["89,000 원"].exists)
        XCTAssertTrue(app.staticTexts["나이키"].exists)
        let measurements = app.descendants(matching: .any)["product-detail.measurements"].firstMatch
        for _ in 0..<8 where !measurements.exists || measurements.frame.maxY > exportButton.frame.minY {
            app.swipeUp()
        }
        XCTAssertTrue(measurements.exists)
        XCTAssertLessThanOrEqual(measurements.frame.maxY, exportButton.frame.minY)
        for (key, title, value) in [
            ("shoulderWidth", "어깨", "56cm"),
            ("chestWidth", "가슴", "55cm"),
            ("totalLength", "기장", "68cm"),
            ("sleeveLengthLeft", "소매", "52cm")
        ] {
            let column = app.descendants(matching: .any)["library.measurement.\(key)"].firstMatch
            XCTAssertTrue(column.exists, key)
            XCTAssertTrue(column.staticTexts[title].exists, key)
            XCTAssertTrue(column.staticTexts[value].exists, key)
        }
        XCTAssertTrue(exportButton.isHittable)
        attachScreenshot(app, name: "debug-library-detail-measurements")
        exportButton.tap()

        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
        let fruitsA = app.buttons["후루츠패밀리로 내보내기 (A)"]
        let fruitsB = app.buttons["후루츠패밀리로 내보내기 (B)"]
        reveal(fruitsB, in: app)
        XCTAssertTrue(fruitsA.exists)
        XCTAssertTrue(fruitsB.exists)
        attachScreenshot(app, name: "debug-library-sample-export-channels")

        app.buttons["export.close"].tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))
        app.buttons["library.edit"].tap()
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        let nameInput = app.descendants(matching: .any)["product-info.name"].firstMatch
        reveal(nameInput, in: app)
        tapVisibleInput(nameInput, in: app)
        nameInput.typeText(" 수정")
        let editedName = "90s 나이키 트랙탑 수정"
        XCTAssertEqual(nameInput.value as? String, editedName)
        let done = app.buttons["product-info.done"]
        XCTAssertTrue(done.isEnabled)
        done.tap()

        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 10))
        XCTAssertFalse(information.exists)
        XCTAssertFalse(app.descendants(matching: .any)["product-complete.screen"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["제품 정보 입력 완료! 🎉"].exists)
        XCTAssertFalse(app.buttons["product-complete.library"].exists)
        XCTAssertTrue(app.buttons["library.edit"].isHittable)
        XCTAssertTrue(exportButton.isHittable)
        XCTAssertTrue(name.staticTexts[editedName].exists)
        XCTAssertTrue(price.staticTexts["89,000 원"].exists)
        attachScreenshot(app, name: "debug-library-detail-after-edit")

        app.navigationBars[editedName].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["보관함"].isHittable)
        let cardID = "library.product.53E00000-0000-4000-8000-000000000053"
        XCTAssertTrue(app.buttons[cardID].label.contains(editedName))
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "library.product."
        )).count, 1)

        app.buttons["debug.export-sample"].tap()
        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 5))
        app.navigationBars[editedName].buttons.firstMatch.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "library.product."
        )).count, 1)

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let savedCard = app.buttons[cardID]
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10))
        XCTAssertTrue(savedCard.label.contains(editedName))
        savedCard.tap()
        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 5))
        XCTAssertTrue(name.staticTexts[editedName].exists)
        XCTAssertFalse(app.buttons["product-complete.library"].exists)
    }

    @MainActor
    func testProductInformationBackgroundTapDismissesKeyboardsWithoutLosingInput() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        app.buttons["debug.export-sample"].tap()
        XCTAssertTrue(app.buttons["library.edit"].waitForExistence(timeout: 10))
        app.buttons["library.edit"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 5))

        let name = app.descendants(matching: .any)["product-info.name"].firstMatch
        let detail = app.descendants(matching: .any)["product-info.detail"].firstMatch
        let price = app.textFields["product-info.price"]
        let shoulder = app.textFields["product-info.measurement.shoulderWidth"]
        let keyboard = app.keyboards.firstMatch

        reveal(name, in: app)
        tapVisibleInput(name, in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        name.typeText("X")
        let editedName = name.value as? String
        XCTAssertTrue(editedName?.contains("X") == true)
        dismissKeyboardByTappingBackground(beside: name, in: app)
        XCTAssertEqual(name.value as? String, editedName)

        tapVisibleInput(name, in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // Switch inputs while the keyboard is already open. A background
        // gesture must not consume the editor's tap or prevent typing.
        XCTAssertTrue(detail.isHittable)
        tapVisibleInput(detail, in: app)
        detail.typeText("Y")
        let editedDetail = detail.value as? String
        XCTAssertTrue(editedDetail?.contains("Y") == true)
        XCTAssertTrue(keyboard.exists)
        dismissKeyboardByTappingBackground(beside: detail, in: app)
        XCTAssertEqual(detail.value as? String, editedDetail)

        for input in [price, shoulder] {
            reveal(input, in: app)
            let value = input.value as? String
            tapVisibleInput(input, in: app)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            dismissKeyboardByTappingBackground(beside: input, in: app)
            XCTAssertEqual(input.value as? String, value)
            tapVisibleInput(input, in: app)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            dismissKeyboardByTappingBackground(beside: input, in: app)
        }
        XCTAssertEqual(name.value as? String, editedName)
        XCTAssertEqual(detail.value as? String, editedDetail)
        attachScreenshot(app, name: "product-info-background-dismissed-keyboard")
    }

    @MainActor
    private func tapVisibleInput(_ input: XCUIElement, in app: XCUIApplication) {
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let keyboardTop = app.keyboards.firstMatch.exists
            ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
        let top = max(input.frame.minY, barBottom + 12)
        let bottom = min(input.frame.maxY, keyboardTop - 12)
        XCTAssertGreaterThan(bottom, top)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: input.frame.maxX - min(4, input.frame.width / 2),
                                 dy: (top + min(bottom, top + 44)) / 2)).tap()
    }

    @MainActor
    private func dismissKeyboardByTappingBackground(beside input: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let top = app.navigationBars.firstMatch.frame.maxY + 20
        let bottom = keyboard.frame.minY - 20
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 8, dy: min(max(input.frame.midY, top), bottom))).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        return app
    }

    @MainActor
    private func expectHome(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10), file: file, line: line)
        let entry = app.buttons["product-flow.start"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(entry.isHittable, file: file, line: line)
        XCTAssertFalse(app.buttons["openLiDARLab"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["openQuickCopy"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["openExportChannels"].exists, file: file, line: line)
    }

    @MainActor
    private func expectEmptyLibrary(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10), file: file, line: line)
        let title = app.staticTexts["library.empty.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(title.label, "보관함이 비어있어요", file: file, line: line)
        XCTAssertTrue(app.staticTexts["작업을 시작해보세요"].exists, file: file, line: line)
        let start = app.buttons["library.empty.start-measurement"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(start.label, "실측 시작하기", file: file, line: line)
        XCTAssertTrue(start.isHittable, file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).firstMatch.exists, file: file, line: line)
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
