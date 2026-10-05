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
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].exists)
        app.buttons["closeGarmentCapture"].tap()
        expectHome(in: app)

        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
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
        XCTAssertTrue(app.staticTexts["보관된 제품이 없어요"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).firstMatch.exists, file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
