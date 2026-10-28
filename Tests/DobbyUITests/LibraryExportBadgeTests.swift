import XCTest

/// Uses an isolated product store and only opens the in-app guides.
/// It never starts a copy helper or opens an external platform.
@MainActor
final class LibraryExportBadgeTests: XCTestCase {
    func testFruitsSelectionsAddOneBadgeToTheSavedProductAndSurviveRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        app.navigationBars["90s 나이키 트랙탑"].buttons.firstMatch.tap()

        let cardID = "library.product.53E00000-0000-4000-8000-000000000053"
        let card = app.buttons[cardID]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(card.label.contains("선택한 내보내기 플랫폼"))
        card.tap()

        let export = app.buttons["library.export"]
        reveal(export, in: app)
        export.tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))

        let fruitsA = app.buttons["후루츠패밀리로 내보내기 (A)"]
        reveal(fruitsA, in: app)
        fruitsA.tap()
        XCTAssertTrue(app.navigationBars["후루츠패밀리로 내보내기"].waitForExistence(timeout: 10))
        app.navigationBars["후루츠패밀리로 내보내기"].buttons.firstMatch.tap()

        let fruitsB = app.buttons["후루츠패밀리로 내보내기 (B)"]
        reveal(fruitsB, in: app)
        fruitsB.tap()
        let closeGuide = app.buttons["export.fruits.overlay.close"]
        XCTAssertTrue(closeGuide.waitForExistence(timeout: 10))
        closeGuide.tap()
        app.buttons["export.close"].tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        app.navigationBars["90s 나이키 트랙탑"].buttons.firstMatch.tap()
        assertOnlyFruitsBadge(on: app.buttons[cardID])

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        assertOnlyFruitsBadge(on: app.buttons[cardID])
    }

    private func assertOnlyFruitsBadge(on card: XCUIElement, file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertTrue(card.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(card.label.contains("선택한 내보내기 플랫폼"), file: file, line: line)
        XCTAssertEqual(card.label.components(separatedBy: "후루츠패밀리로 내보내기").count - 1, 1,
                       file: file, line: line)
        XCTAssertFalse(card.label.contains("Instagram으로 내보내기"), file: file, line: line)
        XCTAssertFalse(card.label.contains("카페24로 내보내기"), file: file, line: line)
        XCTAssertFalse(card.label.contains("네이버스토어로 내보내기"), file: file, line: line)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
