import XCTest

/// Exercises only labelled synthetic captures in private per-test stores.
/// Relaunches prove that a new flow restores saved state rather than live view state.
@MainActor
final class ProductDraftResumeTests: XCTestCase {
    func testMeasurementAndDetailDraftsResumeCorrectedEvidenceAndOriginalPhotos() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)

        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let initialPoint = try XCTUnwrap(point.value as? String)
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        wait(for: NSPredicate(format: "value != %@", initialPoint), on: point)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        let correctedPoint = try XCTUnwrap(point.value as? String)
        let productID = exitToLibrary(stage: "실측 결과 단계", app: app)
        attachScreenshot(app, name: "draft-library-measurement-result")

        relaunchAndResume(productID: productID, stage: "실측 결과 단계", app: app)
        assertResumedStage("실측 결과", app: app)
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertEqual(point.value as? String, correctedPoint)
        XCTAssertFalse(app.buttons["camera.captureDetail"].exists)
        attachScreenshot(app, name: "draft-restored-corrected-measurement-result")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        waitEnabled(confirm)
        confirm.tap()
        captureTwoDetails(in: app)
        let originalPhotoIDs = detailPhotoIdentifiers(in: app)
        XCTAssertEqual(originalPhotoIDs.count, 3, "The measurement and both captured originals must be present")
        XCTAssertEqual(exitToLibrary(stage: "상세 촬영 단계", app: app), productID)
        attachScreenshot(app, name: "draft-library-details")

        relaunchAndResume(productID: productID, stage: "상세 촬영 단계", app: app)
        assertResumedStage("제품 상세 촬영", app: app)
        XCTAssertTrue(app.buttons["camera.captureDetail"].isHittable)
        XCTAssertEqual(detailPhotoIdentifiers(in: app), originalPhotoIDs)
        XCTAssertFalse(app.buttons["camera.completePhotos"].exists)
        attachScreenshot(app, name: "draft-restored-detail-originals")
    }

    func testSelectionAndInformationDraftsRestoreExactlyAndCompleteTheSameProduct() {
        continueAfterFailure = false
        let app = fixtureApp()
        let suffix = String(UUID().uuidString.prefix(8))
        let name = "Draft product " + suffix
        let brand = "Draft brand " + suffix
        let description = "Unfinished description " + suffix
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)
        let confirm = app.buttons["confirmGarmentMeasurement"]
        waitEnabled(confirm)
        confirm.tap()
        captureTwoDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))

        let completePhotos = app.buttons["camera.completePhotos"]
        thumbnail(0, in: app).tap()
        XCTAssertEqual(completePhotos.value as? String, "0장 선택 · 최소 1장")
        XCTAssertFalse(completePhotos.isEnabled)
        let productID = exitToLibrary(stage: "제품 사진 선택 단계", app: app)
        attachScreenshot(app, name: "draft-library-photo-selection")

        relaunchAndResume(productID: productID, stage: "제품 사진 선택 단계", app: app)
        assertResumedStage("제품 사진 선택", app: app)
        XCTAssertEqual(completePhotos.value as? String, "0장 선택 · 최소 1장")
        XCTAssertFalse(completePhotos.isEnabled)
        for index in 0..<3 {
            XCTAssertEqual(thumbnail(index, in: app).value as? String, "선택 안 됨")
        }
        attachScreenshot(app, name: "draft-restored-zero-photo-selection")

        for index in [2, 0, 1] { thumbnail(index, in: app).tap() }
        assertSelectionOrder(in: app)
        XCTAssertEqual(exitToLibrary(stage: "제품 사진 선택 단계", app: app), productID)
        relaunchAndResume(productID: productID, stage: "제품 사진 선택 단계", app: app)
        assertResumedStage("제품 사진 선택", app: app)
        assertSelectionOrder(in: app)
        XCTAssertFalse(app.staticTexts["사진을 불러올 수 없어요"].exists)
        attachScreenshot(app, name: "draft-restored-photo-selection-order")
        completePhotos.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))

        replaceText(in: field("name", in: app), with: name, app: app)
        replaceText(in: field("detail", in: app), with: description, app: app)
        replaceText(in: field("brand", in: app), with: brand, app: app)
        let shoulder = app.textFields["product-info.measurement.shoulderWidth"]
        replaceText(in: shoulder, with: "0", app: app)
        XCTAssertEqual(exitToLibrary(stage: "제품 정보 입력 단계", app: app), productID)
        attachScreenshot(app, name: "draft-library-partial-information")

        relaunchAndResume(productID: productID, stage: "제품 정보 입력 단계", app: app)
        assertResumedStage("제품 정보 입력", app: app)
        XCTAssertEqual(field("name", in: app).value as? String, name)
        XCTAssertEqual(field("detail", in: app).value as? String, description)
        XCTAssertEqual(field("brand", in: app).value as? String, brand)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0", "Raw invalid input must survive exit and process restart")
        attachScreenshot(app, name: "draft-restored-partial-information-and-zero")

        // Back still preserves the restored photo order and unfinished numeric text.
        tapBack(in: app)
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))
        assertSelectionOrder(in: app)
        completePhotos.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0")
        app.buttons["product-info.done"].tap()
        let invalid = app.alerts["제품 정보를 저장하지 못했어요"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 5))
        invalid.buttons["확인"].tap()
        replaceText(in: shoulder, with: "67.25", app: app)
        app.buttons["product-info.done"].tap()
        let library = app.buttons["product-complete.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()

        assertCompletedProduct(productID: productID, name: name, brand: brand, app: app)
        attachScreenshot(app, name: "draft-completed-same-product")
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        assertCompletedProduct(productID: productID, name: name, brand: brand, app: app)
        app.buttons["library.product.\(productID)"].tap()
        XCTAssertTrue(app.navigationBars["제품 상세"].waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)["library.measurement.shoulderWidth"].firstMatch
        reveal(row, in: app)
        let labels = [row.label] + row.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("67 cm") })
    }

    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        return app
    }

    private func openMeasurementResult(in app: XCUIApplication) {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].waitForExistence(timeout: 10))
        let capture = app.buttons["captureGarment"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        capture.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
    }

    private func captureTwoDetails(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        let capture = app.buttons["camera.captureDetail"]
        for expectedCount in 2...3 {
            waitEnabled(capture)
            capture.tap()
            let saved = expectation(for: NSPredicate { _, _ in
                self.detailPhotoIdentifiers(in: app).count == expectedCount
            }, evaluatedWith: app)
            wait(for: [saved], timeout: 15)
        }
        waitEnabled(app.buttons["camera.selectPhotos"])
    }

    private func detailPhotoIdentifiers(in app: XCUIApplication) -> Set<String> {
        Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "camera.detailPhoto.")).allElementsBoundByIndex.map(\.identifier))
    }

    @discardableResult
    private func exitToLibrary(stage: String, app: XCUIApplication) -> String {
        let exits = app.buttons.matching(identifier: "product-flow.exit")
        let exit = exits.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? exits.firstMatch
        waitEnabled(exit)
        exit.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 20))
        let drafts = draftButtons(in: app)
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(drafts.count, 1)
        let productID = String(drafts.firstMatch.identifier.dropFirst("library.draft.".count))
        XCTAssertNotNil(UUID(uuidString: productID))
        assertDraft(productID: productID, stage: stage, app: app)
        return productID
    }

    private func relaunchAndResume(productID: String, stage: String, app: XCUIApplication) {
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        assertDraft(productID: productID, stage: stage, app: app)
        app.buttons["library.draft.\(productID)"].tap()
    }

    private func assertResumedStage(_ title: String, app: XCUIApplication) {
        let restored = app.navigationBars[title].waitForExistence(timeout: 15)
        if !restored {
            print("DRAFT_RESTORE_FAILURE \(title)\n\(app.debugDescription)")
            attachScreenshot(app, name: "draft-unexpected-resume-screen")
            attachDiagnostic(app, name: "draft-unexpected-resume-hierarchy")
        }
        XCTAssertTrue(restored, "Resume must reopen the saved \(title) stage")
    }

    private func assertDraft(productID: String, stage: String, app: XCUIApplication) {
        let draft = app.buttons["library.draft.\(productID)"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertEqual(draftButtons(in: app).count, 1)
        let stageText = app.staticTexts["library.draft.stage.\(productID)"]
        XCTAssertTrue((stageText.exists ? stageText.label : draft.label).contains(stage))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).count, 0)
    }

    private func draftButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.draft."))
    }

    private func thumbnail(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let thumbnail = app.buttons["camera.thumbnail.\(index)"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        return thumbnail
    }

    private func assertSelectionOrder(in app: XCUIApplication) {
        for (captureIndex, order) in [(2, 1), (0, 2), (1, 3)] {
            XCTAssertEqual(thumbnail(captureIndex, in: app).value as? String, "\(order)번째 선택")
        }
        let complete = app.buttons["camera.completePhotos"]
        XCTAssertEqual(complete.value as? String, "3장 선택 · 최소 1장")
        XCTAssertTrue(complete.isEnabled)
    }

    private func assertCompletedProduct(productID: String, name: String, brand: String, app: XCUIApplication) {
        let card = app.buttons["library.product.\(productID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains(name))
        XCTAssertTrue(card.label.contains(brand))
        XCTAssertEqual(draftButtons(in: app).count, 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).count, 1)
    }

    private func field(_ key: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-info.\(key)"].firstMatch
    }

    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
            count: current == placeholder ? 0 : current.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }

    private func tapBack(in app: XCUIApplication) {
        if let back = app.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.last(where: { $0.isHittable }) {
            back.tap()
            return
        }
        for bar in app.navigationBars.allElementsBoundByIndex.reversed() {
            if let back = bar.buttons.allElementsBoundByIndex.first(where: {
                $0.isHittable && $0.frame.midX < app.frame.midX && $0.identifier != "product-flow.exit"
            }) {
                back.tap()
                return
            }
        }
        attachDiagnostic(app, name: "draft-native-back-not-found")
        XCTFail("The resumed flow must retain native Back navigation")
    }

    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        wait(for: NSPredicate(format: "enabled == true"), on: element)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement) {
        let observed = expectation(for: predicate, evaluatedWith: element)
        wait(for: [observed], timeout: 20)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            let bars = app.navigationBars
            let bar = bars.element(boundBy: max(0, bars.count - 1))
            let top = bar.exists ? bar.frame.maxY + 12 : 80
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY - 12 : app.frame.maxY - 60
            if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
            let frame = element.frame
            let validFrame = !frame.isEmpty && !frame.isNull && !frame.isInfinite
                && frame.maxX > app.frame.minX && frame.minX < app.frame.maxX
            let goDown = element.exists && validFrame && frame.minY < top
            let height = max(40, bottom - top)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.30 : 0.80) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.80 : 0.30) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachDiagnostic(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
