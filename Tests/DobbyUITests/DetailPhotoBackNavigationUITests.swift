// Created by mason on 10/19/26.
import XCTest

/// Isolated synthetic fixtures verify navigation and draft retention, not camera accuracy.
final class DetailPhotoBackNavigationUITests: XCTestCase {
    @MainActor
    func testDetailBackReturnsToTopAndBottomResultsWithoutExitConfirmation() {
        for isTop in [true, false] {
            let app = launchResult(isTop: isTop)
            defer { app.terminate() }
            if isTop { moveShoulderPoint(in: app) }
            let confirm = app.buttons["confirmGarmentMeasurement"]
            waitEnabled(confirm)
            let labels = measurementLabels(in: app)
            let points = measurementPoints(in: app)
            XCTAssertEqual(labels.count, 4)
            XCTAssertFalse(points.isEmpty)

            let productID = saveAndResumeDraft(app: app)
            waitEnabled(confirm)
            XCTAssertEqual(measurementLabels(in: app), labels)
            XCTAssertEqual(measurementPoints(in: app), points)
            confirm.tap()
            waitForDetails(in: app, expectsGuide: false)

            let evidence = galleryEvidence(in: app, expectedPhotoCount: 2)
            returnToMeasurementResult(in: app)
            XCTAssertEqual(measurementLabels(in: app), labels)
            XCTAssertEqual(measurementPoints(in: app), points)
            XCTAssertEqual(saveAndResumeDraft(app: app), productID)
            waitEnabled(confirm)
            confirm.tap()
            waitForDetails(in: app, expectsGuide: false)
            XCTAssertEqual(galleryEvidence(in: app, expectedPhotoCount: 2), evidence)
            screenshot(app, name: isTop ? "top-result-and-evidence-after-resume" : "bottom-result-and-evidence-after-resume")
        }
    }

    @MainActor
    func testRepeatedResumeAndRetakeKeepDetailPhotosSelectionAndRepresentative() {
        let app = launchResult(isTop: true)
        defer { app.terminate() }
        moveShoulderPoint(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        waitForDetails(in: app)
        for _ in 0..<2 {
            let shutter = app.buttons["camera.captureDetail"]
            waitEnabled(shutter)
            shutter.tap()
            waitEnabled(shutter)
        }
        let oldEvidence = galleryEvidence(in: app, expectedPhotoCount: 4)
        openSelection(in: app)
        XCTAssertEqual(selectionControls(in: app).count, 4)
        // Retain a detail representative, selected measurement visualization and original.
        for index in [0, 3, 1, 0] {
            let photo = selectionControl(index, in: app)
            waitEnabled(photo)
            photo.tap()
        }
        assertSelection(in: app)
        returnToDetails(in: app)
        openSelection(in: app)
        assertSelection(in: app)

        var productID: String?
        for _ in 0..<2 {
            returnToDetails(in: app)
            returnToMeasurementResult(in: app)
            let restoredID = saveAndResumeDraft(app: app)
            retakeFromResult(in: app)
            let confirm = app.buttons["confirmGarmentMeasurement"]
            waitEnabled(confirm)
            confirm.tap()
            waitForDetails(in: app, expectsGuide: false)
            XCTAssertNotEqual(galleryEvidence(in: app, expectedPhotoCount: 4), oldEvidence,
                              "Retake must publish new measurements, not reuse the restored corrected record")
            openSelection(in: app)
            if let productID { XCTAssertEqual(restoredID, productID) }
            productID = restoredID
            XCTAssertEqual(selectionControls(in: app).count, 4)
            assertSelection(in: app)
            let preview = app.buttons["camera.grid.preview.3"]
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
        disableProductAutofillIfPresent(in: app)
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
    private func returnToDetails(in app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        waitForDetails(in: app, expectsGuide: false)
        XCTAssertFalse(exitConfirmation(in: app).exists)
    }

    @MainActor
    private func returnToMeasurementResult(in app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        XCTAssertTrue(app.navigationBars["실측 결과"].isHittable)
        XCTAssertFalse(exitConfirmation(in: app).exists)
        XCTAssertFalse(app.buttons["product-flow.start"].isHittable)
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
        for (index, order) in [(3, 1), (1, 2), (0, 3)] {
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
    func testFreshResultBackReturnsToCameraWithoutAlertAndCanCaptureAgain() {
        let app = launchResult(isTop: true)
        defer { app.terminate() }
        retakeFromResult(in: app)
        app.buttons["confirmGarmentMeasurement"].tap()
        waitForDetails(in: app)
        _ = galleryEvidence(in: app, expectedPhotoCount: 2)
    }

    @MainActor
    private func retakeFromResult(in app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
        XCTAssertFalse(app.buttons["product-flow.start"].isHittable)
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
    }

    @MainActor
    private func exitConfirmation(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-flow.exit-confirmation"].firstMatch
    }

    @MainActor
    private func saveAndResumeDraft(app: XCUIApplication) -> String {
        // Confirmation persists the current evidence and photo snapshot. Back
        // only navigates; no result-screen exit dialog is involved.
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        let guide = app.buttons["camera.startDetailCapture"]
        if guide.waitForExistence(timeout: 2) {
            guide.tap()
            returnToMeasurementResult(in: app)
            app.buttons["confirmGarmentMeasurement"].tap()
            waitForDetails(in: app, expectsGuide: false)
        }
        returnToMeasurementResult(in: app)
        app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)?.tap()
        XCTAssertTrue(app.buttons["closeGarmentCapture"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
        app.buttons["closeGarmentCapture"].tap()
        XCTAssertTrue(app.tabBars.buttons["홈"].waitForExistence(timeout: 10))
        app.tabBars.buttons["홈"].tap()
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
        XCTAssertTrue(drafts.firstMatch.label.contains("상세 촬영 단계"))
        // Reopening the process proves persistence instead of retaining the live camera model.
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let draft = app.buttons["library.draft.\(productID)"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(draft.label.contains("상세 촬영 단계"))
        draft.tap()
        waitForDetails(in: app, expectsGuide: false)
        returnToMeasurementResult(in: app)
        return productID
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    }

    @MainActor
    private func moveShoulderPoint(in app: XCUIApplication) {
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        let original = point.value as? String
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original ?? ""), object: point)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
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
