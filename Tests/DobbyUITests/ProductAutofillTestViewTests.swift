import XCTest

/// The debug screen is opened through Settings with a seeded synthetic photo.
/// These opt-in fixtures never open the photo library, upload photos, or spend API credits.
final class ProductAutofillTestViewTests: XCTestCase {
    @MainActor
    func testSettingsOpensIsolatedAITestAndShowsGeneratedFixture() {
        let app = openTestScreen(result: "success")
        defer { app.terminate() }

        XCTAssertTrue(element("ai-test.fixture", in: app).exists,
                      "Synthetic generation must be visibly distinguished from a live AI response")
        XCTAssertTrue(app.buttons["ai-test.pickPhotos"].firstMatch.exists)
        XCTAssertTrue(app.buttons["ai-test.clear"].firstMatch.exists)
        tap("ai-test.generate", in: app)

        let name = element("ai-test.result.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(name.label.contains("AI 테스트 네이비 집업 후드"))
        let brand = element("ai-test.result.brand", in: app)
        XCTAssertTrue(brand.exists)
        XCTAssertTrue(brand.label.contains("TEST BRAND"))
        let description = element("ai-test.result.description", in: app)
        XCTAssertTrue(description.exists)
        XCTAssertTrue(description.label.contains("네이비 컬러와 전면 지퍼"))
        XCTAssertFalse(element("ai-test.error", in: app).exists)

        // Local generation fixtures have no HTTP response headers. The screen
        // must still expose diagnostics as unavailable, without inventing counts.
        for identifier in ["ai-test.research.status", "ai-test.research.calls", "ai-test.research.attempts"] {
            let diagnostic = element(identifier, in: app)
            XCTAssertTrue(diagnostic.exists, identifier)
            XCTAssertFalse(diagnostic.label.isEmpty, identifier)
        }
        let copy = app.buttons["ai-test.copy"].firstMatch
        reveal(copy, in: app)
        XCTAssertTrue(copy.isEnabled)
        // Checking availability avoids replacing the user's current clipboard.
        screenshot(app, name: "ai-test-screen-generated-synthetic-result")
    }

    @MainActor
    func testCancellingDebugGenerationKeepsPhotosAndRejectsTheLateFixtureResult() {
        let app = openTestScreen(result: "delay")
        defer { app.terminate() }
        tap("ai-test.generate", in: app)
        tap("ai-test.cancel", in: app)

        let generate = app.buttons["ai-test.generate"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.wait(for: \.isEnabled, toEqual: true, timeout: 5),
                      "Cancellation must leave the seeded photo available for another explicit attempt")
        XCTAssertFalse(element("ai-test.result.name", in: app).exists)
        XCTAssertFalse(element("ai-test.error", in: app).exists)
        let lateResult = expectation(for: NSPredicate(format: "exists == true"),
                                     evaluatedWith: element("ai-test.result.name", in: app))
        lateResult.isInverted = true
        wait(for: [lateResult], timeout: 6)
        XCTAssertTrue(generate.isEnabled)
        XCTAssertTrue(element("ai-test.fixture", in: app).exists)
        screenshot(app, name: "ai-test-screen-cancelled-synthetic-generation")
    }

    @MainActor
    private func openTestScreen(result: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--ai-test-photo-fixture"]
        app.launchEnvironment["DOBBY_AI_FIXTURE_RESULT"] = result
        app.launch()
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        tap("settings.aiTest", in: app)
        XCTAssertTrue(app.navigationBars["AI 정보 생성 테스트"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("ai-test.fixture", in: app).waitForExistence(timeout: 5))
        let generate = app.buttons["ai-test.generate"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), identifier)
        reveal(button, in: app)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 5), identifier)
        button.tap()
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, target.identifier)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
