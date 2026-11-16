import XCTest

/// Uses disposable synthetic captures and isolated stores. No marketplace is
/// opened and no AI request is made by these completion-summary checks.
final class ProductInputCompletionUITests: XCTestCase {
    @MainActor
    func testCompletionPhotosStayStaticWhileSavedPhotosStillOpenAndBothActionsRoute() {
        continueAfterFailure = false
        for isTop in [true, false] {
            let token = UUID().uuidString
            let name = "Completion " + String(token.prefix(8))
            let app = XCUIApplication()
            app.launchArguments = ["--flow-preview", "--flow-test-store", token]
            if isTop { app.launchArguments.append("--garment-preview-top") }
            app.launch()

            tap(app, "product-flow.start")
            armSyntheticGarmentCapture(in: app)
            tap(app, "captureGarment")
            tap(app, "confirmGarmentMeasurement")
            tap(app, "camera.startDetailCapture")
            tap(app, "camera.captureDetail")
            tap(app, "camera.selectPhotos")
            XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))

            enter(name, into: field("name", in: app), app: app)
            enter("실측값과 세 장의 사진을 포함한 완료 화면 확인", into: field("detail", in: app), app: app)
            enter("40000", into: field("price", in: app), app: app)
            enter("Completion Brand", into: field("brand", in: app), app: app)
            let measurementKey = isTop ? "shoulderWidth" : "waistWidth"
            let measurement = app.textFields["product-info.measurement." + measurementKey]
            enter("67", into: measurement, app: app)
            tap(app, "product-info.done")
            XCTAssertTrue(app.buttons["product-complete.export"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["제품 정보 입력 완료 🎉"].exists)
            XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
            let exportFrame = app.buttons["product-complete.export"].frame
            XCTAssertTrue(app.buttons["product-complete.library"].isHittable)

            let photoQuery = NSPredicate(format: "identifier BEGINSWITH %@", "product-detail.photo.")
            let photos = app.images.matching(photoQuery)
            XCTAssertEqual(photos.count, 3, "The completion summary must keep every saved product photo")
            XCTAssertEqual(app.buttons.matching(photoQuery).count, 0)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "제품 사진 확대")).count, 0)
            let first = photos.element(boundBy: 0)
            reveal(first, in: app)
            // AX reports the scaled-to-fill bitmap's intrinsic width instead
            // of the SwiftUI clipping bounds. Validate the 152-point crop in
            // the attached screenshot; its 212-point height is exposed exactly.
            XCTAssertEqual(first.frame.height, 212, accuracy: 1)
            let productName = app.descendants(matching: .any)["product-detail.name"].firstMatch
            XCTAssertLessThan(productName.frame.maxY, first.frame.minY,
                              "The completion design presents the product name before its photos")
            screenshot(named: isTop ? "completion-top-summary" : "completion-bottom-summary")
            first.tap()
            XCTAssertFalse(app.descendants(matching: .any)["product-gallery.pager"].firstMatch.exists)
            XCTAssertFalse(app.buttons["product-gallery.close"].exists)

            let originalX = first.frame.minX
            let row = app.descendants(matching: .any)["product-detail.photos"].firstMatch
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)))
            XCTAssertLessThan(first.frame.minX, originalX - 20,
                              "Removing enlargement must preserve horizontal photo scrolling")
            XCTAssertTrue(photos.element(boundBy: 2).isHittable)

            let keys = isTop ? ["shoulderWidth", "chestWidth", "totalLength", "sleeveLengthLeft"]
                : ["waistWidth", "frontRise", "totalLengthLeft", "hemWidthLeft"]
            for key in keys {
                let cell = app.descendants(matching: .any)["product-detail.measurement." + key].firstMatch
                reveal(cell, in: app)
                XCTAssertTrue(cell.exists, "The summary must use this garment's actual measurements: " + key)
            }
            let corrected = app.descendants(matching: .any)["product-detail.measurement." + measurementKey].firstMatch
            XCTAssertTrue(corrected.staticTexts["67cm"].exists,
                          "Completion must preserve the confirmed value instead of showing the design sample")
            XCTAssertEqual(app.buttons["product-complete.export"].frame.minY, exportFrame.minY, accuracy: 1,
                           "Completion actions remain fixed while the summary scrolls")
            screenshot(named: isTop ? "completion-top-measurements" : "completion-bottom-measurements")

            if isTop {
                tap(app, "product-complete.export")
                XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts[name].exists)
                tap(app, "export.close")
                XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
                app.tabBars.buttons["보관함"].tap()
            } else {
                tap(app, "product-complete.library")
            }
            XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
            let saved = app.staticTexts[name].firstMatch
            reveal(saved, in: app)
            saved.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
            let savedPhoto = app.buttons.matching(photoQuery).firstMatch
            reveal(savedPhoto, in: app)
            XCTAssertTrue(savedPhoto.exists, "Archive details retain their existing photo enlargement")
            savedPhoto.tap()
            XCTAssertTrue(app.descendants(matching: .any)["product-gallery.pager"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["product-gallery.close"].exists)
            app.buttons["product-gallery.close"].tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func field(_ key: String, in app: XCUIApplication) -> XCUIElement {
        // SwiftUI can put the same identifier on a prompt and its editor.
        // Select an editable AX role so typing never targets the prompt text.
        let identifier = "product-info." + key
        let textView = app.textViews[identifier].firstMatch
        if textView.exists { return textView }
        return app.textFields[identifier].firstMatch
    }

    @MainActor
    private func enter(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.isHittable, field.identifier)
        if field.identifier == "product-info.detail" {
            let barBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 100
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let top = max(field.frame.minY, barBottom + 12)
            let bottom = min(field.frame.maxY, keyboardTop - 12)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: field.frame.midX, dy: (top + min(bottom, top + 44)) / 2)).tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: current == placeholder ? 0 : current.count) + text)
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), identifier)
        // Camera guides and the result confirmation own overlays outside the
        // navigation bar's scroll region. Scrolling an already hittable control
        // can dismiss the guide or collapse the result sheet before its tap.
        if !button.isHittable { reveal(button, in: app) }
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            let details = app.scrollViews["product-complete.details-scroll"]
            if details.exists {
                let viewport = details.frame
                if element.isHittable, element.frame.minY >= viewport.minY,
                   element.frame.maxY <= viewport.maxY { return }
                let above = element.frame.minY < viewport.minY
                details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.25 : 0.75))
                    .press(forDuration: 0.05, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.75 : 0.25)))
                continue
            }
            let top = (app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 68) + 12
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 40
            let frame = element.frame
            if element.isHittable, frame.minY >= top,
               (frame.maxY <= bottom || (element.identifier == "product-info.detail" && min(frame.maxY, bottom) - max(frame.minY, top) >= 44)) {
                return
            }
            let above = element.exists && !frame.isEmpty && frame.maxX > app.frame.minX
                && frame.minX < app.frame.maxX && frame.minY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let height = max(40, bottom - top)
            origin.withOffset(CGVector(dx: app.frame.width * 0.97, dy: top + height * (above ? 0.3 : 0.8)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(
                    dx: app.frame.width * 0.97, dy: top + height * (above ? 0.8 : 0.3))))
        }
    }

    @MainActor
    private func screenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
