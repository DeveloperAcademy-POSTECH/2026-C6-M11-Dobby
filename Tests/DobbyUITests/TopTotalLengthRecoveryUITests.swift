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
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_top.totalLength"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 3)

        let notice = app.buttons["garmentUnavailableNotice"]
        notice.tap()
        XCTAssertTrue(app.navigationBars["총장 위치 지정"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["applyTotalLengthCorrection"].isEnabled)
        let photo = app.otherElements["totalLengthCorrectionPhoto"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(photo.frame.width, 200, "Tap coordinates must refer to the entire photo, not an inherited point label")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24)).tap()
        XCTAssertEqual(app.buttons["totalLengthCorrectionEndpoint_0"].value as? String, "위치 확인 완료")
        XCTAssertFalse(app.buttons["applyTotalLengthCorrection"].isEnabled)
        app.buttons["cancelTotalLengthCorrection"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_top.totalLength"].exists,
                       "Cancel must discard the draft's partial manual edit")

        notice.tap()
        XCTAssertTrue(app.navigationBars["총장 위치 지정"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["totalLengthCorrectionEndpoint_0"].value as? String, "위치 확인 필요")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24)).tap()
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
        XCTAssertEqual(app.buttons["totalLengthCorrectionEndpoint_1"].value as? String, "위치 확인 완료")
        let apply = app.buttons["applyTotalLengthCorrection"]
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        let length = app.buttons["garmentMeasurementLabel_top.totalLength"]
        XCTAssertTrue(length.waitForExistence(timeout: 10))
        XCTAssertFalse(notice.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 4)
        let labelParts = length.label.components(separatedBy: ", ")
        let centimeters = try XCTUnwrap(labelParts.dropFirst().first).replacingOccurrences(of: " cm", with: "")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "top-total-length-restored-current-result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // The same correction is reachable from nested measurement details.
        // Previously corrected points still require confirmation in a new draft.
        app.buttons["garmentResultActions"].tap()
        app.buttons["openGarmentMeasurementDetails"].tap()
        let reviewMenu = app.buttons["reviewAllGarmentMeasurementPoints"]
        XCTAssertTrue(reviewMenu.waitForExistence(timeout: 5))
        reviewMenu.tap()
        app.buttons["reviewGarmentItem_top.totalLength"].tap()
        XCTAssertTrue(app.navigationBars["총장 위치 지정"].waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24)).tap()
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        let closeDetails = app.buttons["closeGarmentMeasurementDetails"]
        XCTAssertTrue(closeDetails.waitForExistence(timeout: 5))
        closeDetails.tap()
        XCTAssertTrue(length.waitForExistence(timeout: 5))
        XCTAssertEqual(length.label.components(separatedBy: ", ").dropFirst().first,
                       centimeters + " cm")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        wait(for: [enabled], timeout: 10)
        confirm.tap()
        let selectPhotos = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(selectPhotos.waitForExistence(timeout: 15))
        selectPhotos.tap()
        let completePhotos = app.buttons["camera.completePhotos"]
        XCTAssertTrue(completePhotos.waitForExistence(timeout: 10))
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
