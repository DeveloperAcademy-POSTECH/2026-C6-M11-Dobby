import XCTest

@MainActor
final class LibraryStickyToolbarTests: XCTestCase {
    func testSearchCollapsesByDirectionWhileToolbarRemainsFixedAndUsable() throws {
        guard let token = ProcessInfo.processInfo.environment["DOBBY_LIBRARY_SCROLL_TEST_STORE"] else {
            throw XCTSkip("Requires an isolated store seeded with scrollable library items")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", token]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 15))
        app.tabBars.buttons["보관함"].tap()
        let edit = app.buttons["library.edit-mode"]
        let search = app.searchFields["library.search"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let originalFrame = edit.frame
        screenshot(app, name: "library-search-expanded-fixed-toolbar")
        let list = app.scrollViews["library.products"]
        for _ in 0..<3 { list.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        XCTAssertEqual(edit.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertFalse(search.isHittable)
        screenshot(app, name: "library-search-hidden-fixed-toolbar")
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(edit.frame.minY, originalFrame.minY, accuracy: 1)
        screenshot(app, name: "library-search-revealed-away-from-top")
        edit.tap()
        XCTAssertEqual(edit.label, "완료")
        // The custom Done pill has a different height from the native Edit
        // button; their vertical centers remain on the same fixed toolbar.
        XCTAssertEqual(edit.frame.midY, originalFrame.midY, accuracy: 1)
        edit.tap()
        search.tap()
        search.typeText("No matching item")
        XCTAssertTrue(app.staticTexts["library.search.empty.title"].waitForExistence(timeout: 5))
        search.typeText("\n")
        app.tabBars.buttons["홈"].tap()
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(edit.frame.minY, originalFrame.minY, accuracy: 1)
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
