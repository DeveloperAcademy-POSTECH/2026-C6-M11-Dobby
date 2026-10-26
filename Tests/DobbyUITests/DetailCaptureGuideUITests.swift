// Created by mason on 10/20/26.
import XCTest

/// 합성 촬영으로 안내 터치 차단과 같은 초안의 재진입 상태를 검증한다.
final class DetailCaptureGuideUITests: XCTestCase {
    @MainActor
    func testGuideDismissalDoesNotCaptureAndSameDraftDoesNotRepeatGuide() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let measure = app.buttons["captureGarment"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        measure.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        confirm.tap()
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        let capture = app.buttons["camera.captureDetail"]
        XCTAssertFalse(capture.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "detail-capture-start-guide"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // 화면 하단 셔터 위치를 눌러도 이 첫 터치는 안내에만 소비돼야 한다.
        guide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.915)).tap()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 5))
        let more = app.buttons["camera.moreOptions"]
        XCTAssertTrue(more.wait(for: \.isHittable, toEqual: true, timeout: 5))
        more.tap()
        let closeOptions = app.buttons["camera.closeOptions"]
        XCTAssertTrue(closeOptions.waitForExistence(timeout: 5))
        XCTAssertFalse(capture.exists)
        XCTAssertFalse(app.buttons["camera.openGallery"].exists)
        XCTAssertFalse(app.buttons["camera.exposureOption"].isEnabled)
        XCTAssertFalse(app.buttons["camera.aspectRatioOption"].isEnabled)
        XCTAssertTrue(app.buttons["camera.aspectRatioOption"].value as? String == "4:3, 조절 준비 중")
        let optionsShot = XCTAttachment(screenshot: app.screenshot())
        optionsShot.name = "detail-capture-options-menu"
        optionsShot.lifetime = .keepAlways
        add(optionsShot)
        closeOptions.tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))
        more.tap()
        app.buttons["camera.dismissOptions"].tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))
        // 메뉴를 열어 둔 채 이동해도 복귀 시 촬영 컨트롤을 다시 표시한다.
        more.tap()
        let next = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        next.tap()
        XCTAssertTrue(app.buttons["camera.thumbnail.0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.thumbnail.1"].exists)
        app.navigationBars["제품 사진 선택"].buttons.element(boundBy: 0).tap()
        XCTAssertFalse(closeOptions.exists)
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let back = app.buttons["product-flow.backToMeasurement"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertFalse(guide.exists)
        back.tap()
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        confirm.tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertFalse(guide.exists)
        capture.tap()
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        next.tap()
        XCTAssertTrue(app.buttons["camera.thumbnail.1"].waitForExistence(timeout: 10))
        // 새 실측 촬영으로 새 초안을 만들면 안내가 다시 필요하다.
        app.navigationBars["제품 사진 선택"].buttons.element(boundBy: 0).tap()
        back.tap()
        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 10))
        retake.tap()
        XCTAssertTrue(measure.waitForExistence(timeout: 10))
        armSyntheticGarmentCapture(in: app)
        measure.tap()
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        confirm.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
    }
}
