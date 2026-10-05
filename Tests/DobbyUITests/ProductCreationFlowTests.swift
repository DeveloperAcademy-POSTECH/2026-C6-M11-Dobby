import XCTest

/// Only the explicitly labelled synthetic flow runs here. Each test uses a new
/// isolated SwiftData store and never imports Photos, starts a copy activity,
/// presses a copy control, or opens a marketplace link.
final class ProductCreationFlowTests: XCTestCase {
    @MainActor
    func testTopCreationKeepsCorrectedMeasurementsPhotosAndExportAcrossBackAndRelaunch() throws {
        continueAfterFailure = false
        let token = UUID().uuidString
        let name = "Flow top " + String(token.prefix(8))
        let brand = "FlowTestBrand"
        let description = "A measured product with two selected photos."
        let app = fixtureApp(token: token, top: true)
        app.launch()
        openCapture(in: app)
        app.buttons["captureGarment"].tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).count, 6)

        // A small physical-point correction must still be usable in the new
        // full flow. This is synthetic depth evidence, not a camera accuracy test.
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 5) && photo.waitForExistence(timeout: 5))
        let originalPoint = try XCTUnwrap(point.value as? String)
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        wait(for: NSPredicate(format: "value != %@", originalPoint), on: point)
        waitEnabled(confirm)
        attachScreenshot(app, name: "flow-top-measurement-result-corrected-point")
        confirm.tap()

        let captureDetail = app.buttons["camera.captureDetail"]
        XCTAssertTrue(captureDetail.waitForExistence(timeout: 15))
        waitEnabled(captureDetail)
        captureDetail.tap()
        let choose = app.buttons["camera.selectPhotos"]
        waitEnabled(choose)
        attachScreenshot(app, name: "flow-top-detail-captured-original")
        choose.tap()
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))
        let detail = app.buttons["camera.thumbnail.1"]
        reveal(detail, in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        waitEnabled(detail)
        detail.tap()
        XCTAssertEqual(detail.value as? String, "2번째 선택")
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "2장 선택 · 최소 1장")
        attachScreenshot(app, name: "flow-top-photo-selection-two-photos")
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        attachScreenshot(app, name: "flow-top-info-before-editing")
        replaceText(in: field("name", app: app), with: name, app: app)
        replaceText(in: field("detail", app: app), with: description, app: app)
        replaceText(in: field("brand", app: app), with: brand, app: app)
        let shoulder = app.textFields["product-info.measurement.shoulderWidth"]
        reveal(shoulder, in: app)

        // Native Back must keep an unfinished measurement edit in this same
        // draft while the selected photo originals remain available.
        replaceText(in: shoulder, with: "68.39", app: app)
        returnToInformationThroughPhotoSelection(in: app)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "68.39")
        attachScreenshot(app, name: "flow-top-pending-draft-restored-68.39")

        // Invalid input also survives navigation so the user can correct it;
        // returning to Info must never silently replace it with an old value.
        replaceText(in: shoulder, with: "0", app: app)
        returnToInformationThroughPhotoSelection(in: app)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0")
        attachScreenshot(app, name: "flow-top-invalid-pending-draft-restored-zero")
        app.buttons["product-info.done"].tap()
        let invalidValue = app.alerts["제품 정보를 저장하지 못했어요"]
        XCTAssertTrue(invalidValue.waitForExistence(timeout: 5))
        let validationMessage = invalidValue.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "어깨너비", "0보다 큰 숫자", "입력한 정보는 화면에 남아 있어요")).firstMatch
        XCTAssertTrue(validationMessage.exists)
        attachScreenshot(app, name: "flow-top-invalid-measurement-save-guidance")
        invalidValue.buttons["확인"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists)
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "0")

        replaceText(in: shoulder, with: "67.25", app: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        assertFocusedMeasurementVisible(shoulder, in: app)
        attachScreenshot(app, name: "flow-top-info-focused-67.25")
        // Complete while the decimal input still owns focus: the pending draft
        // must persist all digits instead of reusing the rounded display value.
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.export"].waitForExistence(timeout: 15))
        attachScreenshot(app, name: "flow-top-completion-real-product")
        app.buttons["product-complete.export"].tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "flow-top-export-current-product")

        let fruitsDetails = app.buttons["후루츠패밀리로 내보내기 (A)"]
        reveal(fruitsDetails, in: app)
        fruitsDetails.tap()
        XCTAssertTrue(app.navigationBars["제품 상세 페이지"].waitForExistence(timeout: 10))
        let actualShoulder = app.staticTexts["67cm"].firstMatch
        reveal(actualShoulder, in: app)
        XCTAssertTrue(actualShoulder.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "어깨", "복사")).firstMatch.exists,
                      "An upper-body measurement must reach the export detail list")
        XCTAssertFalse(app.buttons["허리 단면 복사"].exists)
        attachScreenshot(app, name: "flow-top-export-actual-shoulder-no-copy")

        // The export detail's edit action returns to this same product. Simply
        // focusing an existing number must not round it or create a new draft.
        let editFromExport = app.buttons["export.detail.edit"]
        XCTAssertTrue(editFromExport.waitForExistence(timeout: 5))
        editFromExport.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        focusExistingShoulder(in: app)
        attachScreenshot(app, name: "flow-top-export-edit-retains-67.25")
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.export"].waitForExistence(timeout: 10))
        app.buttons["product-complete.export"].tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
        reveal(fruitsDetails, in: app)
        fruitsDetails.tap()
        XCTAssertTrue(app.navigationBars["제품 상세 페이지"].waitForExistence(timeout: 10))
        reveal(actualShoulder, in: app)
        XCTAssertTrue(actualShoulder.exists, "An unchanged edit must preserve the integer export display")
        attachScreenshot(app, name: "flow-top-export-after-unchanged-edit-67-display")
        tapBack(in: app)
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 5))
        app.buttons["export.close"].tap()
        XCTAssertTrue(app.buttons["product-complete.library"].waitForExistence(timeout: 10))

        // Presenting Export must not discard the detail originals needed by
        // back-navigation to the same photo-selection model.
        tapBack(in: app)
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        tapBack(in: app)
        if app.navigationBars["제품 상세 촬영"].exists {
            app.buttons["camera.selectPhotos"].tap()
        }
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))
        reveal(detail, in: app)
        XCTAssertEqual(detail.value as? String, "2번째 선택")
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "2장 선택 · 최소 1장")
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.library"].waitForExistence(timeout: 10))
        app.buttons["product-complete.library"].tap()
        openLibraryProduct(named: name, app: app)
        assertSavedValue(key: "shoulderWidth", contains: "67 cm", app: app)
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        openLibraryProduct(named: name, app: app)
        assertSavedValue(key: "shoulderWidth", contains: "67 cm", app: app)
        XCTAssertTrue(app.staticTexts[brand].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", brand)).firstMatch.exists)
        XCTAssertTrue(app.staticTexts[description].exists)
        attachScreenshot(app, name: "flow-top-library-relaunch-corrected-value")

        app.buttons["library.edit"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        focusExistingShoulder(in: app, expectedText: "67")
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.library"].waitForExistence(timeout: 10))
        app.buttons["product-complete.library"].tap()
        openLibraryProduct(named: name, app: app)
        assertSavedValue(key: "shoulderWidth", contains: "67 cm", app: app)
        attachScreenshot(app, name: "flow-top-library-after-unchanged-edit-67-display")

        // A saved product keeps pending edits when returning to its detail
        // page, and commits them only after completing Info again.
        app.buttons["library.edit"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        replaceText(in: shoulder, with: "72.19", app: app)
        tapBack(in: app)
        XCTAssertTrue(app.navigationBars["제품 상세"].waitForExistence(timeout: 10))
        assertSavedValue(key: "shoulderWidth", contains: "67 cm", app: app)
        app.buttons["library.edit"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
        reveal(shoulder, in: app)
        XCTAssertEqual(shoulder.value as? String, "72.19")
        attachScreenshot(app, name: "flow-top-library-pending-draft-restored-72.19")
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.library"].waitForExistence(timeout: 10))
        app.buttons["product-complete.library"].tap()
        openLibraryProduct(named: name, app: app)
        assertSavedValue(key: "shoulderWidth", contains: "72 cm", app: app)
        attachScreenshot(app, name: "flow-top-library-saved-restored-draft-72-display")
    }

    @MainActor
    func testBottomEightValuesMeasurementOnlySelectionAndEmptyCopyHomeUseRealProductFlow() throws {
        continueAfterFailure = false
        let token = UUID().uuidString
        let name = "Flow bottom " + String(token.prefix(8))
        let app = fixtureApp(token: token, top: false)
        app.launch()

        // An absent copy session must produce guidance instead of showing the
        // old mock product. This URL performs no copy or marketplace launch.
        app.open(URL(string: "dobby-copy://home")!)
        let emptyHelper = app.alerts["내보내기를 열 수 없어요"]
        XCTAssertTrue(emptyHelper.waitForExistence(timeout: 10))
        XCTAssertTrue(emptyHelper.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "진행 중인 복사 도우미가 없어요")).firstMatch.exists)
        emptyHelper.buttons["확인"].tap()
        XCTAssertFalse(app.buttons["export.close"].exists)
        openCapture(in: app)
        app.buttons["closeGarmentCapture"].tap()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(app.staticTexts["보관된 제품이 없어요"].waitForExistence(timeout: 5))
        app.tabBars.buttons["홈"].tap()
        openCapture(in: app)
        app.buttons["captureGarment"].tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_bottom.")).count, 8)
        waitEnabled(confirm)
        confirm.tap()
        XCTAssertTrue(app.buttons["camera.selectPhotos"].waitForExistence(timeout: 15))
        app.buttons["camera.selectPhotos"].tap()
        XCTAssertTrue(app.buttons["camera.completePhotos"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "1장 선택 · 최소 1장")
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        replaceText(in: field("name", app: app), with: name, app: app)
        let first = app.textFields["product-info.measurement.waistWidth"]
        reveal(first, in: app)
        let expected = Set(["waistWidth", "frontRise", "totalLengthLeft", "hemWidthLeft", "inseamLeft",
                            "totalLengthRight", "hemWidthRight", "inseamRight"])
        let table = app.scrollViews["product-info.measurements"]
        XCTAssertTrue(table.exists)
        var seen: Set<String> = []
        for _ in 0..<9 {
            for element in app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.measurement.")).allElementsBoundByIndex {
                if element.exists {
                    seen.insert(String(element.identifier.dropFirst("product-info.measurement.".count)))
                }
            }
            if expected.isSubset(of: seen) { break }
            table.swipeLeft()
        }
        XCTAssertEqual(seen, expected)
        XCTAssertFalse(app.textFields["product-info.measurement.shoulderWidth"].exists)
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-complete.library"].waitForExistence(timeout: 10))
        app.buttons["product-complete.library"].tap()
        openLibraryProduct(named: name, app: app)
        for key in expected {
            let value = app.descendants(matching: .any)["library.measurement.\(key)"].firstMatch
            reveal(value, in: app)
            XCTAssertTrue(value.exists, key)
        }
        attachScreenshot(app, name: "flow-bottom-library-eight-measurements")
    }

    @MainActor
    private func fixtureApp(token: String, top: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", token]
        if top { app.launchArguments.append("--garment-preview-top") }
        return app
    }

    @MainActor
    private func openCapture(in app: XCUIApplication) {
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func field(_ key: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["product-info.\(key)"].firstMatch
    }

    @MainActor
    private func returnToInformationThroughPhotoSelection(in app: XCUIApplication) {
        tapBack(in: app)
        let selectPhotos = app.buttons["camera.selectPhotos"]
        if selectPhotos.isHittable { selectPhotos.tap() }
        XCTAssertTrue(app.navigationBars["제품 사진 선택"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "2장 선택 · 최소 1장")
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current == placeholder ? 0 : current.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func openLibraryProduct(named name: String, app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
        let product = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.product.", name)).firstMatch
        reveal(product, in: app)
        XCTAssertTrue(product.waitForExistence(timeout: 10))
        product.tap()
        XCTAssertTrue(app.navigationBars["제품 상세"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertSavedValue(key: String, contains value: String, app: XCUIApplication) {
        let row = app.descendants(matching: .any)["library.measurement.\(key)"].firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.exists)
        let children = row.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(([row.label] + children).contains { $0.contains(value) }, "Displayed \(key) must show \(value), found \(row.label) \(children)")
    }

    @MainActor
    private func focusExistingShoulder(in app: XCUIApplication, expectedText: String = "67.25") {
        let shoulder = app.textFields["product-info.measurement.shoulderWidth"]
        reveal(shoulder, in: app)
        if !shoulder.isHittable {
            attachDiagnostic(app, element: shoulder, name: "flow-shoulder-not-hittable")
        }
        XCTAssertTrue(shoulder.isHittable)
        XCTAssertEqual(shoulder.value as? String, expectedText)
        shoulder.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(shoulder.value as? String, expectedText)
        assertFocusedMeasurementVisible(shoulder, in: app)
    }

    @MainActor
    private func assertFocusedMeasurementVisible(_ field: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let visible = expectation(for: NSPredicate { _, _ in
            keyboard.exists && field.frame.maxY <= keyboard.frame.minY
        }, evaluatedWith: field)
        wait(for: [visible], timeout: 10)
        XCTAssertTrue(keyboard.exists, "The exact value must be completed while its decimal keyboard is still open")
    }

    @MainActor
    private func tapBack(in app: XCUIApplication) {
        // A covered SwiftUI NavigationStack may retain a later, empty navbar
        // in the AX enumeration. Liquid Glass can also expose the native back
        // button as a sibling, so prefer a hittable native button globally.
        if let nativeBack = app.buttons.matching(identifier: "BackButton")
            .allElementsBoundByIndex.last(where: { $0.isHittable }) {
            nativeBack.tap()
            return
        }
        for bar in app.navigationBars.allElementsBoundByIndex.reversed() {
            if let back = bar.buttons.allElementsBoundByIndex.first(where: {
                $0.isHittable && $0.frame.midX < app.frame.midX
            }) {
                back.tap()
                return
            }
        }
        attachDiagnostic(app, element: app, name: "flow-visible-back-not-found")
        XCTFail("The current screen must expose a hittable native back button")
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        wait(for: NSPredicate(format: "enabled == true"), on: element)
    }

    @MainActor
    private func wait(for predicate: NSPredicate, on element: XCUIElement) {
        let observed = expectation(for: predicate, evaluatedWith: element)
        wait(for: [observed], timeout: 15)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            let bars = app.navigationBars
            let bar = bars.element(boundBy: max(0, bars.count - 1))
            let top = bar.exists ? bar.frame.maxY + 12 : 80
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY - 12 : app.frame.maxY - 60
            if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
            let frame = element.frame
            let hasValidHorizontalFrame = !frame.isEmpty && !frame.isNull && !frame.isInfinite
                && frame.maxX > app.frame.minX && frame.minX < app.frame.maxX
            // Offscreen SwiftUI children can report .zero. That is not
            // evidence that a field lies above the viewport; continue towards
            // later content until it has a meaningful visible-layout frame.
            let goDown = element.exists && hasValidHorizontalFrame && frame.minY < top
            let height = max(40, bottom - top)
            // A gesture at the outer edge avoids editing a garment point or
            // swiping a nested horizontal strip. Both endpoints stay above the
            // keyboard, so a scroll cannot turn into a keyboard gesture.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.30 : 0.80) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.80 : 0.30) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachDiagnostic(_ app: XCUIApplication, element: XCUIElement, name: String) {
        let keyboard = app.keyboards.firstMatch
        let attachment = XCTAttachment(string: "Element: \(element.identifier)\nFrame: \(element.frame)\nHittable: \(element.isHittable)\nApp: \(app.frame)\nKeyboard: \(keyboard.exists ? String(describing: keyboard.frame) : "absent")\n\n\(app.debugDescription)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
