import XCTest

@MainActor
final class ProductPhotoImportUITests: XCTestCase {
    func testAlbumImportRestoresPhotosAndKeepsOverflowBlocked() throws {
        // Seed the simulator photo library with at least eleven images before running.
        guard ProcessInfo.processInfo.environment["DOBBY_UI_ALBUM_IMPORT_FIXTURES"] == "1" else {
            throw XCTSkip("Requires seeded simulator album fixtures")
        }
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
        let onboardingClose = app.buttons["닫기"].firstMatch
        if onboardingClose.exists { onboardingClose.tap() }
        let images = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertGreaterThanOrEqual(images.count, 11)
        // Freeze the grid positions: Photos can reorder accessibility elements
        // as selection changes even though the thumbnails stay in place.
        var frames: [CGRect] = images.allElementsBoundByIndex.map { $0.frame }
        frames.sort { left, right in
            if left.minY == right.minY { return left.minX < right.minX }
            return left.minY < right.minY
        }
        for frame in frames.prefix(11) {
            XCTAssertLessThan(frame.midY, app.frame.height - 90)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        }
        app.navigationBars["사진"].buttons["완료"].tap()
        let skeleton = app.descendants(matching: .any)["product-info.photos.importing"].firstMatch
        if skeleton.exists {
            XCTAssertFalse(app.buttons["product-info.done"].isEnabled)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "photo-import-skeleton"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 40))
        XCTAssertEqual(count.label, "제품 사진 21장, 최대 10장")
        XCTAssertTrue(add.isEnabled)
        app.buttons["product-info.done"].tap()
        XCTAssertTrue(app.buttons["product-info.done"].exists)
        XCTAssertEqual(count.label, "제품 사진 21장, 최대 10장")
    }
}
