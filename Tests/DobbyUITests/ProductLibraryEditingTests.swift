// Created by mason on 10/30/26.
import XCTest

@MainActor
final class ProductLibraryEditingTests: XCTestCase {
    func testCancelDiscardSaveAndNoBrandAcrossRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let detail = app.navigationBars["90s 나이키 트랙탑"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        app.buttons["library.edit"].tap()
        let back = app.buttons["product-flow.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5)) // 수정 전에는 알림 없이 상세로.
        app.buttons["library.edit"].tap()
        let name = app.textFields["product-info.name"]
        replace(name, with: "Discard me", in: app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "product-info.delete-photo.")).firstMatch
        let removedID = photo.identifier
        photo.tap()
        back.tap()
        let cancel = app.buttons["product-info.discard-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "library-edit-discard-confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Discard me")
        XCTAssertFalse(app.buttons[removedID].exists)
        back.tap()
        app.buttons["product-info.discard-exit"].tap()
        let card = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        app.buttons["library.edit"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "90s 나이키 트랙탑")
        XCTAssertTrue(app.buttons[removedID].exists)
        let brand = app.textFields["product-info.brand"]
        replace(brand, with: "   ", in: app)
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        detail.buttons.firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("No Brand"))
        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("No Brand"))
        card.tap()
        app.buttons["library.edit"].tap()
        for _ in 0..<5 where !brand.isHittable { app.swipeUp() }
        XCTAssertEqual(brand.value as? String, "   ")
    }

    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        for _ in 0..<5 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(field.value as? String, text)
        app.swipeDown() // 키보드를 닫고 상단 작업 버튼을 표시한다.
    }
}
