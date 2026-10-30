// Created by mason on 10/25/26.
import XCTest

final class ProductPhotoSelectionGridTests: XCTestCase {
    @MainActor
    func testGridLimitFeedbackAndCompletion() {
        let app = openSelection(detailCount: 11)
        let grid = app.scrollViews["camera.selectionGrid"]
        let first = app.buttons["camera.grid.preview.0"]
        let second = app.buttons["camera.grid.preview.1"]
        let third = app.buttons["camera.grid.preview.2"]
        let fourth = app.buttons["camera.grid.preview.3"]
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertLessThan(second.frame.minX, third.frame.minX)
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(fourth.frame.minY, first.frame.maxY)
        XCTAssertTrue(grid.isHittable)
        XCTAssertTrue(app.switches["product-ai.toggle"].exists)
        XCTAssertEqual(app.switches["product-ai.toggle"].value as? String, "1")
        tap(app, "camera.grid.select.0")
        XCTAssertFalse(app.buttons["camera.completePhotos"].isEnabled)
        for index in 1...10 { tap(app, "camera.grid.select.\(index)") }
        XCTAssertFalse(app.buttons["camera.closeSelectionPreview"].exists, "선택 버튼은 확대 화면을 열지 않는다")
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "10장 선택 · 최소 1장 · 최대 10장")
        XCTAssertTrue(app.buttons["camera.completePhotos"].isEnabled)
        let notice = app.staticTexts["camera.selectionLimitNotice"]
        for _ in 0..<2 {
            tap(app, "camera.grid.select.11")
            XCTAssertEqual(value(app, 11), "선택 안 됨")
            XCTAssertTrue(notice.waitForExistence(timeout: 2))
            XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        }
        tap(app, "camera.grid.select.1")
        XCTAssertEqual(value(app, 2), "1번째 선택")
        tap(app, "camera.grid.select.11")
        XCTAssertEqual(value(app, 11), "10번째 선택")
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "selection-grid-ten-selected"
        shot.lifetime = .keepAlways
        add(shot)
        disableProductAutofillIfPresent(in: app)
        tap(app, "camera.completePhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPreviewSharesSelectionAndRestoresScrolledGrid() {
        let app = openSelection(detailCount: 17)
        tap(app, "camera.grid.preview.0")
        XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "1번째 선택")
        XCTAssertTrue(app.buttons["camera.completePhotos"].wait(for: \.isHittable, toEqual: false, timeout: 5))
        tap(app, "camera.selectionPreviewToggle")
        tap(app, "camera.closeSelectionPreview")
        XCTAssertEqual(value(app, 0), "선택 안 됨")
        XCTAssertFalse(app.buttons["camera.completePhotos"].isEnabled)
        for index in 1...10 { tap(app, "camera.grid.select.\(index)") }
        tap(app, "camera.grid.preview.11")
        XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "선택 안 됨")
        tap(app, "camera.selectionPreviewToggle")
        XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "선택 안 됨")
        XCTAssertTrue(app.staticTexts["camera.selectionLimitNotice"].waitForExistence(timeout: 2))
        tap(app, "camera.closeSelectionPreview")
        XCTAssertFalse(app.staticTexts["camera.selectionLimitNotice"].exists)
        tap(app, "camera.grid.select.1")
        tap(app, "camera.grid.preview.11")
        tap(app, "camera.selectionPreviewToggle")
        XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "10번째 선택")
        tap(app, "camera.closeSelectionPreview")
        XCTAssertEqual(value(app, 11), "10번째 선택")
        XCTAssertEqual(value(app, 2), "1번째 선택")
        let grid = app.scrollViews["camera.selectionGrid"]
        grid.swipeUp()
        let last = app.buttons["camera.grid.preview.17"]
        XCTAssertTrue(last.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let previousY = last.frame.minY
        tap(app, "camera.grid.preview.17")
        XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "선택 안 됨")
        tap(app, "camera.closeSelectionPreview")
        XCTAssertTrue(last.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(last.frame.minY, previousY, accuracy: 2)
    }

    @MainActor
    private func openSelection(detailCount: Int) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        tap(app, "product-flow.start")
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        let guide = app.buttons["camera.startDetailCapture"]
        if guide.waitForExistence(timeout: 5) { guide.tap() }
        for _ in 0..<detailCount { tap(app, "camera.captureDetail") }
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 20), id)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), id)
        button.tap()
    }

    @MainActor
    private func value(_ app: XCUIApplication, _ index: Int) -> String? {
        app.buttons["camera.grid.select.\(index)"].value as? String
    }
}
