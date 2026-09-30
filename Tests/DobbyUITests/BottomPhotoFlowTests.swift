import XCTest

/// Exercises the system Photos picker and real bundled Core ML provider. The
/// opt-in runner creates a disposable simulator containing two test-owned blank
/// images (one intentionally oversize). This verifies import/error handling,
/// not clothing/point accuracy.
final class BottomPhotoFlowTests: XCTestCase {
    @MainActor
    func testPhotoImportReplacementAndDismissalReset() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOBBY_UI_PHOTO_FIXTURES"] == "1",
                          "Run DOBBY_UI_PHOTO_FIXTURES=1 Tools/run-ui-tests.sh to seed an isolated photo library.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openPhotoRecognition(in: app)

        selectFixture(at: 0, in: app)
        let firstError = awaitPhotoError(in: app)
        XCTAssertTrue(firstError.contains("하의를 찾지 못했습니다") || firstError.contains("사진을 읽을 수 없습니다"), firstError)
        selectFixture(at: 1, in: app)
        // The fixtures deliberately fail at different stages. A second callback
        // must replace the first message; retaining a stale error cannot pass.
        let secondExpected = firstError.contains("하의를 찾지 못했습니다")
            ? "사진을 읽을 수 없습니다" : "하의를 찾지 못했습니다"
        let secondError = awaitPhotoError(in: app, containing: secondExpected)
        XCTAssertNotEqual(firstError, secondError)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "bottom-photo-real-picker-no-detection"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["완료"].tap()
        openPhotoRecognition(in: app)
        XCTAssertTrue(app.otherElements["bottomRecognitionEmpty"].exists
                      || app.staticTexts["하의 사진을 선택해 주세요"].exists)
        XCTAssertFalse(app.staticTexts["bottomRecognitionError"].exists)
        XCTAssertFalse(app.otherElements["bottomRecognitionResult"].exists)
        XCTAssertFalse(app.otherElements["bottomRecognitionStatus"].exists)
    }

    @MainActor
    private func openPhotoRecognition(in app: XCUIApplication) {
        let open = app.buttons["openBottomRecognition"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        for _ in 0 ..< 8 where !open.isHittable { app.swipeUp() }
        open.tap()
        XCTAssertTrue(app.buttons["pickBottomPhoto"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func selectFixture(at index: Int, in app: XCUIApplication) {
        app.buttons["pickBottomPhoto"].tap()
        // iOS 26 exposes photo-grid entries as images, not collection cells.
        // Use its accessibility identifier instead of localized dates/labels.
        // The freshly imported fixtures precede the simulator's stock photos.
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.element(boundBy: index).waitForExistence(timeout: 15), app.debugDescription)
        let photo = photos.element(boundBy: index)
        // Photos' virtual grid exposes image frames but no tappable AX point.
        // Derive the touch from the observed cell frame, never fixed screen pixels.
        XCTAssertFalse(photo.frame.isEmpty)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func awaitPhotoError(in app: XCUIApplication, containing expected: String? = nil) -> String {
        let error = app.staticTexts["bottomRecognitionError"]
        XCTAssertTrue(error.waitForExistence(timeout: 30), app.debugDescription)
        if let expected {
            let updated = expectation(for: NSPredicate(format: "label CONTAINS %@", expected), evaluatedWith: error)
            wait(for: [updated], timeout: 30)
        }
        XCTAssertFalse(app.otherElements["bottomRecognitionStatus"].exists)
        XCTAssertFalse(app.otherElements["bottomRecognitionResult"].exists)
        XCTAssertFalse(app.staticTexts["bottomRecognitionConfidence"].exists)
        return error.label
    }
}
