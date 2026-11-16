import XCTest

/// Uses the real Home entry with labelled synthetic capture and a private store.
/// No physical camera, AI request, export, or Photos-library save is performed.
@MainActor
final class HomeMeasurementTransitionUITests: XCTestCase {
    func testTapAndShortPullReturnHomeWhileCommittedPullOpensOneCaptureFlow() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        let start = waitForHome(in: app)

        start.tap()
        assertHomeWithoutCapture(in: app)
        pull(start, downBy: 24, in: app)
        assertHomeWithoutCapture(in: app)
        attach(app, name: "home-transition-short-pull-cancelled")

        pull(start, downBy: 260, in: app)
        assertSingleCaptureTutorial(in: app)
        attach(app, name: "home-transition-committed-capture-tutorial")
        continueToCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        _ = waitForHome(in: app)

        // A second complete gesture must create one fresh flow, rather than
        // reveal a hidden earlier cover when the current camera is closed.
        pull(app.buttons["product-flow.start"], downBy: 260, in: app)
        assertSingleCaptureTutorial(in: app)
        continueToCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        assertHomeWithoutCapture(in: app)
    }

    func testHomeResumeCardRestoresItsSavedStageWithoutStartingMeasurementAgain() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        pull(waitForHome(in: app), downBy: 260, in: app)
        assertSingleCaptureTutorial(in: app)
        continueToCapture(in: app)
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        waitUntilEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()

        let detailGuide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(detailGuide.waitForExistence(timeout: 15))
        detailGuide.tap()
        waitUntilEnabled(app.buttons["camera.captureDetail"])

        // Confirming a result writes the detail-stage draft. Relaunch, as in
        // ProductDraftResumeTests, to verify the actual persisted card instead
        // of depending on an unconfirmed retake/close navigation side effect.
        app.terminate()
        app.launch()
        _ = waitForHome(in: app)

        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        for _ in 0..<5 where !resume.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(resume.isHittable)
        XCTAssertTrue(resume.label.contains("상세 촬영"))
        resume.tap()
        // The checkpoint may predate acknowledging the detail guide. That
        // existing guide is unrelated to the new Home-to-measurement motion.
        if detailGuide.waitForExistence(timeout: 3) { detailGuide.tap() }
        waitUntilEnabled(app.buttons["camera.captureDetail"])
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["camera.captureDetail"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
        attach(app, name: "home-transition-resume-keeps-saved-detail-stage")
    }

    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top", "--garment-preview-capture-tutorial"]
        return app
    }

    @discardableResult
    private func waitForHome(in app: XCUIApplication) -> XCUIElement {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate { _, _ in start.isHittable && start.isEnabled },
                                evaluatedWith: start)
        wait(for: [ready], timeout: 10)
        return start
    }

    private func assertHomeWithoutCapture(in app: XCUIApplication) {
        _ = waitForHome(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["home.guidance"].firstMatch.exists)
        XCTAssertFalse(app.buttons["closeGarmentCapture"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
    }

    private func pull(_ element: XCUIElement, downBy distance: CGFloat, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let available = max(0, app.frame.maxY - 90 - element.frame.midY)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: min(distance, available))))
    }

    private func assertSingleCaptureTutorial(in app: XCUIApplication) {
        let tutorial = app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch
        XCTAssertTrue(tutorial.waitForExistence(timeout: 15))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "garmentCaptureTutorial").count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
        XCTAssertTrue(app.buttons["continueGarmentCaptureTutorial"].isHittable)
    }

    private func continueToCapture(in app: XCUIApplication) {
        app.buttons["continueGarmentCaptureTutorial"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["closeGarmentCapture"].isHittable)
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate { _, _ in element.isEnabled && element.isHittable },
                                evaluatedWith: element)
        wait(for: [ready], timeout: 15)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
