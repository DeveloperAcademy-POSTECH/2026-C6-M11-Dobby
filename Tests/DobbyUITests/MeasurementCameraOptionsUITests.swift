import XCTest
import UIKit

/// Explicit synthetic photos and control receipts verify interaction, displayed
/// pixels and coordinate preservation, never optical exposure or LiDAR accuracy.
final class MeasurementCameraOptionsUITests: XCTestCase {
    @MainActor
    func testOptionsReplaceControlsWithoutMovingThePhotoAndOutsideTapClosesEveryPanel() throws {
        continueAfterFailure = false
        let app = openPreview()
        armSyntheticGarmentCapture(in: app)
        let viewport = photoViewport(in: app)
        let original = viewport.frame
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.isEnabled)

        openOptions(in: app)
        assertFrame(viewport.frame, equals: original)
        XCTAssertFalse(shutter.exists, "The hidden shutter must not remain an accessible capture action")
        XCTAssertFalse(app.buttons["cameraZoomSelector"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["captureGuidance"].firstMatch.exists)
        XCTAssertTrue(app.buttons["camera.exposureOption"].isEnabled)
        XCTAssertTrue(app.buttons["camera.aspectRatioOption"].isEnabled)
        XCTAssertFalse(app.buttons["replayGarmentCaptureTutorial"].exists)
        attach(name: "measurement-options-menu-over-unchanged-photo")

        app.buttons["camera.exposureOption"].tap()
        assertPanel("camera.exposurePanel", fits: app)
        closeByOutsideTap(in: app)
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        assertFrame(viewport.frame, equals: original)

        openOptions(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["camera.exposurePanel"].firstMatch.exists,
                       "Opening More again starts at its menu, not the previous child panel")
        app.buttons["camera.closeOptions"].tap()
        waitUntil { !app.descendants(matching: .any)["camera.optionsMenu"].firstMatch.exists }
        shutter.tap()
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testExposureMenuAndTapFocusShareAcceptedEVAndRapidRulerRequestsCanReset() throws {
        continueAfterFailure = false
        let app = openPreview()
        openOptions(in: app)
        app.buttons["camera.exposureOption"].tap()
        assertPanel("camera.exposurePanel", fits: app)
        let value = app.staticTexts["camera.exposureValue"]
        let ruler = app.descendants(matching: .any)["camera.exposureRuler"].firstMatch
        waitUntil { Self.number(in: value.label) == 0 }
        drag(ruler, horizontally: -80)
        waitUntil { Self.number(in: value.label).map { $0 > 0 } == true }
        attach(name: "measurement-options-positive-exposure")

        app.buttons["camera.exposureBack"].tap()
        assertPanel("camera.optionsMenu", fits: app)
        app.buttons["camera.closeOptions"].tap()
        let viewport = photoViewport(in: app)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        let focusExposure = app.descendants(matching: .any)["cameraExposureControl"].firstMatch
        XCTAssertTrue(focusExposure.waitForExistence(timeout: 3))
        waitUntil { focusExposure.value as? String == "EV +0.0" }

        openOptions(in: app)
        app.buttons["camera.exposureOption"].tap()
        assertPanel("camera.exposurePanel", fits: app)
        waitUntil { Self.number(in: value.label) == 0 }
        // Alternating real pan events exercise queued receipts and the final
        // requested value without assuming XCTest's complete delivered distance.
        for distance in [CGFloat(-70), 110, -60] { drag(ruler, horizontally: distance) }
        let reset = app.buttons["camera.exposureReset"]
        if Self.number(in: value.label) == 0 { drag(ruler, horizontally: -70) }
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()
        waitUntil { Self.number(in: value.label) == 0 }
        XCTAssertFalse(app.staticTexts["camera.exposureError"].exists)
        closeByOutsideTap(in: app)
        openOptions(in: app)
        app.buttons["camera.exposureOption"].tap()
        waitUntil { Self.number(in: value.label) == 0 }
        attach(name: "measurement-options-reset-exposure-survives-reopen")
    }

    @MainActor
    func testDetailStyleExposureIndicatorAndSaturatedDragsRemainResponsive() throws {
        continueAfterFailure = false
        let app = openPreview()
        openOptions(in: app)
        app.buttons["camera.exposureOption"].tap()
        assertPanel("camera.exposurePanel", fits: app)
        let ruler = app.descendants(matching: .any)["camera.exposureRuler"].firstMatch
        let value = app.staticTexts["camera.exposureValue"]
        let idle = XCUIScreen.main.screenshot()
        let idleHeight = try indicatorHeight(in: idle.image, ruler: ruler.frame, screen: app.frame)
        XCTAssertTrue((26...30).contains(idleHeight), "The marker uses detail capture's fixed 28pt height")
        attach(idle, name: "measurement-exposure-indicator-before-touch")

        // Detail capture keeps the marker height fixed during adjustment.
        // Haptic sensation requires an actual iPhone separately.
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.8)
        waitUntil { Self.number(in: value.label).map { $0 > 0.9 } == true }
        for _ in 0..<2 { drag(ruler, horizontally: -140) }
        waitUntil { Self.number(in: value.label) == 2 }
        let released = XCUIScreen.main.screenshot()
        let releasedHeight = try indicatorHeight(in: released.image, ruler: ruler.frame, screen: app.frame)
        XCTAssertEqual(releasedHeight, idleHeight, accuracy: 1,
                       "The detail-style marker stays the same height after a completed gesture")
        attach(released, name: "measurement-exposure-indicator-released-at-limit")
        drag(ruler, horizontally: 80)
        waitUntil { Self.number(in: value.label).map { $0 < 1.6 } == true }
        app.buttons["camera.exposureReset"].tap()
        waitUntil { Self.number(in: value.label) == 0 }
        XCTAssertFalse(app.staticTexts["camera.exposureError"].exists)
    }

