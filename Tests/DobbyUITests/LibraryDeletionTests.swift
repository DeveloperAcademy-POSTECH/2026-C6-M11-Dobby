import XCTest

/// Exercises confirmation against a test-owned store, without external apps or real captures.
@MainActor
final class LibraryDeletionTests: XCTestCase {
    func testCancelKeepsProductAndConfirmedDeletionSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssertTrue(app.navigationBars["제품 상세"].waitForExistence(timeout: 10))
        app.navigationBars["제품 상세"].buttons.firstMatch.tap()

        let productID = "53E00000-0000-4000-8000-000000000053"
        let card = app.buttons["library.product.\(productID)"]
        let remove = app.buttons["library.delete.\(productID)"]
        let edit = app.buttons["library.edit-mode"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertEqual(edit.label, "수정")
        XCTAssertFalse(remove.exists)

        edit.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "완료")
        XCTAssertFalse(card.exists)
        attachScreenshot(app, name: "library-edit-mode")

        remove.tap()
        let alert = app.alerts["이 작업을 삭제하겠습니까?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["삭제된 작업은 복구할 수 없어요"].exists)
        XCTAssertTrue(alert.buttons["취소"].exists)
        XCTAssertTrue(alert.buttons["삭제하기"].exists)
        XCTAssertEqual(alert.buttons.count, 2)
        let deleteButton = alert.buttons["삭제하기"]
        let cancelButton = alert.buttons["취소"]
        XCTAssertLessThan(deleteButton.frame.midX, cancelButton.frame.midX)
        XCTAssertEqual(deleteButton.frame.midY, cancelButton.frame.midY, accuracy: 1)
        XCTAssertFalse(app.navigationBars["제품 상세"].exists)
        attachScreenshot(app, name: "library-delete-confirmation")
        alert.buttons["취소"].tap()

        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        XCTAssertEqual(edit.label, "완료")
        edit.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
        XCTAssertEqual(edit.label, "수정")
        card.tap()
        XCTAssertTrue(app.navigationBars["제품 상세"].waitForExistence(timeout: 10))
        app.navigationBars["제품 상세"].buttons.firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        edit.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["삭제하기"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(edit.isEnabled)

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertFalse(app.buttons["library.product.\(productID)"].exists)
        XCTAssertFalse(app.buttons["library.delete.\(productID)"].exists)
    }

    private func expectEmptyLibrary(in app: XCUIApplication, file: StaticString = #filePath,
                                    line: UInt = #line) {
        let title = app.staticTexts["library.empty.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(title.label, "보관함이 비어있어요", file: file, line: line)
        let start = app.buttons["library.empty.start-measurement"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(start.label, "실측 시작하기", file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).firstMatch.exists, file: file, line: line)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
