import XCTest

/// Exercises only labelled synthetic captures in private per-test stores.
/// Relaunches prove that a new flow restores saved state rather than live view state.
@MainActor
final class ProductDraftResumeTests: XCTestCase {
    func testInformationBackUsesDoneStateBeforeAndAfterHomeResume() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openNewInformation(in: app)

        let done = app.buttons["product-info.done"]
        XCTAssertFalse(done.isEnabled)
        returnFromEmptyInformationToSelection(in: app)
        app.buttons["camera.completePhotos"].tap()
        assertResumedStage("제품 정보 입력", app: app)

        // One populated field enables Done even while other required fields are missing.
        let name = "QA partial information"
        replaceText(in: field("name", in: app), with: name, app: app)
        XCTAssertTrue(done.isEnabled)
        presentExitConfirmation(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        attachScreenshot(app, name: "information-back-confirmation-keyboard-dismissed")
        app.buttons["product-flow.exit-cancel"].tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(field("name", in: app).value as? String, name)
        saveAndReturnHome(app: app)
        expectHomeResume(stage: "제품 정보 입력 단계", app: app)

        // Restore from disk, not the same live NavigationStack.
        app.terminate()
        app.launch()
        expectHomeResume(stage: "제품 정보 입력 단계", app: app)
        app.buttons["home.resume"].tap()
        assertResumedStage("제품 정보 입력", app: app)
        XCTAssertFalse(app.navigationBars["제품 정보 수정"].exists)
        XCTAssertEqual(field("name", in: app).value as? String, name)
        XCTAssertTrue(done.isEnabled)
        cancelExitAndStay(title: "제품 정보 입력", app: app)

        // Clearing the last value must restore the selection-return route on a resumed draft too.
        replaceText(in: field("name", in: app), with: "", app: app)
        XCTAssertFalse(done.isEnabled)
        returnFromEmptyInformationToSelection(in: app)
    }

