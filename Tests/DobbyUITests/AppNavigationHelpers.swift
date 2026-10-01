import XCTest

extension XCTestCase {
    /// Existing measurement tests enter through the real home menu. This does
    /// not reset saved measurements, photos, preferences or the clipboard.
    @MainActor
    func launchLiDARLab(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.launch()
        openLiDARLab(in: app, file: file, line: line)
    }

    @MainActor
    func openLiDARLab(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let entry = app.buttons["openLiDARLab"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Home must expose the measurement lab", file: file, line: line)
        guard entry.exists else { return }
        XCTAssertTrue(entry.isHittable, file: file, line: line)
        entry.tap()
        XCTAssertTrue(app.buttons["closeLiDARLab"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.navigationBars["측정 실험실"].exists, file: file, line: line)
    }
}
