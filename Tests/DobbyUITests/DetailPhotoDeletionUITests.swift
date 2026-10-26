// Created by mason on 10/6/26.
import XCTest

final class DetailPhotoDeletionUITests: XCTestCase {
    @MainActor
    func testCornerDeleteButtonCancelsAndDeletesOnlyDetailPhoto() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let capture = app.buttons["captureGarment"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        capture.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        let shutter = app.buttons["camera.captureDetail"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.deletePhoto."))
        XCTAssertEqual(deletes.count, 0)
        for _ in 0..<2 {
            XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            shutter.tap()
        }
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        XCTAssertEqual(deletes.count, 2)
        let delete = app.buttons[deletes.element(boundBy: 0).identifier]
        let photoID = delete.identifier.replacingOccurrences(of: "camera.deletePhoto.", with: "camera.detailPhoto.")
        let photo = app.descendants(matching: .any)[photoID].firstMatch
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "detail-photos-corner-delete-controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(delete.frame.midX, photo.frame.maxX, accuracy: 1)
        XCTAssertEqual(delete.frame.midY, photo.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(delete.frame.width, 44)
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        let alert = app.alerts["상세 사진을 삭제할까요?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["취소"].tap()
        XCTAssertEqual(deletes.count, 2)
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["삭제"].tap()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5))
        XCTAssertEqual(deletes.count, 1)
        let choose = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        choose.tap()
        let page = app.descendants(matching: .any)["camera.photoCarouselPage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.value as? String, "1 / 2")
    }
}
