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
        openNewDetailDraft(in: app)
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        let capture = app.buttons["camera.captureDetail"]
        XCTAssertFalse(capture.isHittable)
        attachScreenshot(app, name: "detail-capture-start-guide")
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
        XCTAssertEqual(app.buttons["camera.aspectRatioOption"].value as? String, "4:3",
                       "The shared panel reports its selected ratio even when the separate availability gate disables editing")
        attachScreenshot(app, name: "detail-capture-options-menu")
        closeOptions.tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))
        more.tap()
        app.buttons["camera.dismissOptions"].tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))

        // 옵션을 열어 둔 채 뒤로가기를 취소해도 같은 촬영 초안과 컨트롤을 유지한다.
        more.tap()
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-cancel"].tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(closeOptions.exists)
        XCTAssertFalse(guide.exists)
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let productID = saveDraftViaHome(stage: "상세 촬영 단계", app: app)

        // 프로세스를 다시 열어도 안내 확인 여부는 같은 저장 초안에 남는다.
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let draft = app.buttons["library.draft.\(productID)"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertTrue(draft.label.contains("상세 촬영 단계"))
        draft.tap()
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        XCTAssertFalse(guide.exists)
        XCTAssertFalse(closeOptions.exists)
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        capture.tap()
        let next = app.buttons["camera.selectPhotos"]
        waitEnabled(next)
        next.tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        let selections = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.grid.select."))
        XCTAssertEqual(selections.count, 2, "안내 닫기는 촬영하지 않고 이후 셔터 한 번만 상세 사진을 추가해야 한다")
        XCTAssertTrue(app.buttons["camera.grid.select.0"].exists)
        XCTAssertTrue(app.buttons["camera.grid.select.1"].exists)
        XCTAssertFalse(app.buttons["camera.grid.select.2"].exists)

        // 확대 사진의 보조 뒤로가기는 임시저장 확인창을 열지 않는다.
        let preview = app.buttons["camera.grid.preview.1"]
        waitEnabled(preview)
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera.selectionPreviewImage"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["camera.closeSelectionPreview"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
        returnToDetails(in: app)
        XCTAssertFalse(guide.exists)
        next.tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertEqual(selections.count, 2)
        returnToDetails(in: app)
        XCTAssertEqual(saveDraftViaHome(stage: "상세 촬영 단계", app: app), productID)

        // 새 실측 촬영으로 새 초안을 만들면 안내가 다시 필요하다.
        app.tabBars.buttons["홈"].tap()
        openNewDetailDraft(in: app)
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertFalse(capture.isHittable)
    }

    @MainActor
    private func returnToDetails(in app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
    }

    @MainActor
    private func openNewDetailDraft(in app: XCUIApplication) {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let measure = app.buttons["captureGarment"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        measure.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        waitEnabled(confirm)
        confirm.tap()
    }

    @MainActor
    private func presentExitConfirmation(in app: XCUIApplication) {
        let query = app.buttons.matching(identifier: "product-flow.back")
        let backs = query.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(backs.count, 1)
        let back = backs.first ?? query.firstMatch
        waitEnabled(back)
        back.tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["product-flow.exit-cancel"].isEnabled)
        XCTAssertTrue(app.buttons["product-flow.exit-save"].isEnabled)
    }

    @MainActor
    private func saveDraftViaHome(stage: String, app: XCUIApplication) -> String {
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-save"].tap()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.wait(for: \.isHittable, toEqual: true, timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected)
        XCTAssertFalse(exitConfirmation(in: app).exists)
        app.tabBars.buttons["보관함"].tap()
        let drafts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.draft."))
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(drafts.count, 1)
        let productID = String(drafts.firstMatch.identifier.dropFirst("library.draft.".count))
        XCTAssertNotNil(UUID(uuidString: productID))
        XCTAssertTrue(drafts.firstMatch.label.contains(stage))
        return productID
    }

    @MainActor
    private func exitConfirmation(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-flow.exit-confirmation"].firstMatch
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 20))
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 20))
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
