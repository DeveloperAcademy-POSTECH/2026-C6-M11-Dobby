// Created by mason on 10/25/26.
import XCTest

final class ProductPhotoSelectionGridTests: XCTestCase {
    @MainActor
    func testBackKeepsPhotosAndSelectionOrderWhileAddingAnotherCapture() {
        let app = openSelection(detailCount: 2)
        defer { app.terminate() }
        tap(app, "camera.grid.select.0")
        for index in [2, 0, 1] { tap(app, "camera.grid.select.\(index)") }
        let originalOrder = (0..<3).map { value(app, $0) }
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["product-flow.exit-title"].exists)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists, "촬영 가이드를 다시 요구하지 않는다")
        tap(app, "camera.openGallery")
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        XCTAssertEqual(pager.value as? String, "4 / 4", "실측 원본·표시본과 상세 2장 유지")
        tap(app, "촬영으로 돌아가기")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertEqual((0..<3).map { value(app, $0) }, originalOrder)
        XCTAssertEqual(value(app, 3), "선택 안 됨")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "camera.grid.select.")).count, 4)
        tap(app, "camera.grid.preview.2")
        XCTAssertTrue(app.buttons["camera.selectionPreviewToggle"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertFalse(app.staticTexts["사진을 불러올 수 없어요."].exists)
    }

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
        XCTAssertFalse(app.staticTexts["AI로 제품 정보 입력하기"].exists)
        XCTAssertEqual(app.switches.count, 0)
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
        tap(app, "camera.completePhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPreviewSharesSelectionAndRestoresScrolledGrid() {
        let app = openSelection(detailCount: 17)
        tap(app, "camera.grid.preview.0")
        assertPreviewLayout(app)
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

    @MainActor
    private func assertPreviewLayout(_ app: XCUIApplication) {
        let image = app.descendants(matching: .any)["camera.selectionPreviewImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let bounds = app.windows.firstMatch.frame
        let toggle = app.buttons["camera.selectionPreviewToggle"]
        let back = app.buttons["camera.closeSelectionPreview"]
        let photoTop = bounds.minY + 146 * bounds.width / 402
        // 합성 사진은 4:5이므로 3:4 표시 영역 안에서 원본 비율대로 여백이 생긴다.
        XCTAssertGreaterThanOrEqual(image.frame.minY, photoTop - 2)
        XCTAssertLessThanOrEqual(image.frame.maxY, photoTop + bounds.width * 4 / 3 + 2)
        XCTAssertEqual(image.frame.midX, bounds.midX, accuracy: 2)
        XCTAssertEqual(image.frame.width / image.frame.height, 4 / 5, accuracy: 0.01)
        XCTAssertEqual(toggle.frame.width, 45, accuracy: 1)
        XCTAssertEqual(toggle.frame.height, 45, accuracy: 1)
        XCTAssertEqual(toggle.frame.minY - image.frame.minY, 8, accuracy: 1)
        XCTAssertEqual(image.frame.maxX - toggle.frame.maxX, 8, accuracy: 1)
        XCTAssertTrue(back.isHittable)
        XCTAssertLessThan(back.frame.maxY, image.frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "selection-preview-figma-layout"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
