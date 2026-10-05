// Created by mason on 10/4/26.
import XCTest

final class ProductPhotoSelectionStripTests: XCTestCase {
    @MainActor
    func testOverflowSelectionReordersOnlyTheStrip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
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
        for _ in 0..<6 {
            XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            shutter.tap()
        }
        let choose = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        choose.tap()
        let strip = app.scrollViews["camera.selectionStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        let first = app.buttons["camera.thumbnail.0"]
        let second = app.buttons["camera.thumbnail.2"]
        let last = app.buttons["camera.thumbnail.6"]
        XCTAssertTrue(first.isHittable)
        strip.swipeLeft()
        XCTAssertTrue(last.wait(for: \.isHittable, toEqual: true, timeout: 5))
        last.tap()
        strip.swipeRight()
        XCTAssertTrue(second.wait(for: \.isHittable, toEqual: true, timeout: 5))
        second.tap()
        XCTAssertEqual(last.value as? String, "2번째 선택")
        XCTAssertEqual(second.value as? String, "3번째 선택")
        first.tap()
        XCTAssertEqual(last.value as? String, "1번째 선택")
        XCTAssertEqual(second.value as? String, "2번째 선택")
        XCTAssertLessThan(last.frame.minX, second.frame.minX)
        XCTAssertLessThan(second.frame.minX, first.frame.minX)
        let page = app.descendants(matching: .any)["camera.photoCarouselPage"].firstMatch
        XCTAssertEqual(page.value as? String, "1 / 7")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "selection-strip-selected-left-unselected-right"
        shot.lifetime = .keepAlways
        add(shot)
        last.tap()
        second.tap()
        XCTAssertFalse(app.buttons["camera.completePhotos"].isEnabled)
        first.tap()
        XCTAssertEqual(first.value as? String, "1번째 선택")
        XCTAssertTrue(app.buttons["camera.completePhotos"].isEnabled)
    }
}
