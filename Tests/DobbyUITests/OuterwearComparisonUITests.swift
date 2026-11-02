import XCTest

final class OuterwearComparisonUITests: XCTestCase {
    @MainActor
    func testDebugLabOpensComparisonWithoutStartingPaidRequests() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let entry = app.buttons["openOuterwearComparison"]
        for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["pickOuterwearComparisonPhoto"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["runOuterwearComparison"].isEnabled)
        XCTAssertTrue(app.staticTexts["자동 분류 대상: 아우터·후드가 달린 아우터·Hoodie·Sweater"].exists)
        XCTAssertFalse(app.buttons["outerwearComparisonCategory"].exists)
        XCTAssertTrue(app.navigationBars["아우터 AI 비교 실험"].exists)
        app.buttons["완료"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
