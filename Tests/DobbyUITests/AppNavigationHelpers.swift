import XCTest

extension XCTestCase {
    /// Handles both legacy sensor descriptions and the photo-relative spoken
    /// coordinates used by VoiceOver. The latter are normalized after parsing.
    nonisolated static func measurementPhotoCoordinates(in text: String) -> CGPoint? {
        let pattern = #"사진 가로 ([0-9]+(?:\.[0-9]+)?)퍼센트, 세로 ([0-9]+(?:\.[0-9]+)?)퍼센트"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let xRange = Range(match.range(at: 1), in: text),
           let yRange = Range(match.range(at: 2), in: text),
           let x = Double(text[xRange]), let y = Double(text[yRange]) {
            return CGPoint(x: x / 100, y: y / 100)
        }
        let pieces = text.split { $0 == " " || $0 == "," }
        guard pieces.count == 4, pieces[0] == "x", pieces[2] == "y",
              let x = Double(pieces[1]), let y = Double(pieces[3]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The home tape starts capture after a deliberate downward pull.
    @MainActor
    func startMeasurementFromHome(in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let entry = app.buttons["product-flow.start"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertTrue(entry.isHittable, file: file, line: line)
        let start = entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = min(230, max(0, app.frame.maxY - 90 - entry.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 15), file: file, line: line)
    }

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