    @MainActor
    func testAllAspectRatiosChangeOnlyThePhotoWindowAndPersistAcrossMenuReopening() throws {
        continueAfterFailure = false
        let app = openPreview()
        let ratios: [(String, CGFloat)] = [("1:1", 1), ("16:9", 9.0 / 16), ("4:3", 0.8)]
        for (ratio, displayAspect) in ratios {
            openOptions(in: app)
            app.buttons["camera.aspectRatioOption"].tap()
            assertPanel("camera.aspectRatioPanel", fits: app)
            app.buttons["camera.aspectRatio.\(ratio)"].tap()
            let expected = expectedPhotoRect(in: app.frame, aspect: displayAspect)
            waitUntil { Self.framesMatch(self.photoViewport(in: app).frame, expected) }
            XCTAssertEqual(app.staticTexts["camera.aspectRatioValue"].label, ratio)
            attach(name: "measurement-options-ratio-\(ratio.replacingOccurrences(of: ":", with: "-"))")
            app.buttons["camera.aspectRatioBack"].tap()
            assertPanel("camera.optionsMenu", fits: app)
            XCTAssertTrue(app.buttons["camera.aspectRatioOption"].value as? String == ratio)
            closeByOutsideTap(in: app)
            assertFrame(photoViewport(in: app).frame, equals: expected)
            armSyntheticGarmentCapture(in: app)
            XCTAssertTrue(app.buttons["captureGarment"].isEnabled)
        }
    }

