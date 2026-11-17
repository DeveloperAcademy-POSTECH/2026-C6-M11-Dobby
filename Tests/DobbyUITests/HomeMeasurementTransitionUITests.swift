import XCTest

/// Uses the real Home entry with labelled synthetic capture and a private store.
/// Held pulls retain Home; releasing a committed pull reveals capture.
/// No physical camera, AI request, export, or Photos-library save is performed.
@MainActor
final class HomeMeasurementTransitionUITests: XCTestCase {
    func testReleaseOnlyWipeKeepsTapAndShortPullOnHomeAndOpensOneCaptureFlow() {
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

        pull(start, downBy: 160, in: app)
        assertSingleCaptureTutorial(in: app)
        attach(app, name: "home-transition-committed-capture-tutorial")
        continueToCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        _ = waitForHome(in: app)

        // A second complete gesture must create one fresh flow, rather than
        // reveal a hidden earlier cover when the current camera is closed.
        pull(app.buttons["product-flow.start"], downBy: 160, in: app)
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
        prepareDetailDraft(in: app)

        // Confirming a result writes the detail-stage draft. Relaunch, as in
        // ProductDraftResumeTests, to verify the actual persisted card instead
        // of depending on an unconfirmed retake/close navigation side effect.
        app.terminate()
        app.launch()
        _ = waitForHome(in: app)

        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(resume.isHittable)
        XCTAssertTrue(resume.label.contains("상세 촬영"))
        attach(app, name: "home-transition-updated-resume-card")
        resume.tap()
        // The checkpoint may predate acknowledging the detail guide. That
        // existing guide is unrelated to the new Home-to-measurement motion.
        let detailGuide = app.buttons["camera.startDetailCapture"]
        if detailGuide.waitForExistence(timeout: 3) { detailGuide.tap() }
        waitUntilEnabled(app.buttons["camera.captureDetail"])
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["camera.captureDetail"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
        attach(app, name: "home-transition-resume-keeps-saved-detail-stage")
    }

    func testArrowPullCancelsBelowThresholdAndOpensOneCaptureFlowAfterRelease() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        _ = waitForHome(in: app)

        let arrow = app.descendants(matching: .any)["home.pullArrow"].firstMatch
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        arrow.tap()
        assertHomeWithoutCapture(in: app)
        pull(arrow, downBy: 24, in: app)
        assertHomeWithoutCapture(in: app)
        attach(app, name: "home-arrow-short-pull-cancelled")

        pull(arrow, downBy: 160, in: app)
        assertSingleCaptureTutorial(in: app)
        continueToCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        _ = waitForHome(in: app)

        // Returning from capture must enable a fresh drag from the arrow too.
        pull(arrow, downBy: 160, in: app)
        assertSingleCaptureTutorial(in: app)
        continueToCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        assertHomeWithoutCapture(in: app)
    }

    func testBlankAndGuidanceDragsKeepFittedHomeFixedWithoutStartingCapture() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        prepareDetailDraft(in: app)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        _ = waitForHome(in: app)

        let arrow = app.descendants(matching: .any)["home.pullArrow"].firstMatch
        let guidance = app.descendants(matching: .any)["home.guidance"].firstMatch
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let arrowFrame = arrow.frame
        let guidanceFrame = guidance.frame
        let resumeFrame = resume.frame
        XCTAssertTrue(arrow.isHittable)
        XCTAssertTrue(resume.isHittable)
        XCTAssertTrue(app.frame.contains(resumeFrame),
                      "The large-text draft must fit on Home without needing a scroll")

        let blank = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: max(1, (resumeFrame.minX - app.frame.minX) / 2),
                                 dy: guidanceFrame.midY - app.frame.minY))
        blank.press(forDuration: 0.05, thenDragTo: blank.withOffset(CGVector(dx: 0, dy: -180)))
        let text = guidance.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 10))
        text.press(forDuration: 0.05, thenDragTo: text.withOffset(CGVector(dx: 0, dy: -120)))
        blank.press(forDuration: 0.05, thenDragTo: blank.withOffset(CGVector(dx: 0, dy: 120)))

        assertHomeWithoutCapture(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
        XCTAssertEqual(arrow.frame.minY, arrowFrame.minY, accuracy: 1)
        XCTAssertEqual(guidance.frame.minY, guidanceFrame.minY, accuracy: 1)
        XCTAssertEqual(resume.frame.minY, resumeFrame.minY, accuracy: 1)
        attach(app, name: "home-background-drags-keep-scroll-position")
    }

    func testCommittedPullWithoutPlacementTutorialRestoresCaptureChromeAndPhoto() {
        continueAfterFailure = false
        let app = fixtureApp(showsTutorial: false)
        app.launch()
        defer { app.terminate() }

        pull(waitForHome(in: app), downBy: 160, in: app)
        assertCaptureScreen(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home.measurementTransition"].firstMatch.exists)
        attach(app, name: "home-transition-direct-capture-chrome-and-photo")

        app.buttons["closeGarmentCapture"].tap()
        assertHomeWithoutCapture(in: app)
    }

    private func fixtureApp(showsTutorial: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        if showsTutorial { app.launchArguments.append("--garment-preview-capture-tutorial") }
        return app
    }

    private func prepareDetailDraft(in app: XCUIApplication) {
        pull(waitForHome(in: app), downBy: 160, in: app)
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
        assertCaptureTitle(in: app)
        let continueButton = app.buttons["continueGarmentCaptureTutorial"]
        XCTAssertTrue(continueButton.isEnabled, continueButton.debugDescription)
        XCTAssertTrue(continueButton.isHittable, app.debugDescription)
    }

    private func continueToCapture(in app: XCUIApplication) {
        app.buttons["continueGarmentCaptureTutorial"].tap()
        assertCaptureScreen(in: app)
    }

    private func assertCaptureScreen(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["closeGarmentCapture"].isHittable)
        assertCaptureTitle(in: app)
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(viewport.frame.height, 0)
        XCTAssertGreaterThanOrEqual(viewport.frame.minY, app.buttons["closeGarmentCapture"].frame.maxY,
                                   "The release-only wipe must reveal the photograph below its stationary toolbar")
        XCTAssertTrue(app.frame.contains(viewport.frame), viewport.debugDescription)
        let progress = app.descendants(matching: .any)["product-flow.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(progress.frame.height, 0)
        XCTAssertLessThanOrEqual(progress.frame.maxY, app.buttons["closeGarmentCapture"].frame.minY,
                                "The revealed progress bar must retain its position above the toolbar")
    }

    private func assertCaptureTitle(in app: XCUIApplication) {
        let title = app.navigationBars.staticTexts["실측 촬영"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(title.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(title.frame))
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
