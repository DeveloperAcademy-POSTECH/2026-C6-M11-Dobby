// Created by mason on 10/20/26.
import XCTest

final class DetailPhotoGalleryUITests: XCTestCase {
    @MainActor
    func testBrowsingWithoutDeletionAndReturnToCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let confirmedLabels = enterDetailCapture(app)
        defer { app.terminate() }
        XCTAssertFalse(confirmedLabels.isEmpty)
        let guide = app.buttons["camera.startDetailCapture"]
        let capture = app.buttons["camera.captureDetail"]
        for _ in 0..<2 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        assertFocused(app, index: 3, total: 4)
        XCTAssertGreaterThan(app.buttons["camera.galleryThumbnail.3"].frame.width,
                             app.buttons["camera.galleryThumbnail.2"].frame.width)
        let strip = app.scrollViews["camera.galleryStrip"]
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        assertFocused(app, index: 0, total: 4)
        XCTAssertGreaterThan(app.buttons["camera.galleryThumbnail.3"].frame.midX, app.frame.midX)
        app.buttons["camera.galleryThumbnail.3"].tap()
        assertFocused(app, index: 3, total: 4)
        pager.swipeRight()
        assertFocused(app, index: 2, total: 4)
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertPage(pager, "1 / 4")
        XCTAssertFalse(app.buttons["camera.galleryDelete.0"].exists)
        app.buttons["camera.galleryThumbnail.1"].tap()
        assertPage(pager, "2 / 4")
        XCTAssertFalse(app.buttons["camera.galleryDelete.1"].exists)
        let annotated = app.descendants(matching: .any)["camera.galleryMeasurement"].firstMatch
        XCTAssertTrue(annotated.waitForExistence(timeout: 5))
        XCTAssertTrue((annotated.value as? String)?.contains("cm") == true)
        for label in confirmedLabels {
            let fields = label.components(separatedBy: ", ")
            XCTAssertGreaterThanOrEqual(fields.count, 2)
            XCTAssertTrue((annotated.value as? String)?.contains(fields.prefix(2).joined(separator: " ")) == true)
        }
        XCTAssertFalse(app.buttons["enlargeGarmentPhoto"].exists)
        let measurementShot = XCTAttachment(screenshot: app.screenshot())
        measurementShot.name = "measurement-photo-gallery"; measurementShot.lifetime = .keepAlways; add(measurementShot)
        app.buttons["camera.galleryThumbnail.2"].tap()
        assertFocused(app, index: 2, total: 4)
        let frames = (0..<4).map { app.buttons["camera.galleryThumbnail.\($0)"].frame }
        let compactGap = frames[1].minX - frames[0].maxX
        XCTAssertGreaterThan(frames[2].minX - frames[1].maxX, compactGap)
        XCTAssertGreaterThan(frames[3].minX - frames[2].maxX, compactGap)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-photo-gallery"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.buttons["camera.galleryDelete.2"].exists)
        XCTAssertFalse(app.buttons["camera.galleryDelete.3"].exists)
        XCTAssertEqual(pager.value as? String, "3 / 4")
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertFalse(guide.exists)
        capture.tap()
        let next = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        XCTAssertTrue(app.buttons["camera.thumbnail.3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.thumbnail.4"].exists)
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "1장 선택 · 최소 1장")
    }

    @MainActor
    func testMeasurementOnlyGalleryCentersBothEnds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        app.buttons["camera.openGallery"].tap()
        assertFocused(app, index: 0, total: 2)
        app.buttons["camera.galleryThumbnail.1"].tap()
        assertFocused(app, index: 1, total: 2)
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertFocused(app, index: 0, total: 2)
        XCTAssertFalse(app.buttons["camera.galleryThumbnail.2"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "camera.galleryDelete.")).count, 0)
    }

    @MainActor
    func testOverflowingFilmstripScrollsToBothEndsAndReopensAtLatest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        let capture = app.buttons["camera.captureDetail"]
        // 실측 2개 + 상세 16개: iPhone 17의 화면 너비를 넘는 필름스트립.
        for _ in 0..<16 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        assertFocused(app, index: 17, total: 18)
        let strip = app.scrollViews["camera.galleryStrip"]
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        for _ in 0..<6 {
            if pager.value as? String == "1 / 18" { break }
            strip.swipeRight()
        }
        assertFocused(app, index: 0, total: 18)
        for _ in 0..<6 {
            if pager.value as? String == "18 / 18" { break }
            strip.swipeLeft()
        }
        assertFocused(app, index: 17, total: 18)
        pager.swipeRight()
        assertFocused(app, index: 16, total: 18)
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(gallery.wait(for: \.isHittable, toEqual: true, timeout: 10)); gallery.tap()
        assertFocused(app, index: 17, total: 18)
    }

    @MainActor
    private func enterDetailCapture(_ app: XCUIApplication) -> [String] {
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20)); start.tap()
        let measure = app.buttons["captureGarment"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        measure.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        let labels = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex.map(\.label)
        confirm.tap()
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10)); guide.tap()
        return labels
    }

    @MainActor
    private func assertFocused(_ app: XCUIApplication, index: Int, total: Int) {
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        assertPage(pager, "\(index + 1) / \(total)")
        let thumbnail = app.buttons["camera.galleryThumbnail.\(index)"]
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(thumbnail.frame.midX - app.frame.midX) < 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        XCTAssertTrue(thumbnail.isSelected)
        XCTAssertEqual(thumbnail.value as? String, "현재 보는 사진")
    }
    @MainActor
    private func assertPage(_ pager: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
