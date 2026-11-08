// Created by mason on 11/8/26.
import XCTest

final class DetailCaptureInformationHandoffUITests: XCTestCase {
    @MainActor
    func testNextSkipsSelectionAndRevisitKeepsAllCapturedPhotos() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        defer { app.terminate() }
        tap(app, "product-flow.start")
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        tap(app, "camera.captureDetail")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 4) // 원본 + 실측 표시본 + 상세 2장

        tap(app, "product-flow.back")
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews["camera.selectionGrid"].exists)
        tap(app, "camera.openGallery")
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        XCTAssertEqual(pager.value as? String, "4 / 4")
        tap(app, "촬영으로 돌아가기")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 5)
    }

    @MainActor
    private func assertInformation(_ app: XCUIApplication, count: Int) {
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.scrollViews["camera.selectionGrid"].exists)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
        XCTAssertEqual(photos.count, count)
        XCTAssertFalse(app.staticTexts["product-info.photos.empty"].exists)
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), identifier)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }
}
