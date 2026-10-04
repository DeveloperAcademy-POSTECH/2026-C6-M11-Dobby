// Created by mason on 10/4/26.
import XCTest

final class ProductPhotoCarouselTests: XCTestCase {
    @MainActor
    func testBrowsingDoesNotChangeSelection() {
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
        for _ in 0..<2 {
            XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            shutter.tap()
        }
        let choose = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        choose.tap()
        let page = app.descendants(matching: .any)["camera.photoCarouselPage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertEqual(page.value as? String, "1 / 3")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "photo-carousel-first-page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let carousel = app.scrollViews["camera.photoCarousel"]
        carousel.swipeLeft()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "2 / 3"), object: page)], timeout: 5), .completed)
        carousel.swipeLeft()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "3 / 3"), object: page)], timeout: 5), .completed)
        carousel.swipeRight()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "2 / 3"), object: page)], timeout: 5), .completed)
        carousel.swipeRight()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1 / 3"), object: page)], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["camera.selectedPhotoCount"].label.contains("1장 선택"))
    }
}