    @MainActor
    func testSelectedRatioKeepsProcessingPixelsAndExpandsResultToPreserveEditableOutsidePoints() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-processing",
            "--garment-preview-no-outline", "--garment-preview-matched-framing"])
        openOptions(in: app)
        app.buttons["camera.aspectRatioOption"].tap()
        app.buttons["camera.aspectRatio.16:9"].tap()
        let expected = expectedPhotoRect(in: app.frame, aspect: 9.0 / 16)
        waitUntil { Self.framesMatch(self.photoViewport(in: app).frame, expected) }
        closeByOutsideTap(in: app)
        armSyntheticGarmentCapture(in: app)
        let liveRect = photoViewport(in: app).frame
        let live = XCUIScreen.main.screenshot()
        app.buttons["captureGarment"].tap()
        let frozen = app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch
        XCTAssertTrue(frozen.waitForExistence(timeout: 5))
        let frozenRect = frozen.frame
        let processing = XCUIScreen.main.screenshot()
        assertFrame(frozenRect, equals: liveRect)
        attach(live, name: "measurement-ratio-before-capture")
        attach(processing, name: "measurement-ratio-frozen-processing")

        // The narrow 9:16 window maps these upper side probes to source
        // background, below the progress capsule and outside the neckline.
        let sites = [CGPoint(x: 0.20, y: 0.18), CGPoint(x: 0.80, y: 0.18),
                     CGPoint(x: 0.35, y: 0.46), CGPoint(x: 0.50, y: 0.60)]
        var colors: [[Int]] = []
        for site in sites {
            let before = try rgbSample(in: live.image, at: position(site, in: liveRect), screen: app.frame)
            let after = try rgbSample(in: processing.image, at: position(site, in: frozenRect), screen: app.frame)
            colors.append(before)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(before[channel] - after[channel]), 8,
                    "The selected crop must remain at the same source pixels during analysis")
            }
        }
        XCTAssertGreaterThan(colors[0][0] - colors[3][0], 35,
                             "Compare both garment and background, not matching blank images")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let notice = app.descendants(matching: .any)["garmentExpandedPhotoNotice"].firstMatch
        XCTAssertFalse(notice.exists, "The expanded photo must not introduce an unsolicited notice")
        XCTAssertFalse(app.descendants(matching: .any)["garmentUnavailableNotice"].firstMatch.exists,
                       "Expanding presentation to retain points is not a measurement failure")
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        for id in ["shoulder_left", "shoulder_right", "sleeve_end_left"] {
            let point = app.buttons["garmentMeasurementPoint_\(id)"]
            XCTAssertTrue(point.exists && point.isHittable, "A normal \(id) point must not be discarded")
            XCTAssertTrue(photo.frame.contains(CGPoint(x: point.frame.midX, y: point.frame.midY)))
        }
        let shoulder = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let original = try XCTUnwrap(shoulder.value as? String)
        let start = shoulder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 12, dy: 12)))
        waitUntil { shoulder.value as? String != original && confirm.isEnabled }
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        XCTAssertFalse(notice.exists)
        attach(name: "measurement-ratio-expanded-result-points-remain-editable")
    }

    @MainActor
    func testResultPanelBodyDragAndHandleRestoreKeepPhotoAndPointsUnchanged() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-no-outline",
                                           "--garment-preview-matched-framing"])
        openOptions(in: app)
        app.buttons["camera.aspectRatioOption"].tap()
        app.buttons["camera.aspectRatio.16:9"].tap()
        XCTAssertEqual(app.staticTexts["camera.aspectRatioValue"].label, "16:9")
        app.buttons["camera.aspectRatioBack"].tap()
        app.buttons["camera.closeOptions"].tap()
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["garmentExpandedPhotoNotice"].firstMatch.exists)
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        let sheet = app.descendants(matching: .any)["garmentResultMeasurementSheet"].firstMatch
        let handle = app.descendants(matching: .any)["garmentResultSheetHandle"].firstMatch
        attach(name: "measurement-result-panel-before-body-scroll")
        XCTAssertTrue(sheet.exists && handle.exists)
        let originalPhotoFrame = photo.frame
        let originalPointValue = app.buttons["garmentMeasurementPoint_shoulder_left"].value as? String
        // Start on a card, outside the 28pt grabber, to cover scrolling the
        // panel body rather than only dragging its narrow handle.
        let panelStart = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        panelStart.press(forDuration: 0.05, thenDragTo: panelStart.withOffset(CGVector(dx: 0, dy: 150)),
                         withVelocity: .slow, thenHoldForDuration: 0)
        waitUntil { handle.value as? String == "접힘" }
        let handleStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handleStart.press(forDuration: 0.05, thenDragTo: handleStart.withOffset(CGVector(dx: 0, dy: -150)),
                          withVelocity: .slow, thenHoldForDuration: 0)
        waitUntil { handle.value as? String == "펼쳐짐" }
        assertFrame(photo.frame, equals: originalPhotoFrame)
        XCTAssertEqual(app.buttons["garmentMeasurementPoint_shoulder_left"].value as? String, originalPointValue)
        let sideways = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        sideways.press(forDuration: 0.05, thenDragTo: sideways.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertEqual(handle.value as? String, "펼쳐짐", "Horizontal scrolling must not collapse the panel")
        attach(name: "measurement-result-panel-body-scroll-restored")
    }

    @MainActor
    func testZoomFollowsTheSelectedPhotoWhileShutterAndMoreStayFixed() throws {
        continueAfterFailure = false
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-no-outline"])
        let shutter = app.buttons["captureGarment"]
        let more = app.buttons["garmentCaptureOptions"]
        let zoom = app.buttons["cameraZoomSelector"]
        let fixedShutter = shutter.frame
        let fixedMore = more.frame
        if app.frame.width == 402 && app.frame.height == 874 {
            XCTAssertEqual(fixedShutter.midY, app.frame.minY + 718, accuracy: 1,
                           "The shared shutter row is raised above the 16:9 edge")
        }
        var centers: [String: CGFloat] = [:]
        for (label, aspect) in [("1:1", CGFloat(1)), ("16:9", 9.0 / 16), ("4:3", 0.8)] {
            more.tap()
            app.buttons["camera.aspectRatioOption"].tap()
            app.buttons["camera.aspectRatio.\(label)"].tap()
            app.buttons["camera.aspectRatioBack"].tap()
            app.buttons["camera.closeOptions"].tap()
            let expected = expectedPhotoRect(in: app.frame, aspect: aspect)
            let expectedZoomY = min(expected.maxY - 40,
                min(app.frame.maxY - 192 - 12 - 24, fixedShutter.minY - 12 - 24))
            waitUntil {
                Self.framesMatch(self.photoViewport(in: app).frame, expected)
                    && abs(zoom.frame.midY - expectedZoomY) <= 1
            }
            assertFrame(shutter.frame, equals: fixedShutter)
            assertFrame(more.frame, equals: fixedMore)
            XCTAssertTrue(zoom.isHittable)
            XCTAssertTrue(expected.contains(CGPoint(x: zoom.frame.midX, y: zoom.frame.midY)))
            XCTAssertLessThan(zoom.frame.maxY, shutter.frame.minY)
            XCTAssertGreaterThanOrEqual(distanceToBorder(from: CGPoint(x: fixedShutter.midX, y: fixedShutter.midY),
                rectangle: expected), fixedShutter.width / 2 + 7,
                "No selected photo edge may cross or touch the fixed circular shutter")
            centers[label] = zoom.frame.midY
            if label == "16:9" {
                XCTAssertEqual(expected.width, app.frame.width, accuracy: 1)
                XCTAssertTrue(expected.contains(CGPoint(x: shutter.frame.midX, y: shutter.frame.midY)),
                    "The tall photograph should continue behind the fixed shutter")
            }
            attach(name: "camera-regular-glass-responsive-\(label.replacingOccurrences(of: ":", with: "-"))")
        }
        XCTAssertLessThan(try XCTUnwrap(centers["1:1"]), try XCTUnwrap(centers["4:3"]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(centers["4:3"]), try XCTUnwrap(centers["16:9"]))
    }

    @MainActor
    func testReducedMotionLandscapeOptionsFitAndReturnToCaptureAfterPanelBackAndOutsideDismissal() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openPreview(arguments: ["--garment-preview-top", "--garment-preview-reduce-motion"])
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        let original = photoViewport(in: app).frame
        openOptions(in: app)
        assertFrame(photoViewport(in: app).frame, equals: original)
        app.buttons["camera.exposureOption"].tap()
        assertPanel("camera.exposurePanel", fits: app)
        app.buttons["camera.exposureBack"].tap()
        assertPanel("camera.optionsMenu", fits: app)
        app.buttons["camera.aspectRatioOption"].tap()
        assertPanel("camera.aspectRatioPanel", fits: app)
        app.buttons["camera.aspectRatio.1:1"].tap()
        waitUntil { abs(self.photoViewport(in: app).frame.width / self.photoViewport(in: app).frame.height - 1) < 0.001 }
        attach(name: "measurement-options-landscape-reduced-motion-square")
        closeByOutsideTap(in: app)
        openOptions(in: app)
        XCTAssertTrue(app.buttons["camera.exposureOption"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["camera.aspectRatioPanel"].firstMatch.exists)
        app.buttons["camera.closeOptions"].tap()
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func openPreview(arguments: [String] = ["--garment-preview-top"]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openOptions(in app: XCUIApplication) {
        let more = app.buttons["garmentCaptureOptions"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(more.isHittable)
        more.tap()
        assertPanel("camera.optionsMenu", fits: app)
    }

    @MainActor
    private func closeByOutsideTap(in app: XCUIApplication) {
        let backdrop = app.buttons["camera.dismissOptions"]
        XCTAssertTrue(backdrop.waitForExistence(timeout: 3))
        backdrop.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["garmentCaptureOptions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["camera.optionsMenu"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["camera.exposurePanel"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["camera.aspectRatioPanel"].firstMatch.exists)
    }

    @MainActor
    private func photoViewport(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
    }

    @MainActor
    private func assertPanel(_ identifier: String, fits app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let panel = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertGreaterThan(panel.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThan(panel.frame.height, 44, file: file, line: line)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(panel.frame),
                      "\(identifier) must stay inside the screen", file: file, line: line)
    }

    @MainActor
    private func drag(_ ruler: XCUIElement, horizontally distance: CGFloat) {
        XCTAssertTrue(ruler.isHittable)
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))
    }

    private func expectedPhotoRect(in screen: CGRect, aspect: CGFloat) -> CGRect {
        let maximumHeight = min(screen.width * 16 / 9, screen.height - 120)
        let height = min(maximumHeight, screen.width / aspect)
        let width = height * aspect
        return CGRect(x: screen.midX - width / 2,
            y: screen.minY + 60 + (maximumHeight - height) * 0.375, width: width, height: height)
    }

    private func distanceToBorder(from point: CGPoint, rectangle: CGRect) -> CGFloat {
        let corners = [CGPoint(x: rectangle.minX, y: rectangle.minY),
                       CGPoint(x: rectangle.maxX, y: rectangle.minY),
                       CGPoint(x: rectangle.maxX, y: rectangle.maxY),
                       CGPoint(x: rectangle.minX, y: rectangle.maxY)]
        return (0..<4).map { index -> CGFloat in
            let a = corners[index], b = corners[(index + 1) % 4]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let projection = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            return hypot(point.x - (a.x + projection * dx), point.y - (a.y + projection * dy))
        }.min() ?? 0
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Self.framesMatch(actual, expected),
                      "Expected \(expected), got \(actual)", file: file, line: line)
    }

    nonisolated private static func framesMatch(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1
            && abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
    }

    nonisolated private static func number(in text: String) -> Double? {
        Double(text.replacingOccurrences(of: "EV", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func position(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    @MainActor
    private func indicatorHeight(in image: UIImage, ruler: CGRect, screen: CGRect) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        let sx = CGFloat(cg.width) / screen.width, sy = CGFloat(cg.height) / screen.height
        let patch = CGRect(x: (ruler.midX - screen.minX - 2) * sx,
            y: (ruler.minY - screen.minY) * sy, width: 4 * sx, height: ruler.height * sy).integral
        let pixels = try XCTUnwrap(cg.cropping(to: patch))
        let width = 4, height = max(1, Int(ruler.height.rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double((0..<height).filter { row in
            (0..<width).contains { column in
                let i = (row * width + column) * 4
                return rgba[i] > 150 && rgba[i + 1] > 120 && rgba[i + 2] < 100
            }
        }.count)
    }

    @MainActor
    private func rgbSample(in image: UIImage, at point: CGPoint, screen: CGRect) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage)
        let sx = CGFloat(cg.width) / screen.width, sy = CGFloat(cg.height) / screen.height
        let patch = CGRect(x: (point.x - screen.minX - 1.5) * sx,
            y: (point.y - screen.minY - 1.5) * sy, width: 3 * sx, height: 3 * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let pixels = try XCTUnwrap(cg.cropping(to: patch))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .medium
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba.prefix(3).map(Int.init)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
    }

    @MainActor
    private func attach(name: String) {
        attach(XCUIScreen.main.screenshot(), name: name)
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
