import XCTest

/// Verifies the merged home and actual URL delivery. These checks do not copy
/// product data, start Live Activities or open external marketplace links.
final class AppRoutingTests: XCTestCase {
    @MainActor
    func testHomeFeaturesRemainReachableAndReturnToHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        expectHome(in: app)

        openLiDARLab(in: app)
        app.buttons["closeLiDARLab"].tap()
        expectHome(in: app)
        XCTAssertFalse(app.buttons["closeLiDARLab"].exists)

        app.buttons["openExportChannels"].tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["내보내기"].exists)
        app.buttons["export.close"].tap()
        expectHome(in: app)

        app.buttons["openQuickCopy"].tap()
        XCTAssertTrue(app.navigationBars["상품 정보 빠른 복사"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["quickCopy.feedback"].label, "복사할 항목을 선택하세요")
        app.navigationBars["상품 정보 빠른 복사"].buttons.firstMatch.tap()
        expectHome(in: app)
    }

    @MainActor
    func testCopyHomeDeepLinkDismissesLiDARAndShowsCopyRequest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)

        app.open(URL(string: "dobby-copy://home")!)
        expectCopyRequest(in: app)
        XCTAssertTrue(app.buttons["closeLiDARLab"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["측정 실험실"].exists)
    }

    @MainActor
    func testCopyHomeDeepLinkDismissesNestedLiDARPreviewAndShowsCopyRequest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["closeGarmentCapture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)

        app.open(URL(string: "dobby-copy://home")!)
        expectCopyRequest(in: app)
        XCTAssertTrue(app.buttons["closeGarmentCapture"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["closeLiDARLab"].exists)
        XCTAssertFalse(app.navigationBars["측정 실험실"].exists)
    }

    @MainActor
    func testCopyHomeDeepLinkDismissesExportAndShowsCopyRequest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        expectHome(in: app)
        app.buttons["openExportChannels"].tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))

        app.open(URL(string: "dobby-copy://home")!)
        expectCopyRequest(in: app)
        XCTAssertTrue(app.buttons["export.close"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["내보내기"].exists)
    }

    @MainActor
    func testExpiredCopyRequestDismissesLiDARAndProcessesAfterNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)

        // Valid route syntax with a fresh, nonexistent session. The coordinator
        // must reject it before copying or starting/opening anything external.
        let url = URL(string: "dobby-copy://copy?session=\(UUID().uuidString)&field=brand")!
        app.open(url)
        XCTAssertTrue(app.navigationBars["상품 정보 복사"].waitForExistence(timeout: 10))
        let status = app.staticTexts["quickCopy.routeStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let rejected = expectation(for: NSPredicate(format: "label == %@", "종료되었거나 만료된 도우미입니다. 새로 시작하세요."),
                                   evaluatedWith: status)
        wait(for: [rejected], timeout: 10)
        XCTAssertTrue(app.buttons["closeLiDARLab"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["측정 실험실"].exists)
        XCTAssertFalse(app.buttons["서비스 링크 다시 열기"].exists)
        XCTAssertFalse(app.buttons["이번에 복사한 값"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "expired-copy-request-after-lidar-dismissal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func expectHome(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Dobby"].waitForExistence(timeout: 10), file: file, line: line)
        for identifier in ["openLiDARLab", "openQuickCopy", "openExportChannels"] {
            let entry = app.buttons[identifier]
            XCTAssertTrue(entry.waitForExistence(timeout: 5), identifier, file: file, line: line)
            XCTAssertTrue(entry.isHittable, identifier, file: file, line: line)
        }
    }

    @MainActor
    private func expectCopyRequest(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["상품 정보 복사"].waitForExistence(timeout: 10), file: file, line: line)
        let status = app.staticTexts["quickCopy.routeStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(status.label, "복사 요청을 기다리고 있습니다", "Home links must not execute a copy request", file: file, line: line)
        XCTAssertFalse(app.staticTexts["quickCopy.feedback"].exists, file: file, line: line)
    }
}
