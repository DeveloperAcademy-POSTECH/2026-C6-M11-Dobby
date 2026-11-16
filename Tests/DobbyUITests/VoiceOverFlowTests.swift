import XCTest

/// Inspect the real accessibility tree with synthetic capture data. These tests
/// do not claim to replace a physical-device VoiceOver speech/rotor walkthrough.
@MainActor
final class VoiceOverFlowTests: XCTestCase {
    func testHomeAndSettingsHaveDescriptiveAccessibleControls() throws {
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.label.contains("실측"))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(app.staticTexts["설정"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    func testMeasurementPointsReadPhotoRelativePositionsAndCameraNames() throws {
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        enterMeasurementResult(app)
        let point = app.descendants(matching: .any)["garmentMeasurementPoint_shoulder_left"].firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 10))
        XCTAssertTrue(point.label.contains("어깨"))
        let value = try XCTUnwrap(point.value as? String)
        XCTAssertTrue(value.contains("사진 가로") && value.contains("퍼센트"))
        let position = try XCTUnwrap(Self.measurementPhotoCoordinates(in: value))
        XCTAssertTrue((0...1).contains(position.x) && (0...1).contains(position.y))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        let shutter = app.buttons["camera.captureDetail"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.label.contains("상세 사진"))
        XCTAssertTrue(app.buttons["camera.openGallery"].label.contains("사진"))
    }

    func testGalleryDeleteDialogRemovesBackgroundControlsFromAccessibilityTree() {
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        enterDetailCapture(app)
        tap(app, "camera.captureDetail")
        tap(app, "camera.openGallery")
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let pageBefore = pager.value as? String
        XCTAssertTrue(app.buttons["camera.galleryClose"].exists)
        tap(app, "camera.galleryDelete")
        XCTAssertTrue(app.buttons["camera.galleryConfirmDelete"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.galleryClose"].exists)
        let trashHidden = app.buttons["camera.galleryDelete"].wait(for: \.exists, toEqual: false, timeout: 3)
        if !trashHidden { XCTContext.runActivity(named: "Delete dialog accessibility tree") { activity in
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            activity.add(tree)
        } }
        XCTAssertTrue(trashHidden)
        XCTAssertFalse(app.buttons["camera.galleryThumbnail.0"].exists)
        // The existing outside-tap cancellation must still work without adding
        // a visible cancel control to the designer's popover.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["camera.galleryClose"].waitForExistence(timeout: 10))
        XCTAssertEqual(pager.value as? String, pageBefore)
    }

    func testInputNamesPersistAfterEditingAndPhotoControlsStayNamed() throws {
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        enterDetailCapture(app)
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        let name = app.textFields["product-info.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(name.label.contains("제품명") && name.label.contains("필수"))
        name.tap()
        name.typeText("VoiceOver fixture product")
        XCTAssertTrue(name.label.contains("제품명"))
        XCTAssertEqual(name.value as? String, "VoiceOver fixture product")
        let description = app.textViews["product-info.detail"]
        XCTAssertTrue(description.label.contains("설명"))
        let price = app.textFields["product-info.price"]
        XCTAssertTrue(price.label.contains("가격") && price.label.contains("원"))
        let photoCount = app.descendants(matching: .any)["product-info.photo-count"].firstMatch
        XCTAssertTrue(photoCount.label.contains("최대 10장"))
        // Return the form to its beginning and dismiss the keyboard through the
        // already supported scroll interaction, then open the first visible photo.
        for _ in 0..<3 { app.swipeDown() }
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
        let first = try XCTUnwrap(photos.allElementsBoundByIndex.first(where: \.isHittable))
        XCTAssertTrue(first.label.contains("사진"))
        first.tap()
        let rotate = app.buttons["product-gallery.rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        XCTAssertEqual(rotate.label, "사진 회전")
        XCTAssertEqual(app.buttons["product-gallery.close"].label, "닫기")
        rotate.tap()
        let rotated = expectation(for: NSPredicate(format: "value == %@", "왼쪽으로 90도 회전"), evaluatedWith: rotate)
        wait(for: [rotated], timeout: 10)
        XCTAssertTrue(rotate.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        tap(app, "product-gallery.close")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 10))
    }

    private func fixtureApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        return app
    }

    private func enterMeasurementResult(_ app: XCUIApplication) {
        startMeasurementFromHome(in: app)
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20))
    }

    private func enterDetailCapture(_ app: XCUIApplication) {
        enterMeasurementResult(app)
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let control = app.buttons[id]
        XCTAssertTrue(control.waitForExistence(timeout: 20), id)
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: 20), id)
        control.tap()
    }
}
