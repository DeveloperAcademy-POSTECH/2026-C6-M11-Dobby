import XCTest

extension XCTestCase {
    /// Only synthetic capture fixtures expose this explicit recognition
    /// control. Initial-state and unsupported-device tests must opt in to this
    /// helper rather than having navigation silently arm their shutter.
    @MainActor
    func armSyntheticGarmentCapture(in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), file: file, line: line)
        guard shutter.exists else { return }
        if !shutter.isEnabled {
            let recognize = app.buttons["previewRecognizeGarment"]
            XCTAssertTrue(recognize.waitForExistence(timeout: 5),
                          "Only an explicitly synthetic fixture may simulate garment recognition", file: file, line: line)
            guard recognize.exists else { return }
            XCTAssertTrue(recognize.isHittable, file: file, line: line)
            recognize.tap()
        }
        let armed = expectation(for: NSPredicate { _, _ in
            shutter.isEnabled && shutter.isHittable && shutter.value as? String == "촬영 가능"
        }, evaluatedWith: shutter)
        wait(for: [armed], timeout: 10)
        XCTAssertTrue(shutter.isEnabled, file: file, line: line)
        XCTAssertEqual(shutter.value as? String, "촬영 가능", file: file, line: line)
    }

    /// Measurement tests explicitly enable the hidden debug entry. This does
    /// not reset saved measurements, photos, preferences or the clipboard.
    @MainActor
    func launchLiDARLab(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.launchArguments.append("--show-measurement-lab")
        app.launch()
        openLiDARLab(in: app, file: file, line: line)
    }

    @MainActor
    func openLiDARLab(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let entry = app.buttons["openLiDARLab"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Home must expose the measurement lab", file: file, line: line)
        guard entry.exists else { return }
        XCTAssertTrue(entry.isHittable, file: file, line: line)
        entry.tap()
        XCTAssertTrue(app.buttons["closeLiDARLab"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.navigationBars["측정 실험실"].exists, file: file, line: line)
    }

    /// The Hi-Fi window may be wider than a captured image. Verify the actual
    /// aspect-fit photograph rather than rebasing sensor points to its margins.
    @MainActor
    @discardableResult
    func assertAspectFitPhoto(_ photo: XCUIElement, in viewport: XCUIElement,
                              sourceSize: CGSize, file: StaticString = #filePath,
                              line: UInt = #line) -> CGRect {
        let bounds = viewport.frame
        XCTAssertGreaterThan(sourceSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(sourceSize.height, 0, file: file, line: line)
        XCTAssertFalse(bounds.isEmpty, file: file, line: line)
        guard sourceSize.width > 0, sourceSize.height > 0, !bounds.isEmpty else { return .zero }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let expected = CGRect(x: bounds.midX - sourceSize.width * scale / 2,
            y: bounds.midY - sourceSize.height * scale / 2,
            width: sourceSize.width * scale, height: sourceSize.height * scale)
        XCTAssertEqual(photo.frame.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(photo.frame.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(photo.frame.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(photo.frame.height, expected.height, accuracy: 1, file: file, line: line)
        XCTAssertEqual(photo.frame.width / photo.frame.height, sourceSize.width / sourceSize.height,
                       accuracy: 0.001, "The capture must retain its source aspect ratio", file: file, line: line)
        return expected
    }
}
