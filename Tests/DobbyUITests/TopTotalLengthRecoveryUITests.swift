import XCTest

/// Explicitly labelled synthetic frame. Verifies correction UI and product
/// handoff without exercising camera recognition or physical cm accuracy.
final class TopTotalLengthRecoveryUITests: XCTestCase {
    @MainActor
    func testMissingTotalLengthCanBeCorrectedWithoutRetakingAndReachesProduct() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top", "--garment-preview-missing-top-length"]
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        armSyntheticGarmentCapture(in: app)
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementLabel_top.totalLength"].exists)
        let pendingPoint = app.buttons["garmentMeasurementPoint_neck_center"]
        XCTAssertTrue(pendingPoint.exists, "An unavailable total-length point must still have an editable handle")
        XCTAssertTrue((pendingPoint.value as? String)?.contains("위치 확인 필요") == true)
        let pendingScreenshot = XCTAttachment(screenshot: app.screenshot())
        pendingScreenshot.name = "top-total-length-unavailable-visible-handle"
        pendingScreenshot.lifetime = .keepAlways
        add(pendingScreenshot)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 3)

        let notice = app.buttons["garmentUnavailableNotice"]
        XCTAssertFalse(notice.exists, "A visible pending point must not be covered by a failure banner")
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let dragStart = pendingPoint.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(
            CGVector(dx: photo.frame.width * 0.01, dy: photo.frame.height * 0.02)))
        let length = app.descendants(matching: .any)["garmentMeasurementLabel_top.totalLength"]
        XCTAssertTrue(length.waitForExistence(timeout: 10))
        XCTAssertFalse(notice.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 4)
        let labelParts = length.label.components(separatedBy: ", ")
        let centimeters = try XCTUnwrap(labelParts.dropFirst().first).replacingOccurrences(of: " cm", with: "")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "top-total-length-restored-current-result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.buttons["garmentResultActions"].exists)
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        wait(for: [enabled], timeout: 10)
        confirm.tap()
        let detailGuide = app.buttons["camera.startDetailCapture"]
        if detailGuide.waitForExistence(timeout: 2) { detailGuide.tap() }
        let selectPhotos = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(selectPhotos.waitForExistence(timeout: 15))
        XCTAssertTrue(selectPhotos.wait(for: \.isHittable, toEqual: true, timeout: 5))
        selectPhotos.tap()
        let completePhotos = app.buttons["camera.completePhotos"]
        XCTAssertTrue(completePhotos.waitForExistence(timeout: 10))
        disableProductAutofillIfPresent(in: app)
        completePhotos.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        let storedLength = app.textFields["product-info.measurement.totalLength"]
        for _ in 0..<6 where !storedLength.isHittable { app.swipeUp() }
        XCTAssertTrue(storedLength.exists)
        XCTAssertEqual(storedLength.value as? String, centimeters,
                       "The confirmed corrected total length must reach the current product draft")
        app.terminate()
    }
}
