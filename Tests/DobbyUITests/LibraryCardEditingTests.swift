import XCTest

@MainActor
final class LibraryCardEditingTests: XCTestCase {
    func testEmptyDraftFilterRemainsAvailableWithZeroCount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        let badge = app.buttons["library.draft-count"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.label, "임시저장 0개")
        badge.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.drafts.empty"].waitForExistence(timeout: 5))
        XCTAssertEqual(badge.value as? String, "선택됨")
        badge.tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(badge.exists)
    }

    func testSearchQuerySurvivesKeyboardDismissalAndDetailNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let detail = app.navigationBars["90s 나이키 트랙탑"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        detail.buttons.firstMatch.tap()

        let search = app.searchFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("90s")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.product."))
        XCTAssertEqual(cards.count, 1)
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "90s")
        cards.firstMatch.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertFalse(search.exists, "Library search must not be attached to the detail navigation bar")
        detail.buttons.firstMatch.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "90s")
        XCTAssertEqual(cards.count, 1)
    }

    func testLongPressEditsWithoutOpeningAndDeletionPersists() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let detail = app.navigationBars["90s 나이키 트랙탑"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        detail.buttons.firstMatch.tap()

        let id = "53E00000-0000-4000-8000-000000000053"
        let card = app.buttons["library.product.\(id)"]
        let edit = app.buttons["library.edit-mode"]
        let remove = app.buttons["library.delete.\(id)"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        attach(app, name: "library-normal")
        card.press(forDuration: 0.8)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "완료")
        XCTAssertFalse(detail.exists, "Holding a card must not also open its details")
        attach(app, name: "library-jiggle-editing")

        // Cancelling deletion keeps the product and editing mode intact.
        remove.tap()
        let alert = app.alerts["이 작업을 삭제하겠습니까?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["취소"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        edit.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))

        // A normal tap must still navigate after leaving editing mode.
        card.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.buttons.firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["삭제하기"].tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(edit.label, "수정")
        XCTAssertFalse(edit.isEnabled)

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 10))
        XCTAssertFalse(card.exists)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
