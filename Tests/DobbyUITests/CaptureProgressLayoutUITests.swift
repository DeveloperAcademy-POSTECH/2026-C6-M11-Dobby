import XCTest

/// Exercises only labelled synthetic photographs and an isolated draft store.
/// These checks cover screen composition, not physical camera accuracy.
final class CaptureProgressLayoutUITests: XCTestCase {
    @MainActor
    func testAMeasurementHeaderMatchesFigmaWithoutTheFlowFixtureBanner() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        launchLiDARLab(app)
        defer { app.terminate() }
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        preview.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        let bar = try assertHeader(stage: 1, app: app)
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertEqual(viewport.frame.minY - bar.minY, 84, accuracy: 1)
        XCTAssertFalse(app.staticTexts["product-flow.fixture"].exists)
        screenshot("263-measurement-header-without-fixture-banner")
    }

    @MainActor
    func testCaptureResultAndDetailsKeepTheFigmaHeaderAcrossRepeatedNavigation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        for pass in 1...2 {
            openCapture(in: app)
            let firstBar = try assertHeader(stage: 1, app: app)
            try assertPhoto("garmentCameraViewport", follows: firstBar, app: app)
            if pass == 1 {
                screenshot("263-measurement-4x3")
                try checkMeasurementRatios(in: app)
            }

            armSyntheticGarmentCapture(in: app)
            app.buttons["captureGarment"].tap()
            waitUntilEnabled(app.buttons["confirmGarmentMeasurement"])
            let resultBar = try assertHeader(stage: 2, app: app)
            try assertPhoto("garmentResultPhotoViewport", follows: resultBar, app: app)
            if pass == 1 { screenshot("263-measurement-result-4x3") }

            app.buttons["confirmGarmentMeasurement"].tap()
            let guide = app.buttons["camera.startDetailCapture"]
            XCTAssertTrue(guide.waitForExistence(timeout: 15))
            guide.tap()
            XCTAssertTrue(guide.waitForNonExistence(timeout: 10))
            waitUntilEnabled(app.buttons["camera.captureDetail"])
            let detailBar = try assertHeader(stage: 3, app: app)
            try assertPhoto("camera.photoViewport", follows: detailBar, app: app)
            XCTAssertEqual(app.buttons["camera.selectPhotos"].frame.height, 44, accuracy: 1)
            if pass == 1 { screenshot("263-detail-capture-4x3") }

            app.buttons["product-flow.back"].tap()
            _ = try assertHeader(stage: 2, app: app)
            app.buttons["product-flow.back"].tap()
            let returnedBar = try assertHeader(stage: 1, app: app)
            XCTAssertEqual(returnedBar.minY, firstBar.minY, accuracy: 0.5,
                           "Returning from another stage must not accumulate navigation insets")
            try assertPhoto("garmentCameraViewport", follows: returnedBar, app: app)
            app.buttons["closeGarmentCapture"].tap()
            XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["product-flow.progress"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["garmentResultProgress"].exists)
        }
    }

    @MainActor
    private func checkMeasurementRatios(in app: XCUIApplication) throws {
        let initialBar = try assertHeader(stage: 1, app: app)
        for (ratio, expectedAspect) in [("1:1", CGFloat(1)), ("16:9", 9.0 / 16), ("4:3", 4.0 / 5)] {
            app.buttons["garmentCaptureOptions"].tap()
            let option = app.buttons["camera.aspectRatioOption"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            let selection = app.buttons["camera.aspectRatio.\(ratio)"]
            XCTAssertTrue(selection.waitForExistence(timeout: 5))
            selection.tap()
            app.buttons["camera.aspectRatioBack"].tap()
            app.buttons["camera.dismissOptions"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
            XCTAssertTrue(app.descendants(matching: .any)["camera.optionsMenu"].firstMatch
                .waitForNonExistence(timeout: 5))

            let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
            let settled = expectation(for: NSPredicate { _, _ in
                guard viewport.exists, viewport.frame.height > 0 else { return false }
                return abs(viewport.frame.width / viewport.frame.height - expectedAspect) < 0.005
            }, evaluatedWith: viewport)
            wait(for: [settled], timeout: 10)
            let bar = try assertHeader(stage: 1, app: app)
            XCTAssertEqual(bar.minY, initialBar.minY, accuracy: 0.5)
            let back = app.buttons["closeGarmentCapture"]
            let shutter = app.buttons["captureGarment"]
            let more = app.buttons["garmentCaptureOptions"]
            let zoom = app.buttons["cameraZoomSelector"]
            XCTAssertTrue(more.isHittable && zoom.isHittable)
            XCTAssertGreaterThanOrEqual(viewport.frame.minY, back.frame.maxY,
                                       "Changing aspect must not move the photograph into the toolbar")
            XCTAssertFalse(shutter.frame.intersects(more.frame))
            XCTAssertFalse(shutter.frame.intersects(zoom.frame))
            screenshot("263-measurement-\(ratio.replacingOccurrences(of: ":", with: "x"))")
        }
    }

    @MainActor
    @discardableResult
    private func assertHeader(stage: Int, app: XCUIApplication) throws -> CGRect {
        let identifier = stage == 2 ? "garmentResultProgress" : "product-flow.progress"
        let progress = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        let titles = [1: "실측", 2: "실측 결과", 3: "제품 상세 촬영"]
        XCTAssertEqual(progress.value as? String, "4단계 중 \(stage)단계, \(try XCTUnwrap(titles[stage]))")
        XCTAssertEqual(progress.frame.height, 3, accuracy: 0.5)
        XCTAssertEqual(progress.frame.minX, app.frame.minX, accuracy: 0.5)
        XCTAssertEqual(progress.frame.width, app.frame.width, accuracy: 0.5)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: identifier).count, 1)
        let other = stage == 2 ? "product-flow.progress" : "garmentResultProgress"
        XCTAssertFalse(app.descendants(matching: .any)[other].exists)
        let back = app.buttons[stage == 1 ? "closeGarmentCapture" : "product-flow.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.height, 44, accuracy: 1)
        XCTAssertEqual(back.frame.minY - progress.frame.maxY, 13, accuracy: 1)
        return progress.frame
    }

    @MainActor
    private func assertPhoto(_ identifier: String, follows progress: CGRect, app: XCUIApplication) throws {
        let photo = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        // SwiftUI's scaled-to-fill fixture exposes its intrinsic AX image
        // beyond the screen's horizontal clip. Assert the visible photograph.
        let photoFrame = identifier == "camera.photoViewport" ? photo.frame.intersection(app.frame) : photo.frame
        XCTAssertGreaterThan(photoFrame.height, 0)
        // The labelled fixture uses an 800×1000 source. Measurement keeps
        // its complete 4:5 sensor image; detail capture has its own 4:3 crop.
        let aspect: CGFloat = identifier == "camera.photoViewport" ? 3.0 / 4 : 4.0 / 5
        XCTAssertEqual(photoFrame.width / photoFrame.height, aspect, accuracy: 0.005)
        // The 402×874 Figma reference has its progress at y=62 and photo at
        // y=146. Other window sizes retain their responsive camera placement.
        if abs(app.frame.width - 402) < 1 && abs(app.frame.height - 874) < 1 {
            if identifier == "garmentResultPhotoViewport" {
                // Every result ratio starts below the same header. Preserve
                // the complete 4:5 fixture without vertically centering it.
                let summary = app.descendants(matching: .any)["garmentResultMeasurementSummary"].firstMatch
                XCTAssertTrue(summary.exists)
                XCTAssertEqual(photoFrame.minY, progress.minY + 84, accuracy: 1)
                XCTAssertGreaterThanOrEqual(summary.frame.minY - photoFrame.maxY, 33)
            } else {
                // The synthetic provenance banner occupies a safe-area inset
                // below the native toolbar. Production has no such banner.
                let banner = app.staticTexts["product-flow.fixture"]
                let expectedTop = max(progress.minY + 84, banner.frame.maxY + 14)
                XCTAssertEqual(photoFrame.minY, expectedTop, accuracy: 1)
            }
        }
    }

    @MainActor
    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top", "--garment-preview-matched-framing"]
        return app
    }

    @MainActor
    private func openCapture(in app: XCUIApplication) {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.isHittable)
        start.tap()
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate { _, _ in element.isEnabled && element.isHittable },
                                evaluatedWith: element)
        wait(for: [ready], timeout: 15)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
