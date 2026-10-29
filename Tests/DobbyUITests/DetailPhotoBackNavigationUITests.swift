// Created by mason on 10/19/26.
import XCTest

/// Isolated synthetic fixtures verify navigation and draft retention, not camera accuracy.
final class DetailPhotoBackNavigationUITests: XCTestCase {
    @MainActor
    func testExitConfirmationRestoresTopAndBottomResultsAndOriginalEvidence() {
        for isTop in [true, false] {
            let app = launchResult(isTop: isTop)
            defer { app.terminate() }
            if isTop {
                let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
                let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
                let original = point.value as? String
                let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(
                    CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original ?? ""), object: point)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
            }
            let confirm = app.buttons["confirmGarmentMeasurement"]
            waitEnabled(confirm)
            let labels = measurementLabels(in: app)
            let points = measurementPoints(in: app)
            XCTAssertEqual(labels.count, 4)
            XCTAssertFalse(points.isEmpty)

            cancelExitAndStay(title: "실측 결과", app: app)
            XCTAssertEqual(measurementLabels(in: app), labels)
            XCTAssertEqual(measurementPoints(in: app), points)
            let productID = saveAndResumeDraft(stage: "실측 결과 단계", title: "실측 결과", app: app)
            waitEnabled(confirm)
            XCTAssertEqual(measurementLabels(in: app), labels)
            XCTAssertEqual(measurementPoints(in: app), points)
            confirm.tap()
            waitForDetails(in: app)

            let evidence = galleryEvidence(in: app, expectedPhotoCount: 2)
            cancelExitAndStay(title: "제품 상세 촬영", app: app)
            XCTAssertEqual(saveAndResumeDraft(stage: "상세 촬영 단계", title: "제품 상세 촬영", app: app), productID)
            waitForDetails(in: app, expectsGuide: false)
            XCTAssertEqual(galleryEvidence(in: app, expectedPhotoCount: 2), evidence)
            screenshot(app, name: isTop ? "top-result-and-evidence-after-resume" : "bottom-result-and-evidence-after-resume")
        }
    }

    @MainActor
    func testRepeatedResumeKeepsDetailPhotosSelectionAndRepresentative() {
        let app = launchResult(isTop: true)
        defer { app.terminate() }
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        waitForDetails(in: app)
        for _ in 0..<2 {
            let shutter = app.buttons["camera.captureDetail"]
            waitEnabled(shutter)
            shutter.tap()
            waitEnabled(shutter)
        }
        _ = galleryEvidence(in: app, expectedPhotoCount: 4)
        openSelection(in: app)
        XCTAssertEqual(selectionControls(in: app).count, 3)
        // Select the second detail as representative, the first detail second, measurement last.
        for index in [0, 2, 1, 0] {
            let photo = selectionControl(index, in: app)
            waitEnabled(photo)
            photo.tap()
        }
        assertSelection(in: app)
        cancelExitAndStay(title: "제품 사진 선택", app: app)
        assertSelection(in: app)

        var productID: String?
        for _ in 0..<2 {
            let restoredID = saveAndResumeDraft(stage: "제품 사진 선택 단계", title: "제품 사진 선택", app: app)
            if let productID { XCTAssertEqual(restoredID, productID) }
            productID = restoredID
            XCTAssertEqual(selectionControls(in: app).count, 3)
            assertSelection(in: app)
            let preview = app.buttons["camera.grid.preview.2"]
            waitEnabled(preview)
            preview.tap()
            XCTAssertTrue(app.descendants(matching: .any)["camera.selectionPreviewImage"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["camera.selectionPreviewToggle"].value as? String, "1번째 선택")
            screenshot(app, name: "selected-detail-representative-after-resume")
            app.buttons["camera.closeSelectionPreview"].tap()
            XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
            XCTAssertFalse(exitConfirmation(in: app).exists, "Preview Back only closes the auxiliary preview")
            assertSelection(in: app)
        }
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchResult(isTop: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        if isTop { app.launchArguments.append("--garment-preview-top") }
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let capture = app.buttons["captureGarment"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        capture.tap()
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        return app
    }

    @MainActor
    private func waitForDetails(in app: XCUIApplication, expectsGuide: Bool = true) {
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        let guide = app.buttons["camera.startDetailCapture"]
        if expectsGuide {
            XCTAssertTrue(guide.waitForExistence(timeout: 10))
            guide.tap()
            XCTAssertTrue(guide.waitForNonExistence(timeout: 5))
        } else {
            XCTAssertFalse(guide.exists)
        }
        waitEnabled(app.buttons["camera.captureDetail"])
    }

    @MainActor
    private func galleryEvidence(in app: XCUIApplication, expectedPhotoCount: Int) -> String {
        let gallery = app.buttons["camera.openGallery"]
        waitEnabled(gallery)
        gallery.tap()
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.galleryThumbnail."))
        XCTAssertEqual(photos.count, expectedPhotoCount)
        XCTAssertEqual(app.buttons["camera.galleryThumbnail.0"].label, "실측 원본 사진")
        XCTAssertEqual(app.buttons["camera.galleryThumbnail.1"].label, "실측값 표시 사진")
        for index in 0..<expectedPhotoCount {
            let photo = app.buttons["camera.galleryThumbnail.\(index)"]
            photo.tap()
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "value == %@", "\(index + 1) / \(expectedPhotoCount)"), object: pager)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
            XCTAssertTrue(photo.isSelected)
            if index >= 2 { XCTAssertTrue(photo.label.hasPrefix("상세 사진")) }
        }
        app.buttons["camera.galleryThumbnail.1"].tap()
        let annotationVisible = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == %@", "2 / \(expectedPhotoCount)"), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [annotationVisible], timeout: 5), .completed)
        let evidence = app.descendants(matching: .any)["camera.galleryMeasurement"].firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        let value = evidence.value as? String ?? ""
        XCTAssertTrue(value.contains("cm"))
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
        return value
    }

    @MainActor
    private func openSelection(in app: XCUIApplication) {
        let choose = app.buttons["camera.selectPhotos"]
        waitEnabled(choose)
        choose.tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertSelection(in app: XCUIApplication) {
        for (index, order) in [(2, 1), (1, 2), (0, 3)] {
            XCTAssertEqual(selectionControl(index, in: app).value as? String, "\(order)번째 선택")
        }
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "3장 선택 · 최소 1장 · 최대 10장")
        XCTAssertTrue(app.buttons["camera.completePhotos"].isEnabled)
    }

    @MainActor
    private func selectionControl(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let control = app.buttons["camera.grid.select.\(index)"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        return control
    }

    @MainActor
    private func selectionControls(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.grid.select."))
    }

    @MainActor
    private func cancelExitAndStay(title: String, app: XCUIApplication) {
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-cancel"].tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[title].isHittable)
        XCTAssertTrue(app.buttons["product-flow.back"].isHittable)
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
    private func exitConfirmation(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-flow.exit-confirmation"].firstMatch
    }

    @MainActor
    private func saveAndResumeDraft(stage: String, title: String, app: XCUIApplication) -> String {
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
        // Reopening the process proves persistence instead of retaining the live camera model.
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let draft = app.buttons["library.draft.\(productID)"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(draft.label.contains(stage))
        draft.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
        return productID
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    }

    @MainActor
    private func measurementLabels(in app: XCUIApplication) -> [String: String] {
        Dictionary(uniqueKeysWithValues: app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex.map { ($0.identifier, $0.label) })
    }

    @MainActor
    private func measurementPoints(in app: XCUIApplication) -> [String: String] {
        Dictionary(uniqueKeysWithValues: app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "garmentMeasurementPoint_")).allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") })
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
