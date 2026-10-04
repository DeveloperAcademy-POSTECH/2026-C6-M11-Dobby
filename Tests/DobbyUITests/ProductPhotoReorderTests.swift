// Created by mason on 10/4/26.
import XCTest

final class ProductPhotoReorderTests: XCTestCase {
    @MainActor
    func testLongPressReordersAcrossBothEdgesWithoutChangingCaptureOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let capture = app.buttons["captureGarment"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        capture.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        let shutter = app.buttons["camera.captureDetail"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        for _ in 0..<7 {
            XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            shutter.tap()
        }
        let choose = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        choose.tap()
        let strip = app.scrollViews["camera.selectionStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        for index in 1...6 {
            let photo = app.buttons["camera.thumbnail.\(index)"]
            if !photo.isHittable { strip.swipeLeft() }
            XCTAssertTrue(photo.wait(for: \.isHittable, toEqual: true, timeout: 5))
            photo.tap()
        }
        let first = app.buttons["camera.thumbnail.0"]
        let last = app.buttons["camera.thumbnail.6"]
        let unselected = app.buttons["camera.thumbnail.7"]
        XCTAssertEqual(last.value as? String, "7번째 선택")
        last.press(forDuration: 0.6)
        XCTAssertEqual(last.value as? String, "7번째 선택", "길게 누르기만 하면 선택을 해제하지 않는다")
        let left = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        let right = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertEqual(last.value as? String, "1번째 선택")
        XCTAssertEqual(first.value as? String, "2번째 선택")
        XCTAssertLessThan(last.frame.minX, first.frame.minX)
        let page = app.descendants(matching: .any)["camera.photoCarouselPage"].firstMatch
        XCTAssertEqual(page.value as? String, "1 / 8")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "reordered-last-photo-as-representative"
        shot.lifetime = .keepAlways
        add(shot)
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertEqual(last.value as? String, "7번째 선택")
        XCTAssertEqual(first.value as? String, "1번째 선택")
        strip.swipeLeft()
        XCTAssertTrue(unselected.wait(for: \.isHittable, toEqual: true, timeout: 5))
        unselected.press(forDuration: 0.6, thenDragTo: last)
        XCTAssertEqual(unselected.value as? String, "선택 안 됨")
        XCTAssertEqual(last.value as? String, "7번째 선택")
        // 손을 놓은 뒤 일반 탭과 스크롤을 다시 사용할 수 있다.
        last.tap()
        XCTAssertEqual(last.value as? String, "선택 안 됨")
        last.tap()
        XCTAssertEqual(last.value as? String, "7번째 선택")
        let outside = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: -1))
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(last.value as? String, "7번째 선택")
        last.tap()
        XCTAssertEqual(last.value as? String, "선택 안 됨", "영역 밖에서 손을 놓아도 드래그 상태가 남지 않는다")
        last.tap()
        XCTAssertEqual(last.value as? String, "7번째 선택")
        XCTAssertEqual(page.value as? String, "1 / 8")
    }
}
