// Created by mason on 10/7/26.
import XCTest

final class DetailPhotoDeletionRecoveryUITests: XCTestCase {
    @MainActor
    func testFailedDeletionRetriesAndLastDetailCanBeRecaptured() {
        let app = launchDetails(count: 1, failsOnce: true)
        defer { app.terminate() }
        let deletes = deleteButtons(in: app)
        let originalID = deletes.element(boundBy: 0).identifier
        let original = app.buttons[originalID]
        confirmDeletion(original, in: app)
        let failure = app.alerts["사진을 삭제하지 못했어요"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        failure.buttons["확인"].tap()
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(original.isHittable)
        confirmDeletion(original, in: app)
        XCTAssertTrue(original.waitForNonExistence(timeout: 5))
        XCTAssertEqual(deletes.count, 0)
        let shutter = app.buttons["camera.captureDetail"]
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        shutter.tap()
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNotEqual(deletes.element(boundBy: 0).identifier, originalID)
        app.buttons["camera.selectPhotos"].tap()
        let page = app.descendants(matching: .any)["camera.photoCarouselPage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.value as? String, "1 / 2")
    }

    @MainActor
    func testDeletingRepresentativeKeepsScrollPositionAndPromotesNextSelection() {
        let app = launchDetails(count: 8)
        defer { app.terminate() }
        let deletes = deleteButtons(in: app)
        let first = app.buttons[deletes.element(boundBy: 0).identifier]
        let second = app.buttons[deletes.element(boundBy: 1).identifier]
        let last = app.buttons[deletes.element(boundBy: 7).identifier]
        app.buttons["camera.selectPhotos"].tap()
        for index in [1, 2, 0] {
            let photo = app.buttons["camera.thumbnail.\(index)"]
            XCTAssertTrue(photo.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            photo.tap()
        }
        XCTAssertEqual(app.buttons["camera.thumbnail.1"].value as? String, "1번째 선택")
        app.navigationBars["제품 사진 선택"].buttons.element(boundBy: 0).tap()
        let strip = app.scrollViews["camera.detailPhotoStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        strip.swipeRight()
        strip.swipeRight()
        XCTAssertTrue(first.isHittable)
        XCTAssertFalse(strip.frame.intersects(last.frame))
        confirmDeletion(first, in: app)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertEqual(deletes.count, 7)
        XCTAssertTrue(second.isHittable)
        XCTAssertFalse(strip.frame.intersects(last.frame), "삭제가 목록 끝으로 강제 이동시키면 안 됨")
        app.buttons["camera.selectPhotos"].tap()
        let next = app.buttons["camera.thumbnail.1"] // 삭제 후 촬영 인덱스도 당겨진다.
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.value as? String, "1번째 선택")
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "1장 선택 · 최소 1장")
        app.scrollViews["camera.photoCarousel"].swipeLeft()
        let representative = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND value == %@", "상세 사진", "대표 사진")).firstMatch
        XCTAssertTrue(representative.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchDetails(count: Int, failsOnce: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        if failsOnce { app.launchArguments.append("--detail-delete-failure-once") }
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
        for _ in 0..<count {
            XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            shutter.tap()
        }
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        XCTAssertEqual(deleteButtons(in: app).count, count)
        return app
    }

    @MainActor
    private func deleteButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.deletePhoto."))
    }

    @MainActor
    private func confirmDeletion(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        button.tap()
        let confirmation = app.alerts["상세 사진을 삭제할까요?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["삭제"].tap()
    }
}
