import XCTest

/// Synthetic captures and disposable stores exercise the normal registration
/// and library-editing screens without publishing or requesting AI content.
@MainActor
final class ProductInformationValidationScrollTests: XCTestCase {
    func testRegistrationRevealsEachMissingFieldAndPreservesGrowingDescription() {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        defer { app.terminate() }

        startMeasurementFromHome(in: app)
        armSyntheticGarmentCapture(in: app)
        tap("captureGarment", in: app)
        tap("confirmGarmentMeasurement", in: app)
        tap("camera.startDetailCapture", in: app)
        tap("camera.captureDetail", in: app)
        tap("camera.selectPhotos", in: app)
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))

        scrollToBottom(in: app)
        tap("product-info.done", in: app)
        assertErrorVisible("name", in: app)
        let name = app.textFields["product-info.name"]
        name.tap()
        name.typeText("Validation scroll product")

        scrollToBottom(in: app)
        tap("product-info.done", in: app)
        assertErrorVisible("detail", in: app)
        let detail = app.textViews["product-info.detail"]
        let initialHeight = detail.frame.height
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        let description = (1...18).map { "Product detail line \($0)" }.joined(separator: "\n")
        detail.typeText(description)
        XCTAssertEqual(detail.value as? String, description)
        XCTAssertGreaterThan(detail.frame.height, initialHeight,
                             "The native description editor must continue growing as text is entered")

        // Finish while the multiline keyboard is still up. Its caret-driven
        // scrolling must yield to the missing-price validation destination.
        tap("product-info.done", in: app)
        assertErrorVisible("price", in: app)
        XCTAssertEqual(detail.value as? String, description)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let price = app.textFields["product-info.price"]
        price.tap()
        price.typeText("40000")
        tap("product-info.done", in: app)
        XCTAssertTrue(app.buttons["product-complete.export"].waitForExistence(timeout: 15))
    }

    func testLibraryEditingRevealsTheSameErrorOnEveryCompletionAttempt() {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        defer { app.terminate() }
        openLibraryEditor(in: app)

        let name = app.textFields["product-info.name"]
        reveal(name, in: app)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let originalName = name.value as? String ?? ""
        XCTAssertFalse(originalName.isEmpty)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalName.count))
        XCTAssertTrue(["", name.placeholderValue ?? ""].contains(name.value as? String ?? "<missing>"))

        for _ in 0..<2 {
            scrollToBottom(in: app)
            tap("product-info.done", in: app)
            assertErrorVisible("name", in: app)
            XCTAssertTrue(app.navigationBars["제품 정보 수정"].exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
    }

    func testMissingPhotosTakePriorityOverRequiredTextFields() {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        defer { app.terminate() }
        openLibraryEditor(in: app)

        let removals = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "product-info.delete-photo."))
        for _ in 0..<20 where removals.count > 0 {
            let remove = removals.firstMatch
            reveal(remove, in: app)
            remove.tap()
        }
        XCTAssertEqual(removals.count, 0)
        scrollToBottom(in: app)
        tap("product-info.done", in: app)
        let count = app.descendants(matching: .any)["product-info.photo-count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertTrue(count.label.contains("0장"))
        XCTAssertGreaterThanOrEqual(count.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1)
        XCTAssertTrue(app.navigationBars["제품 정보 수정"].exists)
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        return app
    }

    private func openLibraryEditor(in app: XCUIApplication) {
        app.tabBars.buttons["보관함"].tap()
        tap("debug.export-sample", in: app)
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        tap("library.edit", in: app)
        XCTAssertTrue(app.navigationBars["제품 정보 수정"].waitForExistence(timeout: 10))
    }

    private func assertErrorVisible(_ field: String, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let error = app.staticTexts["product-info.\(field).error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), file: file, line: line)
        let visible = NSPredicate { _, _ in
            error.isHittable
                && error.frame.minY >= app.navigationBars.firstMatch.frame.maxY - 1
                && error.frame.maxY <= app.frame.maxY - 20
        }
        let expectation = XCTNSPredicateExpectation(predicate: visible, object: error)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The first invalid field and its inline error must be visible", file: file, line: line)
    }

    private func scrollToBottom(in app: XCUIApplication) {
        for _ in 0..<4 { app.swipeUp() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 15), identifier)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }
}
