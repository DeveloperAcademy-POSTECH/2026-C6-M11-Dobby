import XCTest
import UIKit

/// Synthetic fixtures verify Hi-Fi composition and navigation only. They do
/// not establish garment recognition, camera levelling or physical accuracy.
final class GarmentHiFiUITests: XCTestCase {
    @MainActor
    func testCapturePhotoWindowAndResultPreserveTheCapturedPhotoCoordinates() throws {
        continueAfterFailure = false
        let app = openPreview()
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        let shutter = app.buttons["captureGarment"]
        let zoom = app.buttons["cameraZoomSelector"]
        let back = app.buttons["closeGarmentCapture"]
        XCTAssertEqual(guidance.label, "옷이 잘리지 않게 카메라 안에 넣어주세요")
        XCTAssertEqual(zoom.value as? String, "1x")
        XCTAssertFalse(shutter.isEnabled, "The shutter must wait for the recognized orange-ready state")
        XCTAssertEqual(shutter.value as? String, "옷 인식 대기")
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.width, 44, accuracy: 1)
        XCTAssertEqual(back.frame.height, 44, accuracy: 1)
        XCTAssertTrue(app.frame.contains(back.frame))
        XCTAssertFalse(app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        if app.frame.width == 402 && app.frame.height == 874 {
            XCTAssertEqual(viewport.frame.minX, app.frame.minX, accuracy: 1)
            // The complete 800×1000 fixture fits between the 146-point top
            // and 192-point bottom chrome, retaining its own 4:5 aspect.
            XCTAssertEqual(viewport.frame.minY, app.frame.minY + 162.75, accuracy: 1)
            XCTAssertEqual(viewport.frame.width, 402, accuracy: 1)
            XCTAssertEqual(viewport.frame.height, 502.5, accuracy: 1)
            XCTAssertEqual(guidance.frame.minY, app.frame.minY + 560, accuracy: 1)
            XCTAssertEqual(guidance.frame.height, 40, accuracy: 1)
            XCTAssertEqual(zoom.frame.minY, app.frame.minY + 617, accuracy: 1)
            XCTAssertEqual(zoom.frame.width, 48, accuracy: 1)
            XCTAssertEqual(zoom.frame.height, 48, accuracy: 1)
            // Match detail capture: 34pt bottom safe area + half of its 114pt row.
            XCTAssertEqual(shutter.frame.minY, app.frame.minY + 737, accuracy: 1)
            XCTAssertEqual(shutter.frame.width, 92, accuracy: 1)
            XCTAssertEqual(shutter.frame.height, 92, accuracy: 1)
            XCTAssertLessThanOrEqual(back.frame.maxY, app.frame.minY + 146)
        }
        screenshot("hifi96-capture-before-recognition")
        recognizeGarment(in: app)
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        XCTAssertEqual(confirm.label, "다음")
        let resultViewport = app.descendants(matching: .any)["garmentResultPhotoViewport"].firstMatch
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(resultViewport.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.exists)
        let sourceRect = assertAspectFitPhoto(photo, in: resultViewport, sourceSize: .init(width: 800, height: 1000))
        let shoulder = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(shoulder.isHittable)
        XCTAssertEqual(shoulder.frame.midX, sourceRect.minX + sourceRect.width * 0.30, accuracy: 1)
        XCTAssertEqual(shoulder.frame.midY, sourceRect.minY + sourceRect.height * 0.23, accuracy: 1)
        XCTAssertFalse(app.buttons["dismissGarmentResultTutorial"].exists)
        if app.frame.width == 402 && app.frame.height == 874 {
            XCTAssertEqual(resultViewport.frame.minX, app.frame.minX, accuracy: 1)
            XCTAssertEqual(resultViewport.frame.width, 402, accuracy: 1)
            XCTAssertEqual(resultViewport.frame.height, 536, accuracy: 1)
            XCTAssertEqual(confirm.frame.minX, app.frame.minX + 32, accuracy: 1)
            XCTAssertEqual(confirm.frame.minY, app.frame.minY + 778, accuracy: 1)
            XCTAssertEqual(confirm.frame.width, 335, accuracy: 1)
            XCTAssertEqual(confirm.frame.height, 62, accuracy: 1)
        }
        screenshot("hifi96-result-source-coordinates")
    }

