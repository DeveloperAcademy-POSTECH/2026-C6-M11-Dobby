// Created by mason on 10/19/26.
import XCTest

/// Isolated synthetic fixtures verify navigation and draft retention, not camera accuracy.
final class DetailPhotoBackNavigationUITests: XCTestCase {
    @MainActor
    func testBackRestoresTopAndBottomResultsWithoutReturningHome() {
        for isTop in [true, false] {
            let app = launchResult(isTop: isTop)
            defer { app.terminate() }
            if isTop {
                let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
                let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
                let original = point.value as? String
                let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(
                    CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original ?? ""), object: point)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
            }
            let confirm = app.buttons["confirmGarmentMeasurement"]
            XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 15))
            let labels = measurementLabels(in: app)
            let points = measurementPoints(in: app)
            XCTAssertEqual(labels.count, 4)
            XCTAssertFalse(points.isEmpty)
            confirm.tap()
            waitForDetails(in: app)
            let measurementID = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "실측 사진, 삭제 불가")).firstMatch.identifier
            XCTAssertTrue(measurementID.hasPrefix("camera.detailPhoto."))
            app.buttons["product-flow.backToMeasurement"].tap()
            XCTAssertTrue(app.navigationBars["실측 결과"].waitForExistence(timeout: 10))
            // The presenting home may remain in the accessibility hierarchy behind the cover.
            XCTAssertFalse(app.buttons["product-flow.start"].isHittable)
            XCTAssertFalse(app.buttons["captureGarment"].isHittable)
            XCTAssertEqual(measurementLabels(in: app), labels)
            XCTAssertEqual(measurementPoints(in: app), points)
            XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            confirm.tap()
            waitForDetails(in: app)
            XCTAssertTrue(app.descendants(matching: .any)[measurementID].firstMatch.exists)
            XCTAssertEqual(deleteIDs(in: app).count, 0)
            screenshot(app, name: isTop ? "top-result-round-trip" : "bottom-result-round-trip")
        }
    }

    @MainActor
    func testRepeatedReturnKeepsDetailPhotosSelectionAndRepresentativeAndCanCaptureAgain() {
        let app = launchResult(isTop: true)
        defer { app.terminate() }
        app.buttons["confirmGarmentMeasurement"].tap()
        waitForDetails(in: app)
        captureDetail(in: app)
        captureDetail(in: app)
        let originalIDs = deleteIDs(in: app)
        XCTAssertEqual(originalIDs.count, 2)
        openSelection(in: app)
        // Select a detail as representative, another detail second, measurement last.
        for index in [0, 2, 1, 0] {
            let photo = app.buttons["camera.thumbnail.\(index)"]
            XCTAssertTrue(photo.wait(for: \.isHittable, toEqual: true, timeout: 5))
            photo.tap()
        }
        assertSelection(in: app)
        for _ in 0..<2 {
            app.navigationBars["제품 사진 선택"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["product-flow.backToMeasurement"].waitForExistence(timeout: 5))
            app.buttons["product-flow.backToMeasurement"].tap()
            XCTAssertTrue(app.navigationBars["실측 결과"].waitForExistence(timeout: 10))
            let confirm = app.buttons["confirmGarmentMeasurement"]
            XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            confirm.tap()
            waitForDetails(in: app)
            XCTAssertEqual(deleteIDs(in: app), originalIDs)
            openSelection(in: app)
            assertSelection(in: app)
        }
        let carousel = app.scrollViews["camera.photoCarousel"]
        carousel.swipeLeft()
        carousel.swipeLeft()
        let representative = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND value == %@", "상세 사진", "대표 사진")).firstMatch
        XCTAssertTrue(representative.waitForExistence(timeout: 5))
        screenshot(app, name: "selected-detail-representative-after-two-returns")
        app.navigationBars["제품 사진 선택"].buttons.element(boundBy: 0).tap()
        captureDetail(in: app)
        XCTAssertEqual(deleteIDs(in: app).count, 3)
        XCTAssertTrue(Set(originalIDs).isSubset(of: Set(deleteIDs(in: app))))
        openSelection(in: app)
        assertSelection(in: app)
        XCTAssertEqual(app.buttons["camera.thumbnail.3"].value as? String, "선택 안 됨")
        app.buttons["camera.completePhotos"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchResult(isTop: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        if isTop { app.launchArguments.append("--garment-preview-top") }
        app.launch()
        let start = app.buttons["product-flow.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let capture = app.buttons["captureGarment"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        capture.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func waitForDetails(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["제품 상세 촬영"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["camera.captureDetail"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    }

    @MainActor
    private func captureDetail(in app: XCUIApplication) {
        let count = deleteIDs(in: app).count
        let shutter = app.buttons["camera.captureDetail"]
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        shutter.tap()
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.deletePhoto."))
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count + 1), object: deletes)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 10), .completed)
        XCTAssertTrue(shutter.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    }

    @MainActor
    private func openSelection(in app: XCUIApplication) {
        let choose = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        choose.tap()
        XCTAssertTrue(app.scrollViews["camera.selectionStrip"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertSelection(in app: XCUIApplication) {
        for (index, order) in [(2, 1), (1, 2), (0, 3)] {
            XCTAssertEqual(app.buttons["camera.thumbnail.\(index)"].value as? String, "\(order)번째 선택")
        }
        XCTAssertEqual(app.buttons["camera.completePhotos"].value as? String, "3장 선택 · 최소 1장")
        XCTAssertLessThan(app.buttons["camera.thumbnail.2"].frame.minX, app.buttons["camera.thumbnail.1"].frame.minX)
        XCTAssertLessThan(app.buttons["camera.thumbnail.1"].frame.minX, app.buttons["camera.thumbnail.0"].frame.minX)
    }

    @MainActor
    private func deleteIDs(in app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.deletePhoto."))
            .allElementsBoundByIndex.map(\.identifier)
    }

    @MainActor
    private func measurementLabels(in app: XCUIApplication) -> [String: String] {
        Dictionary(uniqueKeysWithValues: app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex.map { ($0.identifier, $0.label) })
    }

    @MainActor
    private func measurementPoints(in app: XCUIApplication) -> [String: String] {
        Dictionary(uniqueKeysWithValues: app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "garmentMeasurementPoint_")).allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") })
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
