import XCTest

@MainActor
final class ProductPhotoAdditionTests: XCTestCase {
    func testTenExistingPhotosStillAllowOpeningAlbumPicker() {
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
        let count = app.staticTexts["product-info.photo-count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "제품 사진 10장, 최대 10장")
        let add = app.buttons["product-info.add-photo"].firstMatch
        XCTAssertTrue(add.isEnabled)
        add.tap()
        let album = app.buttons["앨범에서 선택하기"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        // The system picker exposes its navigation bar after presentation.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["product-info.done"].isHittable)
    }
}
