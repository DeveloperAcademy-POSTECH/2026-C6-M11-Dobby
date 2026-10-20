// Created by mason on 10/20/26.
import XCTest

final class DetailPhotoGalleryUITests: XCTestCase {
    @MainActor
    func testBrowsingDeletionRecoveryAndReturnToCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top", "--detail-delete-failure-once"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20)); start.tap()
        let measure = app.buttons["captureGarment"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15)); measure.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20)); confirm.tap()
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10)); guide.tap()
        let capture = app.buttons["camera.captureDetail"]
        for _ in 0..<2 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        XCTAssertEqual(pager.value as? String, "3 / 3")
        pager.swipeRight()
        assertPage(pager, "2 / 3")
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertPage(pager, "1 / 3")
        XCTAssertFalse(app.buttons["camera.galleryDelete.0"].exists)
        app.buttons["camera.galleryThumbnail.1"].tap()
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(app.buttons["camera.galleryThumbnail.1"].frame.midX - app.frame.midX) < 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-photo-gallery"; shot.lifetime = .keepAlways; add(shot)
        let delete = app.buttons["camera.galleryDelete.1"]
        delete.tap()
        app.alerts["상세 사진을 삭제할까요?"].buttons["취소"].tap()
        XCTAssertEqual(pager.value as? String, "2 / 3")
        delete.tap()
        app.alerts["상세 사진을 삭제할까요?"].buttons["삭제"].tap()
        let error = app.alerts["사진을 삭제하지 못했어요"]
        XCTAssertTrue(error.waitForExistence(timeout: 5)); error.buttons["확인"].tap()
        XCTAssertEqual(pager.value as? String, "2 / 3")
        for expected in ["2 / 2", "1 / 1"] {
            delete.tap()
            app.alerts["상세 사진을 삭제할까요?"].buttons["삭제"].tap()
            assertPage(pager, expected)
        }
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertFalse(guide.exists)
        capture.tap()
        let next = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        XCTAssertTrue(app.buttons["camera.thumbnail.1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "1장 선택 · 최소 1장")
    }
    @MainActor
    private func assertPage(_ pager: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
