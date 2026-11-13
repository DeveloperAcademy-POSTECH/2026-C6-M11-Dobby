import XCTest

/// Synthetic photo coordinates exercise presentation only, not recognition or
/// the physical accuracy of the reported garment measurements.
final class MeasurementFullZoomComparisonUITests: XCTestCase {
    @MainActor
    func testPhotoOverlaysEnlargeTogetherAndZoomedPointEditingPreservesSourceCoordinates() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        launchLiDARLab(app)
        defer { app.terminate() }
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        for _ in 0..<8 where !preview.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))

        let viewport = app.descendants(matching: .any)["garmentResultPhotoViewport"].firstMatch
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        // This central label stays fully visible at 4×, so clipping cannot be
        // mistaken for a change in the capsule's intrinsic screen dimensions.
        let chest = app.descendants(matching: .any)["garmentMeasurementLabel_top.chestWidth"].firstMatch
        let point = app.buttons["garmentMeasurementPoint_armpit_left"]
        let otherPoint = app.buttons["garmentMeasurementPoint_armpit_right"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(chest.waitForExistence(timeout: 5))
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(otherPoint.waitForExistence(timeout: 5))
        let initialViewport = viewport.frame
        let initialPhoto = photo.frame
        let initialLabel = chest.frame
        let initialValue = chest.label
        let initialCoordinates = try XCTUnwrap(point.value as? String)
        let initialOtherCoordinates = try XCTUnwrap(otherPoint.value as? String)
        let initialPointSeparation = abs(otherPoint.frame.midX - point.frame.midX)
        XCTAssertTrue(initialValue.contains("cm"))
        XCTAssertTrue(initialCoordinates.hasPrefix("x ") && initialCoordinates.contains(", y "))
        XCTAssertGreaterThan(initialLabel.width, 0)
        XCTAssertGreaterThan(initialLabel.height, 0)
        XCTAssertGreaterThan(initialPointSeparation, 0)
        XCTAssertTrue(initialPhoto.contains(initialLabel))
        XCTAssertEqual(point.frame.width, 56, accuracy: 1)
        XCTAssertEqual(point.frame.height, 56, accuracy: 1)
        attachScreenshot("full-zoom-before-zoom")

        // XCTest's synthesized pinch scale can differ from the raw finger
        // distance ratio observed by the custom recognizer. Measure the real
        // transform from unchanged source points and approach it in small steps.
        let intermediateScale = pinchOut(photo, untilAtLeast: 1.95, left: point, right: otherPoint,
                                         initialSeparation: initialPointSeparation)
        XCTAssertGreaterThan(abs(chest.frame.midY - initialLabel.midY), 5,
                             "The label must move with its garment anchor when the photo zooms")
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: intermediateScale, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        XCTAssertEqual(otherPoint.value as? String, initialOtherCoordinates)
        attachZoomState("full-zoom-intermediate", scale: intermediateScale,
                        left: point, right: otherPoint, label: chest)

        let maximumScale = pinchOut(photo, untilAtLeast: 3.95, left: point, right: otherPoint,
                                    initialSeparation: initialPointSeparation)
        XCTAssertGreaterThanOrEqual(maximumScale, intermediateScale - 0.05)
        XCTAssertLessThanOrEqual(maximumScale, 4.05, "Photo navigation must respect its 4× limit")
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: maximumScale, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        XCTAssertEqual(otherPoint.value as? String, initialOtherCoordinates)
        attachZoomState("full-zoom-maximum", scale: maximumScale,
                        left: point, right: otherPoint, label: chest)

        // A synthesized gesture may already have reached the cap on its first
        // step. A further pinch still verifies the saturated presentation.
        photo.pinch(withScale: 1.15, velocity: 1)
        let saturatedScale = actualScale(left: point, right: otherPoint,
                                         initialSeparation: initialPointSeparation)
        XCTAssertEqual(saturatedScale, maximumScale, accuracy: 0.05)
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: saturatedScale, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        let saturatedLabel = chest.frame

        // At this zoom the central background is clear of point handles. A
        // short pan keeps the capsule visible and away from clamping edges.
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let translation = CGVector(dx: 16, dy: 12)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(translation))
        waitUntil { abs(chest.frame.midX - saturatedLabel.midX) > 8 }
        XCTAssertEqual(chest.frame.midX, saturatedLabel.midX + translation.dx, accuracy: 3,
                       "The enlarged capsule must follow its garment anchor during a pan")
        XCTAssertEqual(chest.frame.midY, saturatedLabel.midY + translation.dy, accuracy: 3)
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: saturatedScale, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        attachScreenshot("full-zoom-maximum-after-pan")

        // Approach the actual 1× state instead of assuming that XCTest's
        // requested scale equals the custom recognizer's finger-distance ratio.
        // At identity, the edge clamp also removes the preceding pan.
        for _ in 0..<8 where actualScale(left: point, right: otherPoint,
                                         initialSeparation: initialPointSeparation) > 1.01 {
            photo.pinch(withScale: 0.5, velocity: -1)
        }
        waitUntil {
            abs(chest.frame.midX - initialLabel.midX) <= 2
                && abs(chest.frame.midY - initialLabel.midY) <= 2
        }
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: 1, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        XCTAssertEqual(chest.frame.minX, initialLabel.minX, accuracy: 2)
        XCTAssertEqual(chest.frame.minY, initialLabel.minY, accuracy: 2)
        XCTAssertEqual(actualScale(left: point, right: otherPoint,
                                   initialSeparation: initialPointSeparation), 1, accuracy: 0.01)
        XCTAssertEqual(otherPoint.value as? String, initialOtherCoordinates)
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].isEnabled)
        attachScreenshot("full-zoom-restored-one-x")

        // Return to an intermediate zoom, where the left armpit remains on
        // screen. Editing must invert the display scale exactly once, while
        // the larger visible dot retains its original 56pt touch target.
        let editingScale = pinchOut(photo, untilAtLeast: 1.95, left: point, right: otherPoint,
                                    initialSeparation: initialPointSeparation)
        XCTAssertLessThan(editingScale, 2.7,
                          "The point-edit comparison requires the left armpit to remain on screen")
        // Bring the whole 56pt target inside the viewport rather than testing
        // XCTest's hit-testing behavior for a partly clipped edge button.
        let editPanStart = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        editPanStart.press(forDuration: 0.05,
                          thenDragTo: editPanStart.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertTrue(initialPhoto.contains(CGPoint(x: point.frame.midX, y: point.frame.midY)))
        XCTAssertEqual(point.frame.width, 56, accuracy: 1)
        XCTAssertEqual(point.frame.height, 56, accuracy: 1)
        assertPresentation(chest: chest, point: point, photo: photo, viewport: viewport,
            labelSize: initialLabel.size, scale: editingScale, value: initialValue, coordinates: initialCoordinates,
            photoFrame: initialPhoto, viewportFrame: initialViewport)
        attachZoomState("full-zoom-before-point-edit", scale: editingScale,
                        left: point, right: otherPoint, label: chest)

        let originalPoint = try XCTUnwrap(Self.coordinates(in: initialCoordinates))
        let editStart = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        editStart.press(forDuration: 0.05, thenDragTo: editStart.withOffset(CGVector(dx: 12, dy: 0)))
        let confirm = app.buttons["confirmGarmentMeasurement"]
        waitUntil {
            point.value as? String != initialCoordinates && confirm.isEnabled
                && !chest.label.contains("재계산 중")
        }
        let editedPoint = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(point.value as? String)))
        XCTAssertEqual(editedPoint.x - originalPoint.x, 12 / (initialPhoto.width * editingScale), accuracy: 0.001,
                       "A zoomed drag must convert screen points back into source coordinates once")
        XCTAssertEqual(editedPoint.y, originalPoint.y, accuracy: 0.0005)
        XCTAssertEqual(otherPoint.value as? String, initialOtherCoordinates)
        XCTAssertNotEqual(chest.label, initialValue, "Moving the chest endpoint must recalculate its measurement")
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        XCTAssertEqual(point.frame.width, 56, accuracy: 1)
        XCTAssertEqual(point.frame.height, 56, accuracy: 1)
        assertFrame(photo.frame, equals: initialPhoto)
        assertFrame(viewport.frame, equals: initialViewport)
        attachZoomState("full-zoom-after-point-edit", scale: editingScale,
                        left: point, right: otherPoint, label: chest)
    }

    @MainActor
    private func pinchOut(_ photo: XCUIElement, untilAtLeast target: CGFloat,
                          left: XCUIElement, right: XCUIElement, initialSeparation: CGFloat,
                          file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        var scale = actualScale(left: left, right: right, initialSeparation: initialSeparation)
        for _ in 0..<12 where scale < target {
            photo.pinch(withScale: min(1.2, max(1.05, target / scale)), velocity: 1)
            scale = actualScale(left: left, right: right, initialSeparation: initialSeparation)
        }
        XCTAssertGreaterThanOrEqual(scale, target,
                                    "Pinches must visibly enlarge the source-point separation", file: file, line: line)
        return scale
    }

    @MainActor
    private func actualScale(left: XCUIElement, right: XCUIElement,
                             initialSeparation: CGFloat) -> CGFloat {
        abs(right.frame.midX - left.frame.midX) / initialSeparation
    }

    @MainActor
    private func attachZoomState(_ name: String, scale: CGFloat, left: XCUIElement,
                                 right: XCUIElement, label: XCUIElement) {
        let details = XCTAttachment(string: "Observed scale: \(scale)\nLeft: \(left.frame)\nRight: \(right.frame)\nLabel: \(label.frame)")
        details.name = name + "-geometry"
        details.lifetime = .keepAlways
        add(details)
        attachScreenshot(name)
    }

    @MainActor
    private func assertPresentation(chest: XCUIElement, point: XCUIElement,
                                    photo: XCUIElement, viewport: XCUIElement,
                                    labelSize: CGSize, scale: CGFloat, value: String, coordinates: String,
                                    photoFrame: CGRect, viewportFrame: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(chest.exists, file: file, line: line)
        XCTAssertTrue(photo.frame.contains(chest.frame),
                      "Compare a fully visible capsule rather than a clipped edge label", file: file, line: line)
        XCTAssertEqual(chest.frame.width, labelSize.width * scale, accuracy: 1, file: file, line: line)
        XCTAssertEqual(chest.frame.height, labelSize.height * scale, accuracy: 1, file: file, line: line)
        XCTAssertEqual(point.frame.width, 56, accuracy: 1,
                       "Enlarging the visible dot must preserve its screen-space touch target", file: file, line: line)
        XCTAssertEqual(point.frame.height, 56, accuracy: 1, file: file, line: line)
        XCTAssertEqual(chest.label, value, "Navigation must preserve the measurement value", file: file, line: line)
        XCTAssertEqual(point.value as? String, coordinates,
                       "Navigation must preserve normalized source-photo coordinates", file: file, line: line)
        assertFrame(photo.frame, equals: photoFrame, file: file, line: line)
        assertFrame(viewport.frame, equals: viewportFrame, file: file, line: line)
    }

    private static func coordinates(in text: String) -> CGPoint? {
        let pieces = text.split { $0 == " " || $0 == "," }
        guard pieces.count == 4, pieces[0] == "x", pieces[2] == "y",
              let x = Double(pieces[1]), let y = Double(pieces[3]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        wait(for: [ready], timeout: 5)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
