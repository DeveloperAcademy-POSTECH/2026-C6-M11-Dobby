import XCTest

/// Creates a synthetic product in an isolated store before visiting export screens.
/// It never starts a copy helper or opens an external platform.
@MainActor
final class LibraryExportBadgeTests: XCTestCase {
    func testPlatformSelectionsDoNotCreateCompletedUploadBadgesAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        defer { app.terminate() }

        let productName = "Export badge regression product"
        startMeasurementFromHome(in: app)
        armSyntheticGarmentCapture(in: app)
        tap("captureGarment", in: app)
        tap("confirmGarmentMeasurement", in: app)
        tap("camera.startDetailCapture", in: app)
        tap("camera.captureDetail", in: app)
        tap("camera.selectPhotos", in: app)
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        enter(productName, into: "name", in: app)
        enter("Isolated product for completed-upload badge verification", into: "detail", in: app)
        enter("40000", into: "price", in: app)
        tap("product-info.done", in: app)
        tap("product-complete.library", in: app)
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))

        let card = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.product.", productName
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let cardID = card.identifier
        XCTAssertTrue(cardID.hasPrefix("library.product."))
        assertNoCompletedUploadBadges(on: card)
        card.tap()

        let export = app.buttons["library.export"]
        reveal(export, in: app)
        export.tap()
        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))

        // Visiting a platform does not confirm a completed upload. Do not
        // save photos, start PiP or open the external platform in this test.
        for _ in 0..<2 {
            let fruits = app.buttons["후르츠패밀리에 업로드하기"]
            reveal(fruits, in: app)
            fruits.tap()
            let closeFruits = app.buttons["채널 선택으로 돌아가기"]
            XCTAssertTrue(closeFruits.waitForExistence(timeout: 10))
            closeFruits.tap()
            XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 5))
        }
        app.buttons["export.close"].tap()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected)
        app.tabBars.buttons["보관함"].tap()
        assertNoCompletedUploadBadges(on: app.buttons[cardID])

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        assertNoCompletedUploadBadges(on: app.buttons[cardID])
    }

    private func assertNoCompletedUploadBadges(on card: XCUIElement, file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertTrue(card.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertFalse(card.label.contains("업로드 완료 플랫폼"), file: file, line: line)
        XCTAssertFalse(card.label.contains("후루츠패밀리로 내보내기"), file: file, line: line)
        XCTAssertFalse(card.label.contains("Instagram으로 내보내기"), file: file, line: line)
        XCTAssertFalse(card.label.contains("카페24로 내보내기"), file: file, line: line)
        XCTAssertFalse(card.label.contains("네이버스토어로 내보내기"), file: file, line: line)
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), identifier)
        if !button.isHittable { reveal(button, in: app) }
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }

    private func enter(_ text: String, into key: String, in app: XCUIApplication) {
        let identifier = "product-info." + key
        let textView = app.textViews[identifier].firstMatch
        let field = textView.exists ? textView : app.textFields[identifier].firstMatch
        reveal(field, in: app)
        if key == "detail" {
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 100
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let top = max(field.frame.minY, navigationBottom + 12)
            let bottom = min(field.frame.maxY, keyboardTop - 12)
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: field.frame.midX, dy: (top + min(bottom, top + 44)) / 2)
            ).tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let value = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: value == placeholder ? 0 : value.count) + text)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            let top = (app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map { $0.frame.maxY }.max() ?? 68) + 12
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 40
            let frame = element.frame
            if element.isHittable, frame.minY >= top,
               frame.maxY <= bottom || (element.identifier == "product-info.detail"
                    && min(frame.maxY, bottom) - max(frame.minY, top) >= 44) { break }
            let above = element.exists && !frame.isEmpty && frame.minY < top
            let height = max(40, bottom - top)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.width * 0.97, dy: top + height * (above ? 0.3 : 0.8)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(
                    dx: app.frame.width * 0.97, dy: top + height * (above ? 0.8 : 0.3))))
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