    func testDiscardingNewInformationReturnsHomeWithoutResumeCard() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openNewInformation(in: app)
        replaceText(in: field("name", in: app), with: "Discard unfinished information", app: app)
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-discard"].tap()
        expectHomeAfterDiscard(in: app)
        XCTAssertFalse(app.buttons["home.resume"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.resume"].exists)
    }

    private func openNewInformation(in app: XCUIApplication) {
        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        captureTwoDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        assertResumedStage("제품 사진 선택", app: app)
        for index in [1, 2] { selectionControl(index, in: app).tap() }
        waitEnabled(app.buttons["camera.completePhotos"])
        app.buttons["camera.completePhotos"].tap()
        assertResumedStage("제품 정보 입력", app: app)
    }

    private func returnFromEmptyInformationToSelection(in app: XCUIApplication) {
        app.buttons["product-flow.back"].tap()
        assertResumedStage("제품 사진 선택", app: app)
        XCTAssertFalse(exitConfirmation(in: app).exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "camera.grid.select.")).count, 3)
        for index in 0...2 {
            XCTAssertEqual(selectionControl(index, in: app).value as? String, "\(index + 1)번째 선택")
        }
        XCTAssertFalse(app.staticTexts["사진을 불러올 수 없어요"].exists)
    }

    func testClosingAndDiscardingNewMeasurementResultKeepsWorkUntilDiscardAndLeavesNoDraft() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        let originalPoint = try XCTUnwrap(point.value as? String)

        cancelExitAndStay(title: "실측 결과", screenshot: "draft-exit-three-actions-measurement", app: app)
        XCTAssertEqual(point.value as? String, originalPoint,
                       "Closing the confirmation must keep the current measurement result")
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-discard"].tap()
        expectHomeAfterDiscard(in: app)
        XCTAssertFalse(app.buttons["home.resume"].exists)
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(draftButtons(in: app).count, 0)
        XCTAssertEqual(savedProductButtons(in: app).count, 0)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.resume"].exists)
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(draftButtons(in: app).count, 0)
        XCTAssertEqual(savedProductButtons(in: app).count, 0)
    }

    func testDiscardingResumedInformationDraftReturnsHomeAndPreservesOtherProductsAfterRelaunch() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        openMeasurementResult(in: app)
        let retainedID = saveDraftViaHome(stage: "실측 결과 단계", app: app)
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        let sampleTitle = "90s 나이키 트랙탑"
        XCTAssertTrue(app.navigationBars[sampleTitle].waitForExistence(timeout: 10))
        app.navigationBars[sampleTitle].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
        app.tabBars.buttons["홈"].tap()

        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        captureTwoDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))
        selectionControl(1, in: app).tap()
        selectionControl(2, in: app).tap()
        waitEnabled(app.buttons["camera.completePhotos"])
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        let draftName = "Discard this unfinished product"
        replaceText(in: field("name", in: app), with: draftName, app: app)
        saveAndReturnHome(app: app)
        expectHomeResume(stage: "제품 정보 입력 단계", app: app)
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
        let drafts = draftButtons(in: app)
        XCTAssertEqual(drafts.count, 2)
        guard let discarded = drafts.allElementsBoundByIndex.first(where: { !$0.identifier.hasSuffix(retainedID) }) else {
            XCTFail("The second registration must have its own saved draft")
            return
        }
        let discardedID = String(discarded.identifier.dropFirst("library.draft.".count))
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let restored = app.buttons["library.draft.\(discardedID)"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        restored.tap()
        assertResumedStage("제품 정보 입력", app: app)
        XCTAssertEqual(field("name", in: app).value as? String, draftName)
        let editedName = draftName + " edited"
        replaceText(in: field("name", in: app), with: editedName, app: app)
        cancelExitAndStay(title: "제품 정보 입력", screenshot: "draft-exit-three-actions-information", app: app)
        XCTAssertEqual(field("name", in: app).value as? String, editedName,
                       "Closing the confirmation must keep unsaved input in the resumed draft")

        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-discard"].tap()
        expectHomeAfterDiscard(in: app)
        expectHomeResume(stage: "실측 결과 단계", app: app)
        app.tabBars.buttons["보관함"].tap()
        assertOtherProductsSurviveDiscard(retainedID: retainedID, discardedID: discardedID, app: app)
        attachScreenshot(app, name: "draft-discard-preserves-other-products")

        app.terminate()
        app.launch()
        expectHomeResume(stage: "실측 결과 단계", app: app)
        app.tabBars.buttons["보관함"].tap()
        assertOtherProductsSurviveDiscard(retainedID: retainedID, discardedID: discardedID, app: app)
    }

    func testHomeCardResumesSavedDetailDraftAfterRelaunch() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["home.resume"].exists)
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let initialShutterSize = start.frame.size
        let guidance = app.staticTexts["home.guidance"]
        let initialGuidance = guidance.label
        attachScreenshot(app, name: "home-without-draft")
        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        captureTwoDetails(in: app)
        let productID = saveDraftViaHome(stage: "상세 촬영 단계", app: app)
        app.tabBars.buttons["홈"].tap()
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(resume.label.contains("상세 촬영 단계"))
        XCTAssertTrue(resume.isHittable)
        XCTAssertEqual(start.frame.width, initialShutterSize.width, accuracy: 1)
        XCTAssertEqual(start.frame.height, initialShutterSize.height, accuracy: 1)
        XCTAssertEqual(guidance.label, initialGuidance)
        XCTAssertLessThanOrEqual(guidance.frame.maxY, resume.frame.minY)
        attachScreenshot(app, name: "home-latest-detail-draft")

        // 홈 카드도 새 프로세스에서 저장된 상품 ID로 기존 복원 흐름을 열어야 한다.
        app.terminate()
        app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        assertResumedStage("제품 상세 촬영", app: app)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists)
        XCTAssertTrue(app.buttons["camera.captureDetail"].isHittable)
        XCTAssertEqual(detailPhotoCaptureIndices(in: app).count, 3)
        XCTAssertEqual(saveDraftViaHome(stage: "상세 촬영 단계", app: app), productID)
    }

    func testHomeUpdatesToOlderDraftAfterDeletionAndHidesWhenEmpty() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)
        let firstID = saveDraftViaHome(stage: "실측 결과 단계", app: app)
        app.tabBars.buttons["홈"].tap()
        expectHomeResume(stage: "실측 결과 단계", app: app)

        // 이어하기 카드가 있어도 줄자 버튼은 별도의 새 촬영을 시작한다.
        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 10))
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        guide.tap()
        saveAndReturnHome(app: app)
        expectHomeResume(stage: "상세 촬영 단계", app: app)
        app.tabBars.buttons["보관함"].tap()
        let drafts = draftButtons(in: app)
        XCTAssertEqual(drafts.count, 2)
        let second = drafts.allElementsBoundByIndex.first { !$0.identifier.hasSuffix(firstID) }
        guard let second else { XCTFail("새 촬영은 별도 초안을 생성해야 한다"); return }
        let secondID = String(second.identifier.dropFirst("library.draft.".count))
        deleteDraft(productID: secondID, app: app)
        app.tabBars.buttons["홈"].tap()
        expectHomeResume(stage: "실측 결과 단계", app: app)
        app.buttons["home.resume"].tap()
        assertResumedStage("실측 결과", app: app)
        XCTAssertEqual(saveDraftViaHome(stage: "실측 결과 단계", app: app), firstID)
        deleteDraft(productID: firstID, app: app)
        app.tabBars.buttons["홈"].tap()
        XCTAssertFalse(app.buttons["home.resume"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.resume"].exists)
    }

    func testHomeResumeRemainsReachableWithAccessibilityText() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)
        _ = saveDraftViaHome(stage: "실측 결과 단계", app: app)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        expectHomeResume(stage: "실측 결과 단계", app: app)
        let card = app.buttons["home.resume"]
        XCTAssertGreaterThan(card.frame.height, 125, "큰 글씨에서는 카드 높이가 확장되어야 한다")
        XCTAssertGreaterThanOrEqual(card.frame.minX, 0)
        XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.width)
        attachScreenshot(app, name: "home-draft-accessibility-text")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(card.isHittable)
        attachScreenshot(app, name: "home-draft-accessibility-scrolled")
        card.tap()
        assertResumedStage("실측 결과", app: app)
    }

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
        cancelExitAndStay(title: "실측 결과", screenshot: "draft-exit-confirmation-dark-result", app: app)
        XCTAssertEqual(point.value as? String, correctedPoint)
        let productID = saveDraftViaHome(stage: "실측 결과 단계", app: app)
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
        cancelExitAndStay(title: "제품 상세 촬영", app: app)
        let originalPhotoIndices = detailPhotoCaptureIndices(in: app)
        XCTAssertEqual(originalPhotoIndices.count, 3, "The measurement and both captured originals must be present")
        XCTAssertEqual(saveDraftViaHome(stage: "상세 촬영 단계", app: app), productID)
        attachScreenshot(app, name: "draft-library-details")

        relaunchAndResume(productID: productID, stage: "상세 촬영 단계", app: app, viaHome: false)
        assertResumedStage("제품 상세 촬영", app: app)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists,
                       "A saved photo draft must retain the acknowledged capture guide")
        XCTAssertTrue(app.buttons["camera.captureDetail"].isHittable)
        XCTAssertEqual(detailPhotoCaptureIndices(in: app), originalPhotoIndices)
        XCTAssertFalse(app.buttons["camera.completePhotos"].exists)
        attachScreenshot(app, name: "draft-restored-detail-originals")
    }

    func testSelectionOrderSurvivesReturningToDetailsAndRelaunch() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openMeasurementResult(in: app)
        waitEnabled(app.buttons["confirmGarmentMeasurement"])
        app.buttons["confirmGarmentMeasurement"].tap()
        captureTwoDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        for index in [0, 2, 0, 1] { selectionControl(index, in: app).tap() }
        assertSelectionOrder(in: app)
        returnFromSelectionToDetails(in: app)
        let productID = saveDraftViaHome(stage: "상세 촬영 단계", app: app)
        relaunchAndResume(productID: productID, stage: "상세 촬영 단계", app: app)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "camera.grid.select.")).count, 3)
        assertSelectionOrder(in: app)
        app.buttons["camera.grid.preview.2"].tap()
        let toggle = app.buttons["camera.selectionPreviewToggle"]
        waitEnabled(toggle)
        XCTAssertEqual(toggle.value as? String, "1번째 선택")
        XCTAssertFalse(app.staticTexts["사진을 불러올 수 없어요."].exists)
        app.buttons["camera.closeSelectionPreview"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 5))
        assertSelectionOrder(in: app)
    }

    func testSelectionSurvivesDetailReturnAndDraftResumeThenCompletesTheSameProduct() {
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
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "camera.grid.select.")).count, 3)

        let completePhotos = app.buttons["camera.completePhotos"]
        selectionControl(0, in: app).tap()
        XCTAssertEqual(completePhotos.value as? String, "0장 선택 · 최소 1장 · 최대 10장")
        XCTAssertFalse(completePhotos.isEnabled)
        returnFromSelectionToDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        XCTAssertEqual(completePhotos.value as? String, "0장 선택 · 최소 1장 · 최대 10장")
        XCTAssertFalse(completePhotos.isEnabled)
        returnFromSelectionToDetails(in: app)
        let productID = saveDraftViaHome(stage: "상세 촬영 단계", app: app)
        attachScreenshot(app, name: "draft-library-photo-selection")

        relaunchAndResume(productID: productID, stage: "상세 촬영 단계", app: app)
        app.buttons["camera.selectPhotos"].tap()
        assertResumedStage("제품 사진 선택", app: app)
        XCTAssertEqual(completePhotos.value as? String, "0장 선택 · 최소 1장 · 최대 10장")
        XCTAssertFalse(completePhotos.isEnabled)
        for index in 0..<3 {
            XCTAssertEqual(selectionControl(index, in: app).value as? String, "선택 안 됨")
        }
        attachScreenshot(app, name: "draft-restored-zero-photo-selection")

        for index in [2, 0, 1] { selectionControl(index, in: app).tap() }
        assertSelectionOrder(in: app)
        returnFromSelectionToDetails(in: app)
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.scrollViews["camera.selectionGrid"].waitForExistence(timeout: 10))
        assertSelectionOrder(in: app)
        returnFromSelectionToDetails(in: app)
        XCTAssertEqual(saveDraftViaHome(stage: "상세 촬영 단계", app: app), productID)
        relaunchAndResume(productID: productID, stage: "상세 촬영 단계", app: app)
        app.buttons["camera.selectPhotos"].tap()
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
        cancelExitAndStay(title: "제품 정보 입력", screenshot: "draft-exit-confirmation-light-information", app: app)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0")
        XCTAssertEqual(field("name", in: app).value as? String, name)
        XCTAssertEqual(saveDraftViaHome(stage: "제품 정보 입력 단계", app: app), productID)
        attachScreenshot(app, name: "draft-library-partial-information")

        relaunchAndResume(productID: productID, stage: "제품 정보 입력 단계", app: app)
        assertResumedStage("제품 정보 입력", app: app)
        XCTAssertEqual(field("name", in: app).value as? String, name)
        XCTAssertEqual(field("detail", in: app).value as? String, description)
        XCTAssertEqual(field("brand", in: app).value as? String, brand)
        assertPriceIsOmitted(in: app)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0", "Raw invalid input must survive exit and process restart")
        attachScreenshot(app, name: "draft-restored-partial-information-and-zero")

        // Cancelling Back keeps this exact information draft and its raw edit.
        cancelExitAndStay(title: "제품 정보 입력", app: app)
        XCTAssertEqual(field("name", in: app).value as? String, name)
        XCTAssertEqual(field("detail", in: app).value as? String, description)
        XCTAssertEqual(field("brand", in: app).value as? String, brand)
        assertPriceIsOmitted(in: app)
        let price = field("price", in: app)
        reveal(price, in: app)
        price.tap()
        price.typeText("40000")
        XCTAssertEqual(price.value as? String, "40,000")
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
        app.tabBars.buttons["홈"].tap()
        XCTAssertFalse(app.buttons["home.resume"].exists, "완료된 상품은 홈의 이어하기 대상에서 제외한다")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.resume"].exists)
        app.tabBars.buttons["보관함"].tap()
        assertCompletedProduct(productID: productID, name: name, brand: brand, app: app)
        app.buttons["library.product.\(productID)"].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)["library.measurement.shoulderWidth"].firstMatch
        reveal(row, in: app)
        let labels = [row.label] + row.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("67cm") })
    }

    private func returnFromSelectionToDetails(in app: XCUIApplication) {
        let back = app.buttons.matching(identifier: "product-flow.back")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back)
        back?.tap()
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists)
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
        armSyntheticGarmentCapture(in: app)
        capture.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
    }

    private func captureTwoDetails(in app: XCUIApplication) {
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        guide.tap()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        let capture = app.buttons["camera.captureDetail"]
        for _ in 0..<2 {
            waitEnabled(capture)
            capture.tap()
            waitEnabled(capture)
        }
        waitEnabled(app.buttons["camera.selectPhotos"])
    }

    private func detailPhotoCaptureIndices(in app: XCUIApplication) -> Set<String> {
        let gallery = app.buttons["camera.openGallery"]
        waitEnabled(gallery)
        gallery.tap()
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.galleryThumbnail."))
        // Gallery has the measured original, its annotated copy, and two details.
        XCTAssertEqual(photos.count, 4)
        let originalSlots = [0, 2, 3]
        for index in originalSlots {
            let photo = app.buttons["camera.galleryThumbnail.\(index)"]
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            photo.tap()
            wait(for: NSPredicate(format: "value == %@", "\(index + 1) / 4"), on: pager)
            XCTAssertTrue(photo.isSelected)
        }
        app.buttons["camera.galleryThumbnail.1"].tap()
        wait(for: NSPredicate(format: "value == %@", "2 / 4"), on: pager)
        let measurement = app.descendants(matching: .any)["camera.galleryMeasurement"].firstMatch
        XCTAssertTrue(measurement.exists)
        XCTAssertTrue((measurement.value as? String)?.contains("cm") == true)
        attachScreenshot(app, name: "draft-gallery-preserved-originals-and-evidence")
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 10))
        XCTAssertFalse(exitConfirmation(in: app).exists, "The auxiliary gallery Back must only close the gallery")
        return Set(originalSlots.map { "camera.galleryThumbnail.\($0)" })
    }

    @discardableResult
    private func saveDraftViaHome(stage: String, app: XCUIApplication) -> String {
        saveAndReturnHome(app: app)
        expectHomeResume(stage: stage, app: app)
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
        let drafts = draftButtons(in: app)
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(drafts.count, 1)
        let productID = String(drafts.firstMatch.identifier.dropFirst("library.draft.".count))
        XCTAssertNotNil(UUID(uuidString: productID))
        assertDraft(productID: productID, stage: stage, app: app)
        return productID
    }

    private func saveAndReturnHome(app: XCUIApplication) {
        presentExitConfirmation(in: app)
        app.buttons["product-flow.exit-save"].tap()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(for: NSPredicate(format: "hittable == true"), on: start)
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected, "Saving a registration draft must return to Home")
        XCTAssertFalse(exitConfirmation(in: app).exists)
    }

    private func cancelExitAndStay(title: String, screenshot: String? = nil, app: XCUIApplication) {
        presentExitConfirmation(in: app)
        if let screenshot { attachScreenshot(app, name: screenshot) }
        app.buttons["product-flow.exit-cancel"].tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[title].isHittable)
        XCTAssertTrue(app.buttons["product-flow.back"].isHittable)
    }

    private func presentExitConfirmation(in app: XCUIApplication) {
        let backs = app.buttons.matching(identifier: "product-flow.back")
        let visible = backs.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visible.count, 1, "Registration must show one main Back chevron")
        XCTAssertFalse(app.buttons["product-flow.exit"].exists)
        XCTAssertFalse(app.buttons["product-flow.backToMeasurement"].exists)
        let back = visible.first ?? backs.firstMatch
        waitEnabled(back)
        back.tap()
        XCTAssertTrue(exitConfirmation(in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["product-flow.exit-title"].label, "작성 중인 상품이 있어요")
        let message = app.staticTexts["product-flow.exit-message"]
        XCTAssertEqual(message.label, "나중에 이어서 작성할 수 있도록 임시 저장할까요?")
        let save = app.buttons["product-flow.exit-save"]
        let discard = app.buttons["product-flow.exit-discard"]
        let close = app.buttons["product-flow.exit-cancel"]
        for (button, label) in [(save, "임시저장하고 나가기"), (discard, "삭제하고 나가기"), (close, "닫기")] {
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.label, label)
        }
        XCTAssertLessThanOrEqual(save.frame.maxY, discard.frame.minY)
        XCTAssertLessThanOrEqual(discard.frame.maxY, close.frame.minY)
    }

    private func expectHomeAfterDiscard(in app: XCUIApplication) {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(for: NSPredicate(format: "hittable == true"), on: start)
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected,
                      "Discarding a registration resumed from Library must return to Home")
        XCTAssertFalse(exitConfirmation(in: app).exists)
    }

    private func assertOtherProductsSurviveDiscard(retainedID: String, discardedID: String, app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.draft.\(retainedID)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library.draft.\(discardedID)"].exists)
        XCTAssertEqual(draftButtons(in: app).count, 1)
        let sample = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        XCTAssertTrue(sample.label.contains("90s 나이키 트랙탑"))
        XCTAssertTrue(sample.label.contains("89,000"))
        XCTAssertEqual(savedProductButtons(in: app).count, 1)
    }

    private func savedProductButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.product."))
    }

    private func exitConfirmation(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-flow.exit-confirmation"].firstMatch
    }

    private func relaunchAndResume(productID: String, stage: String, app: XCUIApplication, viaHome: Bool = true) {
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        assertDraft(productID: productID, stage: stage, app: app)
        if viaHome {
            app.tabBars.buttons["홈"].tap()
            expectHomeResume(stage: stage, app: app)
            app.buttons["home.resume"].tap()
        } else {
            app.buttons["library.draft.\(productID)"].tap()
        }
    }

    private func expectHomeResume(stage: String, app: XCUIApplication) {
        let card = app.buttons["home.resume"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains(stage))
        for _ in 0..<5 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(card.isHittable)
    }

    private func deleteDraft(productID: String, app: XCUIApplication) {
        let edit = app.buttons["library.edit-mode"]
        if edit.label == "수정" { edit.tap() }
        let remove = app.buttons["library.delete.\(productID)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.alerts["이 작업을 삭제하겠습니까?"].buttons["삭제하기"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 10))
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

    private func selectionControl(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let control = app.buttons["camera.grid.select.\(index)"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        return control
    }

    private func assertSelectionOrder(in app: XCUIApplication) {
        for (captureIndex, order) in [(2, 1), (0, 2), (1, 3)] {
            XCTAssertEqual(selectionControl(captureIndex, in: app).value as? String, "\(order)번째 선택")
        }
        let complete = app.buttons["camera.completePhotos"]
        XCTAssertEqual(complete.value as? String, "3장 선택 · 최소 1장 · 최대 10장")
        XCTAssertTrue(complete.isEnabled)
    }

    private func assertCompletedProduct(productID: String, name: String, brand: String, app: XCUIApplication) {
        let card = app.buttons["library.product.\(productID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains(name))
        XCTAssertTrue(card.label.contains(brand))
        XCTAssertTrue(card.label.contains("40,000"))
        XCTAssertEqual(draftButtons(in: app).count, 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).count, 1)
    }

    private func field(_ key: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-info.\(key)"].firstMatch
    }

    private func assertPriceIsOmitted(in app: XCUIApplication) {
        let price = field("price", in: app)
        XCTAssertTrue(price.exists)
        let text = price.value as? String ?? ""
        XCTAssertTrue(text.isEmpty || text == price.placeholderValue,
                      "An unfinished draft must retain its omitted required price")
    }

    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        if field.identifier == "product-info.detail" {
            let barBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 100
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let visibleTop = max(field.frame.minY, barBottom + 12)
            let visibleBottom = min(field.frame.maxY, keyboardTop - 12)
            let tapY = (visibleTop + min(visibleBottom, visibleTop + 44)) / 2
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: field.frame.midX, dy: tapY)).tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
            count: current == placeholder ? 0 : current.count) + text)
        XCTAssertEqual(field.value as? String, text)
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
            if element.isHittable {
                if element.identifier == "product-info.detail",
                   min(element.frame.maxY, bottom) - max(element.frame.minY, top) >= 44 { return }
                if element.frame.minY >= top, element.frame.maxY <= bottom { return }
            }
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
