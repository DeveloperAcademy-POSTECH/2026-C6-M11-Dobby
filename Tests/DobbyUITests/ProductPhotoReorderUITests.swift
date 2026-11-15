import XCTest

@MainActor
final class ProductPhotoReorderUITests: XCTestCase {
    func testDraggingPhotoKeepsReorderingAndGalleryAvailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 15))
        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let edit = app.buttons["library.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let strip = app.collectionViews["product-info.photo-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        func visiblePhotos() -> [XCUIElement] {
            strip.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
                .allElementsBoundByIndex.filter { strip.frame.contains($0.frame) }
                .sorted { $0.frame.minX < $1.frame.minX }
        }
        let original = visiblePhotos()
        XCTAssertGreaterThanOrEqual(original.count, 2)
        let firstID = original[0].identifier
        let secondID = original[1].identifier
        original[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 1, thenDragTo: original[1].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)),
                   withVelocity: .slow, thenHoldForDuration: 8)
        let reordered = visiblePhotos()
        XCTAssertEqual(reordered[0].identifier, secondID)
        XCTAssertEqual(reordered[1].identifier, firstID)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "photo-strip-after-reordering"
        attachment.lifetime = .keepAlways
        add(attachment)
        reordered[1].tap()
        XCTAssertTrue(app.buttons["product-gallery.close"].firstMatch.waitForExistence(timeout: 5))
    }
}
