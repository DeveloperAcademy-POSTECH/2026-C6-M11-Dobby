import XCTest

/// Uses the existing flow-preview capture provider. No physical camera,
/// LiDAR session, device install, AI generation or network call is performed.
@MainActor
final class ProductInputCameraUITests: XCTestCase {
    func testInputAddCameraCancelAndReturnKeepCurrentInformation() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        tap(app, "product-flow.start")
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 30))
        let count = photoCount(app)
        let name = app.textFields["product-info.name"]
        name.tap()
        name.typeText("촬영 전 입력한 이름")
        app.swipeDown()

        openAdditionalCamera(app)
        XCTAssertFalse(app.buttons["captureGarment"].exists, "Photo add must never enter LiDAR capture")
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists)
        XCTAssertFalse(app.buttons["camera.selectPhotos"].isEnabled)
        tap(app, "camera.captureDetail")
        tap(app, "camera.openGallery")
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        XCTAssertEqual(pager.value as? String, "1 / 1", "Only new captures belong to the supplemental session")
        tap(app, "촬영으로 돌아가기")
        tap(app, "product-flow.back")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 10))
        XCTAssertEqual(photoCount(app), count, "Cancel must not append temporary captures")
        XCTAssertEqual(name.value as? String, "촬영 전 입력한 이름")

        openAdditionalCamera(app)
        tap(app, "camera.captureDetail")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 30))
        XCTAssertEqual(photoCount(app), count + 2)
        XCTAssertEqual(name.value as? String, "촬영 전 입력한 이름")
        // A fresh add-camera entry starts empty and cannot repeat a previous
        // successful handoff or save the existing measurement photos again.
        openAdditionalCamera(app)
        XCTAssertFalse(app.buttons["camera.selectPhotos"].isEnabled)
        XCTAssertFalse(app.buttons["camera.openGallery"].isEnabled)
        tap(app, "product-flow.back")
        XCTAssertEqual(photoCount(app), count + 2)
    }

    func testLibraryEditKeepsOverflowDisablesDoneAndCanDiscardAddedCaptures() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 15))
        let library = app.tabBars.buttons["보관함"]
        XCTAssertTrue(library.wait(for: \.isHittable, toEqual: true, timeout: 10))
        library.tap()
        XCTAssertTrue(library.wait(for: \.isSelected, toEqual: true, timeout: 10))
        tap(app, "debug.export-sample")
        tap(app, "library.edit")
        let initialCount = photoCount(app)
        XCTAssertEqual(initialCount, 10)
        // Start with nine selected photos, then return both new captures to
        // verify that all eleven remain while completion is disabled.
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "product-info.delete-photo.")).firstMatch
        let removedID = delete.identifier
        delete.tap()
        XCTAssertEqual(photoCount(app), 9)
        openAdditionalCamera(app)
        tap(app, "camera.captureDetail")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 30))
        XCTAssertEqual(photoCount(app), 11)
        XCTAssertFalse(app.buttons["product-info.done"].isEnabled,
                       "Overflow must stay visible and disable completion, rather than truncate captures")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "product-edit-add-camera-overflow"; shot.lifetime = .keepAlways; add(shot)
        tap(app, "product-flow.back")
        tap(app, "product-info.discard-exit")
        let card = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        tap(app, "library.edit")
        XCTAssertEqual(photoCount(app), initialCount)
        XCTAssertTrue(app.buttons[removedID].exists, "Discard must restore the original photo selection")
    }

    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        return app
    }

    private func openAdditionalCamera(_ app: XCUIApplication) {
        tap(app, "product-info.add-photo")
        tap(app, "사진 촬영하기")
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 15))
    }

    private func photoCount(_ app: XCUIApplication) -> Int {
        let header = app.descendants(matching: .any)["product-info.photo-count"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        return header.label.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init).first ?? -1
    }

    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 25), identifier)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }
}