    @MainActor
    func testCaptureTutorialAndDetailOptionsKeepRecognitionRequiredForTheShutter() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-capture-tutorial"])
        let tutorial = app.descendants(matching: .any)["garmentCaptureTutorial"].firstMatch
        let checkbox = app.descendants(matching: .any)["skipGarmentCaptureTutorial"].firstMatch
        let continueButton = app.buttons["continueGarmentCaptureTutorial"]
        XCTAssertTrue(tutorial.waitForExistence(timeout: 5))
        XCTAssertTrue(checkbox.isHittable && continueButton.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentCaptureTutorialShirt"].firstMatch.exists)
        let originalSelection = try XCTUnwrap(checkbox.value as? String)
        checkbox.tap()
        waitUntil { (checkbox.value as? String).map { $0 != originalSelection } == true }
        screenshot("hifi96-capture-tutorial")
        continueButton.tap()
        waitUntil { !tutorial.exists }
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(shutter.isEnabled, "Closing a tutorial must not bypass garment recognition")
        XCTAssertEqual(shutter.value as? String, "옷 인식 대기")
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        let options = app.buttons["garmentCaptureOptions"]
        XCTAssertTrue(options.isHittable)
        options.tap()
        XCTAssertTrue(app.buttons["camera.exposureOption"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["camera.aspectRatioOption"].exists)
        XCTAssertFalse(app.buttons["replayGarmentCaptureTutorial"].exists)
        app.buttons["camera.closeOptions"].tap()
        waitUntil { !app.descendants(matching: .any)["camera.optionsMenu"].firstMatch.exists }
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertEqual(shutter.value as? String, "옷 인식 대기")
        recognizeGarment(in: app)
        shutter.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testResultPointsAreImmediatelyEditableAndGuideDoesNotAppearAfterDragging() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-result-tutorial"])
        recognizeGarment(in: app)
        app.buttons["captureGarment"].tap()
        let dismissTutorial = app.buttons["dismissGarmentResultTutorial"]
        let confirm = app.buttons["confirmGarmentMeasurement"]
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(dismissTutorial.exists, "Result entry must allow editing without dismissing a guide")
        XCTAssertTrue(confirm.isHittable && confirm.isEnabled)
        XCTAssertTrue(point.waitForExistence(timeout: 5),
                      "Missing result point: \(point.debugDescription)\nButtons: \(app.buttons.debugDescription)")
        XCTAssertTrue(point.isEnabled)
        let pointState = XCTAttachment(string:
            "frame: \(point.frame), hittable: \(point.isHittable), enabled: \(point.isEnabled)")
        pointState.name = "result-point-before-drag"
        pointState.lifetime = .keepAlways
        add(pointState)
        screenshot("hifi96-result-immediate-point-editing")
        let original = try XCTUnwrap(point.value as? String)
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 8, dy: 5)))
        waitUntil { point.value as? String != original && confirm.isEnabled }
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        XCTAssertFalse(app.buttons["garmentResultActions"].exists)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertFalse(dismissTutorial.exists, "Finishing a point drag must not replay the result guide")
        screenshot("hifi96-result-after-point-edit")
    }

    @MainActor
    func testLevelGuidanceDoesNotBypassTheRecognitionShutterGate() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-level-guide"])
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        XCTAssertEqual(guidance.label, "핸드폰을 수평으로 들어주세요")
        XCTAssertTrue(app.descendants(matching: .any)["garmentCameraLevelGuide"].firstMatch.exists)
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(shutter.isEnabled, "Level guidance alone must not arm the shutter")
        XCTAssertEqual(shutter.value as? String, "옷 인식 대기")
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        screenshot("hifi96-level-guidance")
        recognizeGarment(in: app)
        shutter.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testMatchedCaptureFramingKeepsWhiteResultMarginsAndOriginalPointEdits() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-matched-framing"])
        let shutter = app.buttons["captureGarment"]
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertEqual(shutter.value as? String, "옷 인식 대기")
        recognizeGarment(in: app)
        screenshot("matched-framing-capture-visible-photo")
        shutter.tap()

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let viewport = app.descendants(matching: .any)["garmentResultPhotoViewport"].firstMatch
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let shoulder = app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"]
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertTrue(viewport.exists && photo.exists && point.isHittable)
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        XCTAssertFalse(magnifier.exists)
        let original = try XCTUnwrap(Self.pointCoordinates(in: point.value as? String))
        XCTAssertEqual(original.x, 0.30, accuracy: 0.0001,
                       "A presentation crop must not rewrite the captured sensor point")
        XCTAssertEqual(original.y, 0.23, accuracy: 0.0001)
        // The camera now shows the complete source photo. The opt-in legacy
        // matched-framing flag must not reintroduce a second presentation crop.
        let expectedPhoto = assertAspectFitPhoto(photo, in: viewport,
            sourceSize: .init(width: 800, height: 1000))
        XCTAssertEqual(point.frame.midX,
            expectedPhoto.minX + original.x * expectedPhoto.width, accuracy: 1)
        XCTAssertEqual(point.frame.midY,
            expectedPhoto.minY + original.y * expectedPhoto.height, accuracy: 1)
        XCTAssertTrue(photo.frame.contains(CGPoint(x: point.frame.midX, y: point.frame.midY)))
        let initialShoulder = try XCTUnwrap(Self.measurementCentimeters(in: shoulder.label))

        let resultScreen = XCUIScreen.main.screenshot().image
        try assertWhitePixel(in: resultScreen,
            at: CGPoint(x: app.frame.minX + 8, y: viewport.frame.minY - 8), screen: app.frame)
        try assertWhitePixel(in: resultScreen,
            at: CGPoint(x: app.frame.minX + 8, y: confirm.frame.midY), screen: app.frame)
        try assertWhitePixel(in: resultScreen,
            at: CGPoint(x: app.frame.minX + 8, y: app.frame.maxY - 8), screen: app.frame)
        screenshot("matched-framing-result-white-margins")

        let originalCenter = CGPoint(x: point.frame.midX, y: point.frame.midY)
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 12, dy: 6)))
        waitUntil {
            point.value as? String != String(format: "x %.4f, y %.4f", original.x, original.y)
                && confirm.isEnabled
        }
        let edited = try XCTUnwrap(Self.pointCoordinates(in: point.value as? String))
        XCTAssertGreaterThan(edited.x, original.x)
        XCTAssertGreaterThan(edited.y, original.y)
        XCTAssertLessThan(edited.x, 1)
        XCTAssertLessThan(edited.y, 1)
        XCTAssertEqual(edited.x - original.x, 12 / photo.frame.width, accuracy: 0.002,
                       "Drag translation must retain the complete source photo's coordinate grid")
        XCTAssertEqual(edited.y - original.y, 6 / photo.frame.height, accuracy: 0.002)
        XCTAssertEqual(point.frame.midX, originalCenter.x + 12, accuracy: 3)
        XCTAssertEqual(point.frame.midY, originalCenter.y + 6, accuracy: 3)
        XCTAssertFalse(magnifier.exists, "Finger-up must hide the loupe after editing the full source photo")
        waitUntil {
            Self.measurementCentimeters(in: shoulder.label).map { $0 != initialShoulder } == true
                && confirm.isEnabled
        }
        let editedShoulder = try XCTUnwrap(Self.measurementCentimeters(in: shoulder.label))
        screenshot("matched-framing-result-after-original-point-edit")
        confirm.tap()
        XCTAssertTrue(app.buttons["openGarmentPreview"].waitForExistence(timeout: 10))

        app.terminate()
        launchLiDARLab(app)
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "어깨너비 · 데모")).firstMatch
        revealArchiveElement(record, in: app)
        XCTAssertTrue(record.exists && record.isHittable)
        record.tap()
        let replayed = app.staticTexts["automaticValue_top.shoulderWidth"]
        XCTAssertTrue(replayed.waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(Self.measurementCentimeters(in: replayed.label)), editedShoulder,
                       accuracy: 0.51, "Saving and reopening must retain the edited measurement")
        let provenance = app.descendants(matching: .any)["automaticPointAdjustmentProvenance"].firstMatch
        XCTAssertTrue(provenance.exists && provenance.label.contains("수동"))
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
    }

    @MainActor
    private func assertWhitePixel(in image: UIImage, at point: CGPoint, screen: CGRect,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let x = Int((point.x - screen.minX) * CGFloat(cgImage.width) / screen.width)
        let y = Int((point.y - screen.minY) * CGFloat(cgImage.height) / screen.height)
        let pixel = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
                                 file: file, line: line)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(rgba[0], 250, "Result margin must be white at \(point)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rgba[1], 250, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rgba[2], 250, file: file, line: line)
        XCTAssertEqual(rgba[3], 255, file: file, line: line)
    }

    private static func pointCoordinates(in text: String?) -> CGPoint? {
        guard let text else { return nil }
        let pieces = text.split { $0 == " " || $0 == "," }
        guard pieces.count == 4, pieces[0] == "x", pieces[2] == "y",
              let x = Double(pieces[1]), let y = Double(pieces[3]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func measurementCentimeters(in text: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*cm"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    @MainActor
    private func revealArchiveElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }

    @MainActor
    private func recognizeGarment(in app: XCUIApplication) {
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        if !shutter.isEnabled {
            let recognize = app.buttons["previewRecognizeGarment"]
            XCTAssertTrue(recognize.waitForExistence(timeout: 5))
            XCTAssertTrue(recognize.isHittable)
            recognize.tap()
        }
        waitUntil { shutter.isEnabled && shutter.isHittable }
        XCTAssertEqual(shutter.value as? String, "촬영 가능")
    }

    @MainActor
    private func openPreview(arguments: [String] = ["--garment-preview-top"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        let firstAction = arguments.contains("--garment-preview-capture-tutorial")
            ? app.buttons["continueGarmentCaptureTutorial"] : app.buttons["captureGarment"]
        XCTAssertTrue(firstAction.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) {
        expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
