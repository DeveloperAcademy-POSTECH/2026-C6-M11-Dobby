import XCTest
import UIKit

/// This exercises the explicitly labelled synthetic preview. It is evidence of
/// navigation, display and persistence, never camera or model accuracy.
final class GarmentCaptureFlowTests: XCTestCase {
    @MainActor
    func testCaptureAndResultButtonsRespondAcrossTheirVisiblePadding() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()

        // The right side of each 44-point toolbar button is outside its small
        // symbol. A tap there must still perform the button's normal action.
        let close = app.buttons["closeGarmentCapture"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
        expectation(for: NSPredicate { _, _ in preview.isHittable }, evaluatedWith: preview)
        waitForExpectations(timeout: 5)

        let shutter = app.buttons["captureGarment"]
        let confirm = app.buttons["confirmGarmentMeasurement"]
        // Both taps fall inside the visible capsule and outside the centered
        // confirmation text, covering horizontal and vertical label padding.
        let confirmationSites = [CGVector(dx: 0.12, dy: 0.18), CGVector(dx: 0.88, dy: 0.82)]
        for (index, site) in confirmationSites.enumerated() {
            reveal(preview, in: app)
            preview.tap()
            XCTAssertTrue(shutter.waitForExistence(timeout: 10))
            armPreviewCapture(in: app)
            XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
            shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)).tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))

            if index == 0 {
                XCTAssertFalse(app.buttons["garmentResultActions"].exists)

                let retake = app.buttons["retakeGarmentMeasurement"]
                retake.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
                XCTAssertTrue(shutter.waitForExistence(timeout: 5))
                assertRecognitionGate(in: app, ready: false)
                armPreviewCapture(in: app)
                shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
                XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            }

            XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
            attachScreenshot(app, name: "garment-confirm-padding-\(index)")
            confirm.coordinate(withNormalizedOffset: site).tap()
            expectation(for: NSPredicate { _, _ in preview.isHittable }, evaluatedWith: preview)
            waitForExpectations(timeout: 10)
            XCTAssertFalse(confirm.exists, "A tap in the capsule padding must save and dismiss the result")
        }
    }

    @MainActor
    func testReducedMotionPreviewKeepsAdvisoryContourCaptureAndRetakeUsable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-reduce-motion"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        let shutter = app.buttons["captureGarment"]
        assertRecognitionGate(in: app, ready: false)
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        XCTAssertFalse(guidance.label.contains("인식 완료"))
        recognize.tap()
        assertRecognitionGate(in: app, ready: true)
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        assertAdvisoryContourGuidance(guidance)
        shutter.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        assertRecognitionGate(in: app, ready: false)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-reduced-motion-retake")
    }

    @MainActor
    func testSyntheticPreviewRequiresRecognitionAndDisablesAfterLossAndRetakeForBothKinds() throws {
        continueAfterFailure = false
        let fixtures: [(arguments: [String], prefix: String, count: Int)] = [
            (["--garment-preview-top"], "top.", 4),
            ([], "bottom.", 4)
        ]
        for fixture in fixtures {
            let app = XCUIApplication()
            app.launchArguments = fixture.arguments
            launchLiDARLab(app)
            let preview = app.buttons["openGarmentPreview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
            reveal(preview, in: app)
            preview.tap()
            let recognize = app.buttons["previewRecognizeGarment"]
            XCTAssertTrue(recognize.waitForExistence(timeout: 10))
            let shutter = app.buttons["captureGarment"]
            let silhouette = app.descendants(matching: .any)["garmentSilhouette"].firstMatch
            let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
            XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)
            XCTAssertFalse(silhouette.exists)
            XCTAssertFalse(guidance.label.contains("인식 완료"))
            assertRecognitionGate(in: app, ready: false)
            try assertShutterCenterColor(in: app, ready: false,
                attachmentName: "garment-\(fixture.prefix)-waiting-shutter")
            shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch.exists,
                           "Tapping a waiting shutter must not begin photo analysis")
            recognize.tap()
            assertRecognitionGate(in: app, ready: true)
            try assertShutterCenterColor(in: app, ready: true,
                attachmentName: "garment-\(fixture.prefix)-recognized-orange-shutter")
            XCTAssertTrue(silhouette.exists)
            recognize.tap()
            assertRecognitionGate(in: app, ready: false)
            try assertShutterCenterColor(in: app, ready: false,
                attachmentName: "garment-\(fixture.prefix)-lost-recognition-shutter")
            XCTAssertFalse(silhouette.exists, "Losing recognition must remove both the outline and orange readiness dot")
            shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
            recognize.tap()
            assertRecognitionGate(in: app, ready: true)
            try assertShutterCenterColor(in: app, ready: true,
                attachmentName: "garment-\(fixture.prefix)-recognition-reacquired")
            shutter.tap()
            let confirm = app.buttons["confirmGarmentMeasurement"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists,
                          "This fixture verifies UI flow, never real camera recognition")
            let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "garmentMeasurementLabel_" + fixture.prefix))
            XCTAssertEqual(labels.count, fixture.count)
            assertSingleSideResult(in: app, top: fixture.prefix == "top.")
            let otherPrefix = fixture.prefix == "top." ? "bottom." : "top."
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "garmentMeasurementLabel_" + otherPrefix)).firstMatch.exists)
            attachScreenshot(app, name: "garment-\(fixture.prefix)-captured-after-recognition")

            app.buttons["retakeGarmentMeasurement"].tap()
            XCTAssertTrue(recognize.waitForExistence(timeout: 5))
            XCTAssertFalse(silhouette.exists)
            XCTAssertFalse(guidance.label.contains("인식 완료"))
            assertRecognitionGate(in: app, ready: false)
            shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(confirm.exists, "Retaking must not reuse the previous capture's recognition")
            recognize.tap()
            assertRecognitionGate(in: app, ready: true)
            shutter.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
            XCTAssertEqual(labels.count, fixture.count)
            app.terminate()
        }
    }

    @MainActor
    func testSyntheticCaptureFreezesPhotoAndShowsProcessingBeforeMeasurementResult() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top", "--garment-preview-processing", "--garment-preview-no-outline"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()

        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        assertRecognitionGate(in: app, ready: false)
        XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        armPreviewCapture(in: app)
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists,
                       "This processing-only fixture hides the advisory tint so source pixels can be compared")
        let viewport = app.descendants(matching: .any)["garmentCameraViewport"].firstMatch
        let liveBounds = viewport.frame
        let shutterBounds = shutter.frame
        let screenBounds = app.frame
        let liveScreenshot = XCUIScreen.main.screenshot()
        attachFrame(liveScreenshot, name: "garment-top-live-framing-before-capture")
        // The fixture intentionally holds its processing presentation long
        // enough to inspect it. It never exercises real model/depth accuracy.
        shutter.tap()
        let frozenPhoto = app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch
        XCTAssertTrue(frozenPhoto.waitForExistence(timeout: 5),
                      "Capture must keep the frozen photo visible while finding points and measuring")
        let progress = app.descendants(matching: .any)["measurementProcessingIndicator"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertFalse(shutter.exists, "Processing replaces the shutter so a second capture cannot be requested")
        XCTAssertEqual(progress.frame.midX, shutterBounds.midX, accuracy: 1)
        XCTAssertEqual(progress.frame.midY, shutterBounds.midY, accuracy: 1)
        // Take the frame immediately, before the intentionally short analysis
        // fixture advances. Progress/provenance and controls occupy other areas.
        let frozenBounds = frozenPhoto.frame
        let frozenScreenshot = XCUIScreen.main.screenshot()
        attachFrame(frozenScreenshot, name: "garment-top-frozen-framing-during-analysis")
        XCTAssertEqual(frozenBounds.minX, liveBounds.minX, accuracy: 1)
        XCTAssertEqual(frozenBounds.minY, liveBounds.minY, accuracy: 1)
        XCTAssertEqual(frozenBounds.width, liveBounds.width, accuracy: 1)
        XCTAssertEqual(frozenBounds.height, liveBounds.height, accuracy: 1,
                       "The frozen photo must stay bounded to the full camera viewport")
        let sampleSites = [CGPoint(x: 0.05, y: 0.28), CGPoint(x: 0.15, y: 0.46),
            CGPoint(x: 0.85, y: 0.46), CGPoint(x: 0.42, y: 0.60),
            CGPoint(x: 0.08, y: 0.64), CGPoint(x: 0.92, y: 0.64)]
        var liveColors: [[Int]] = []
        for site in sampleSites {
            let location = CGPoint(x: liveBounds.minX + liveBounds.width * site.x,
                y: liveBounds.minY + liveBounds.height * site.y)
            let liveColor = try rgbSample(in: liveScreenshot.image, at: location, screen: screenBounds)
            let frozenColor = try rgbSample(in: frozenScreenshot.image, at: location, screen: screenBounds)
            liveColors.append(liveColor)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(liveColor[channel] - frozenColor[channel]), 8,
                    "The same source pixel must remain at \(site) during analysis without an additional crop")
            }
        }
        XCTAssertGreaterThan(abs(liveColors[0][0] - liveColors[1][0]), 40,
            "Probe both the colored garment and its background so a blank frozen frame cannot pass")
        XCTAssertTrue(progress.exists)
        let capturedProgress = NSPredicate { _, _ in
            ["측정점 확인 중", "길이 계산 중"].contains(progress.label)
        }
        expectation(for: capturedProgress, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementProgress"].firstMatch.exists,
                       "The previous stage capsule must not remain alongside the new ring")
        XCTAssertFalse(app.descendants(matching: .any)["captureGuidance"].firstMatch.exists)
        XCTAssertEqual(app.progressIndicators.count, 0, "Processing uses one custom ring without system spinners")
        XCTAssertFalse(shutter.exists, "A frozen capture must not accept a second shutter request")
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists,
                       "An advisory live contour must not overlay a different captured photo")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 4)
        XCTAssertFalse(frozenPhoto.exists)
        XCTAssertFalse(progress.exists)
        attachScreenshot(app, name: "garment-top-result-after-frozen-photo-processing")

        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        assertRecognitionGate(in: app, ready: false)
        XCTAssertFalse(frozenPhoto.exists)
        XCTAssertFalse(progress.exists)
        XCTAssertFalse(confirm.exists)
    }

    @MainActor
    func testSyntheticTopPreviewKeepsContourAdvisoryAndShowsFourCapturedMeasurements() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        launchLiDARLab(app)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists)
        XCTAssertTrue(app.staticTexts["automaticGarmentRecognitionHelp"].exists)

        let photoCheck = app.buttons["openTopRecognition"]
        reveal(photoCheck, in: app)
        XCTAssertTrue(photoCheck.exists)
        XCTAssertTrue(app.buttons["openBottomRecognition"].exists, "Both manual models remain available only as photo diagnostics")
        photoCheck.tap()
        XCTAssertTrue(app.navigationBars["상의 사진 인식"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pickTopPhoto"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cm 치수는 계산하지 않습니다")).firstMatch.exists)
        app.buttons["완료"].tap()

        let preview = app.buttons["openGarmentPreview"]
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        recognize.tap()
        assertAdvisoryContourGuidance(guidance)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-top-preview-recognized-outline")
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 4)
        assertSingleSideResult(in: app, top: true)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_bottom.")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["garmentMeasurementLabel_top.totalLength"].label.contains("cm"))
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Top measurement labels must not cover each other")
            }
        }
        attachScreenshot(app, name: "garment-top-preview-measurement-result")
        let shoulderValue = app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"].label
        app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["실측 결과"].exists)
        XCTAssertFalse(app.navigationBars["측정 테스트"].exists)
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"].label, shoulderValue,
                       "A value label tap must preserve the automatic result")
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["confirmGarmentMeasurement"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "어깨너비 · 데모")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.exists)
        record.tap()
        XCTAssertTrue(app.staticTexts["automaticValue_top.totalLength"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
    }

    @MainActor
    func testUnsupportedSimulatorDoesNotProduceMeasurements() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Unsupported-camera behavior is specific to the simulator")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists,
                       "Normal capture must not require a model selection")
        let capture = app.buttons["openGarmentCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        reveal(capture, in: app)
        capture.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertFalse(app.segmentedControls["automaticGarmentKind"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "LiDAR가 있는 iPhone")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).firstMatch.exists)
        attachScreenshot(app, name: "garment-camera-unsupported-simulator")
    }

    @MainActor
    func testLandscapePreviewKeepsCaptureControlsReachable() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recognize.isHittable)
        recognize.tap()
        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-preview-landscape-recognized")
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.buttons["retakeGarmentMeasurement"].isHittable)
        attachScreenshot(app, name: "garment-preview-landscape-result")
    }

    @MainActor
    func testMissingHiddenRightMeasurementsKeepFourUsableLeftMeasurementsWithoutReviewNotice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-partial"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["garmentMeasurementLabel_bottom.waist_left.waist_right"].exists)
        assertSingleSideResult(in: app, top: false)
        XCTAssertFalse(app.buttons["garmentUnavailableNotice"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentUnavailableSummary"].firstMatch.exists,
                       "An unavailable duplicate on the unused side must not prompt manual review")
        XCTAssertFalse(app.buttons["garmentUncertainNotice"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementReviewActions"].firstMatch.exists,
                       "Usable numbers must not require review, even if internal quality is uncertain")
        // Only actual missing values appear as failures; hidden right-side
        // failures and quality-only advisories must not add review actions.
        for id in ["bottom.hem_right_inner.hem_right_outer", "bottom.crotch.hem_right_inner", "bottom.crotch.hem_left_inner"] {
            XCTAssertFalse(app.buttons["reviewGarmentMeasurement_" + id].exists)
        }
        let leftHem = app.descendants(matching: .any)["garmentMeasurementLabel_bottom.hem_left_inner.hem_left_outer"].firstMatch
        XCTAssertTrue(leftHem.exists)
        XCTAssertTrue(leftHem.label.contains("cm"))
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_left_inner"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_right_inner"].firstMatch.exists)
        attachScreenshot(app, name: "garment-preview-missing-hidden-right-keeps-left-values")
    }

    @MainActor
    func testMissingMeasurementKeepsEditablePointsWithoutFailureBanner() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-both-sides-partial"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["garmentUnavailableNotice"].exists)
        let point = app.buttons["garmentMeasurementPoint_hem_left_inner"]
        XCTAssertTrue(point.exists)
        XCTAssertTrue(point.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementLabel_bottom.hem_left_inner.hem_left_outer"].exists,
                       "A pending handle must not create an unmeasured length")
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].isEnabled)
        attachScreenshot(app, name: "garment-missing-measurement-visible-points-without-banner")
    }

    @MainActor
    func testAdvisoryContourPreviewResultRetakeAndConfirmedSave() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchLiDARLab(app)

        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        attachScreenshot(app, name: "garment-preview-camera")
        recognize.tap()
        let silhouette = app.descendants(matching: .any)["garmentSilhouette"].firstMatch
        XCTAssertTrue(silhouette.waitForExistence(timeout: 5))
        assertAdvisoryContourGuidance(guidance)
        attachScreenshot(app, name: "garment-preview-recognized-outline")

        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        let waist = app.descendants(matching: .any)["garmentMeasurementLabel_bottom.waist_left.waist_right"]
        XCTAssertTrue(waist.exists)
        XCTAssertTrue(waist.label.contains("cm"))
        let labels = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 4)
        assertSingleSideResult(in: app, top: false)
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Measurement labels must not cover each other: \(label.identifier), \(other.identifier)")
            }
        }
        attachScreenshot(app, name: "garment-preview-measurement-result")

        XCTAssertFalse(app.buttons["garmentResultActions"].exists)
        XCTAssertTrue(waist.waitForExistence(timeout: 5))
        waist.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["실측 결과"].exists)
        XCTAssertFalse(app.navigationBars["허리"].exists)

        let retake = app.buttons["retakeGarmentMeasurement"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.exists)
        recognize.tap()
        XCTAssertTrue(silhouette.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Only a successful archive save should dismiss the result")
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "허리 단면 · 데모")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.exists)
        record.tap()
        let replayedWaist = app.staticTexts["automaticValue_bottom.waist_left.waist_right"]
        XCTAssertTrue(replayedWaist.waitForExistence(timeout: 10))
        XCTAssertTrue(replayedWaist.label.contains("cm"))
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
    }

    @MainActor
    func testDraggingTopPointShowsMagnifierRecalculatesAndPersistsAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        openPointEditingPreview(in: app)

        let shoulder = app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"]
        let chest = app.descendants(matching: .any)["garmentMeasurementLabel_top.chestWidth"]
        let originalShoulder = try XCTUnwrap(Self.centimeters(in: shoulder.label))
        let originalChest = try XCTUnwrap(Self.centimeters(in: chest.label))
        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        assertPhotoAccessibilityBounds(photo, in: app)
        XCTAssertTrue(point.isHittable)
        // Allow only the floating-point representation error of the hit frame.
        XCTAssertGreaterThanOrEqual(point.frame.width, 56 - 0.001)
        XCTAssertGreaterThanOrEqual(point.frame.height, 56 - 0.001)
        let originalPoint = try XCTUnwrap(point.value as? String)
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertFalse(magnifier.exists, "The initial selected point must not create a persistent loupe.")
        let rightShoulder = app.buttons["garmentMeasurementPoint_shoulder_right"]
        let originalRightShoulder = try XCTUnwrap(rightShoulder.value as? String)
        rightShoulder.tap()
        XCTAssertFalse(magnifier.exists, "A selection-only tap must not show the loupe.")
        XCTAssertEqual(rightShoulder.value as? String, originalRightShoulder)
        point.tap()
        XCTAssertFalse(magnifier.exists, "Selecting another point is still not a drag.")
        XCTAssertEqual(point.value as? String, originalPoint)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: shoulder.label)), originalShoulder,
                       "Selecting a point must not change the measurement")
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        waitForChangedCentimeters(shoulder, from: originalShoulder)
        XCTAssertNotEqual(point.value as? String, originalPoint)
        XCTAssertFalse(magnifier.exists, "Releasing a point must hide its loupe even while that point stays selected.")

        let correctedShoulder = try XCTUnwrap(Self.centimeters(in: shoulder.label))
        XCTAssertLessThan(correctedShoulder, originalShoulder)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: chest.label)), originalChest,
                       "Moving a shoulder must preserve an unrelated chest measurement")
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        attachScreenshot(app, name: "garment-top-drag-released-loupe-hidden-and-correction")
        let confirm = app.buttons["confirmGarmentMeasurement"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        confirm.tap()
        XCTAssertTrue(app.buttons["openGarmentPreview"].waitForExistence(timeout: 10))
        // Recreate the app and replay its on-disk record, rather than retaining
        // a result-view model in memory. No previous archives are removed.
        app.terminate()
        launchLiDARLab(app)
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "어깨너비 · 데모")).firstMatch
        reveal(record, in: app)
        XCTAssertTrue(record.exists)
        record.tap()
        let replayed = app.staticTexts["automaticValue_top.shoulderWidth"]
        XCTAssertTrue(replayed.waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: replayed.label)), correctedShoulder, accuracy: 0.06,
                       "The result label uses one decimal place and the archive uses two")
        XCTAssertTrue(app.staticTexts["automaticProvenance"].label.contains("합성"))
        let correctionProvenance = app.descendants(matching: .any)["automaticPointAdjustmentProvenance"].firstMatch
        XCTAssertTrue(correctionProvenance.exists)
        XCTAssertTrue(correctionProvenance.label.contains("수동"))
        attachScreenshot(app, name: "garment-top-drag-replayed-after-app-relaunch")
    }

    @MainActor
    func testGrabbingBesideSmallTopPointDragsThatPointWithoutJumping() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        openPointEditingPreview(in: app)

        let point = app.buttons["garmentMeasurementPoint_shoulder_left"]
        let otherPoint = app.buttons["garmentMeasurementPoint_shoulder_right"]
        let shoulder = app.descendants(matching: .any)["garmentMeasurementLabel_top.shoulderWidth"]
        let chest = app.descendants(matching: .any)["garmentMeasurementLabel_top.chestWidth"]
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(point.isHittable)
        XCTAssertGreaterThanOrEqual(point.frame.width, 56 - 0.001)
        XCTAssertGreaterThanOrEqual(point.frame.height, 56 - 0.001)
        assertPhotoAccessibilityBounds(photo, in: app)
        let originalPoint = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(point.value as? String)))
        let originalOtherPoint = try XCTUnwrap(otherPoint.value as? String)
        let originalShoulder = try XCTUnwrap(Self.centimeters(in: shoulder.label))
        let originalChest = try XCTUnwrap(Self.centimeters(in: chest.label))
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch

        // Select the opposite point first. That selection must not open the
        // loupe or change the other point before the peripheral drag.
        otherPoint.tap()
        XCTAssertFalse(magnifier.exists)
        XCTAssertEqual(otherPoint.value as? String, originalOtherPoint)
        // Seventeen points is outside the small visible ring and inside the
        // 28-point radius. There is no neighbouring handle at this grab site.
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -17, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        waitForChangedCentimeters(shoulder, from: originalShoulder)
        let moved = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(point.value as? String)))
        // A peripheral grab must preserve the original point-to-finger offset.
        // The tolerance covers input pixel rounding, while a 17-point jump does not.
        XCTAssertEqual(moved.x - originalPoint.x, 0.05, accuracy: 0.003)
        XCTAssertEqual(moved.y - originalPoint.y, 0.025, accuracy: 0.003)
        XCTAssertEqual(otherPoint.value as? String, originalOtherPoint)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: chest.label)), originalChest)
        XCTAssertFalse(magnifier.exists, "The peripheral drag must dismiss its loupe on finger-up.")
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].isEnabled)
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        attachScreenshot(app, name: "garment-top-small-point-peripheral-drag-without-jump")
    }

    @MainActor
    func testNearbyArmpitPointsKeepTheirOwnTouchTargetsAfterMovingCloser() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--garment-preview-top"]
        openPointEditingPreview(in: app)
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        assertPhotoAccessibilityBounds(photo, in: app)
        let left = app.buttons["garmentMeasurementPoint_armpit_left"]
        let right = app.buttons["garmentMeasurementPoint_armpit_right"]
        let chest = app.descendants(matching: .any)["garmentMeasurementLabel_top.chestWidth"]
        let chestBeforeFirst = try XCTUnwrap(Self.centimeters(in: chest.label))
        let leftOriginal = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(left.value as? String)))
        let rightOriginal = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(right.value as? String)))
        let rightValue = try XCTUnwrap(right.value as? String)
        let confirm = app.buttons["confirmGarmentMeasurement"]
        // First bring the later-drawn right armpit point within the 28-point
        // hit radius of the left point. Coordinates come from image space;
        // a clipped touch polygon's AX frame need not centre on the marker.
        // Both the setup and subsequent move remain inside the garment mask.
        let firstStart = photo.coordinate(withNormalizedOffset: CGVector(dx: rightOriginal.x, dy: rightOriginal.y))
        firstStart.press(forDuration: 0.05, thenDragTo: firstStart.withOffset(
            CGVector(dx: (leftOriginal.x - rightOriginal.x) * photo.frame.width + 24, dy: 0)))
        expectation(for: NSPredicate(format: "value != %@", rightValue), evaluatedWith: right)
        waitForExpectations(timeout: 5)
        waitForChangedCentimeters(chest, from: chestBeforeFirst)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        let leftBeforeSecond = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(left.value as? String)))
        let rightBeforeSecond = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(right.value as? String)))
        XCTAssertEqual((rightBeforeSecond.x - leftBeforeSecond.x) * photo.frame.width, 24, accuracy: 0.75)
        XCTAssertEqual((rightBeforeSecond.y - leftBeforeSecond.y) * photo.frame.height, 0, accuracy: 0.75)
        let otherPoints = Dictionary(uniqueKeysWithValues: try app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementPoint_")
        ).allElementsBoundByIndex.filter { $0.identifier != left.identifier }.map {
            ($0.identifier, try XCTUnwrap($0.value as? String))
        })
        let chestBeforeSecond = try XCTUnwrap(Self.centimeters(in: chest.label))
        // This site is four points to the right of the left marker: it is
        // nearer the left point, but also inside the neighbour's old circle.
        let secondStart = photo.coordinate(withNormalizedOffset: CGVector(dx: leftBeforeSecond.x, dy: leftBeforeSecond.y))
            .withOffset(CGVector(dx: 4, dy: 0))
        secondStart.press(forDuration: 0.05, thenDragTo: secondStart.withOffset(CGVector(dx: 8, dy: 15)))
        waitForChangedCentimeters(chest, from: chestBeforeSecond)
        let moved = try XCTUnwrap(Self.coordinates(in: try XCTUnwrap(left.value as? String)))
        XCTAssertEqual(moved.x - leftBeforeSecond.x, 8 / photo.frame.width, accuracy: 0.003)
        XCTAssertEqual(moved.y - leftBeforeSecond.y, 15 / photo.frame.height, accuracy: 0.003)
        for (identifier, value) in otherPoints {
            XCTAssertEqual(app.buttons[identifier].value as? String, value,
                           "The nearer left point must own the touch, preserving \(identifier)")
        }
        let magnifier = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertFalse(magnifier.exists, "Moving nearby points must not leave a stale loupe after release.")
        XCTAssertTrue(confirm.isEnabled)
        attachScreenshot(app, name: "garment-close-armpit-points-select-and-drag-nearest-marker")
    }

    @MainActor
    func testRetakingAfterBottomPointDragClearsAdjustmentAndSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPointEditingPreview(in: app)
        let waist = app.descendants(matching: .any)["garmentMeasurementLabel_bottom.waist_left.waist_right"]
        let originalWaist = try XCTUnwrap(Self.centimeters(in: waist.label))
        let point = app.buttons["garmentMeasurementPoint_waist_left"]
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(point.isHittable)
        let originalPoint = try XCTUnwrap(point.value as? String)
        let photo = app.descendants(matching: .any)["garmentMeasurementPhoto"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        assertPhotoAccessibilityBounds(photo, in: app)
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        waitForChangedCentimeters(waist, from: originalWaist)
        XCTAssertNotEqual(point.value as? String, originalPoint)
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists,
                       "The completed bottom-point drag must not leave a loupe.")
        attachScreenshot(app, name: "garment-bottom-drag-before-retake")

        app.buttons["retakeGarmentMeasurement"].tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists,
                       "A fresh capture starts idle with no active point drag.")
        XCTAssertEqual(point.value as? String, originalPoint)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: waist.label)), originalWaist,
                       "A fresh capture must not carry forward the prior point adjustment")
    }

    @MainActor
    private func assertSingleSideResult(in app: XCUIApplication, top: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let selected = top
            ? ["top.totalLength", "top.shoulderWidth", "top.chestWidth", "top.sleeveLengthLeft"]
            : ["bottom.waist_left.waist_right", "bottom.crotch.waist_center",
               "bottom.hem_left_outer.waist_left", "bottom.hem_left_inner.hem_left_outer"]
        let actual = Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_")).allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(actual, Set(selected.map { "garmentMeasurementLabel_" + $0 }), file: file, line: line)
        // The current total-length editor exposes the depth-backed neck centre,
        // including recovery, rather than its hidden model contributors.
        let unusedPoints = top ? ["sleeve_end_right", "hem_left", "hem_right", "neck_left", "neck_right"] : ["hem_right_inner", "hem_right_outer"]
        for id in unusedPoints {
            XCTAssertFalse(app.buttons["garmentMeasurementPoint_" + id].exists,
                           "The unused side must not show an editable handle: \(id)", file: file, line: line)
        }
        let selectedPoints = top
            ? ["sleeve_end_left", "shoulder_right", "hem_center", "neck_center", "armpit_left", "armpit_right"]
            : ["hem_left_inner", "hem_left_outer", "waist_right"]
        for id in selectedPoints {
            XCTAssertTrue(app.buttons["garmentMeasurementPoint_" + id].exists,
                          "A point used by a displayed measurement must remain editable: \(id)", file: file, line: line)
        }
    }

    @MainActor
    private func openPointEditingPreview(in app: XCUIApplication) {
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
    }

    @MainActor
    private func assertRecognitionGate(in app: XCUIApplication, ready: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let shutter = app.buttons["captureGarment"]
        let expectedValue = ready ? "촬영 가능" : "옷 인식 대기"
        expectation(for: NSPredicate { _, _ in
            shutter.isEnabled == ready && shutter.value as? String == expectedValue
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(shutter.isEnabled, ready, file: file, line: line)
        XCTAssertEqual(shutter.value as? String, expectedValue, file: file, line: line)
    }

    @MainActor
    private func assertShutterCenterColor(in app: XCUIApplication, ready: Bool, attachmentName: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let shutterBounds = app.buttons["captureGarment"].frame
        let screenBounds = app.frame
        let frame = XCUIScreen.main.screenshot()
        attachFrame(frame, name: attachmentName)
        let rgb = try rgbSample(in: frame.image,
            at: CGPoint(x: shutterBounds.midX, y: shutterBounds.midY), screen: screenBounds,
            file: file, line: line)
        if ready {
            XCTAssertGreaterThan(rgb[0], 180, "A ready shutter must visibly show its orange center", file: file, line: line)
            XCTAssertGreaterThanOrEqual(rgb[1], 60, file: file, line: line)
            XCTAssertLessThanOrEqual(rgb[1], 140, file: file, line: line)
            XCTAssertLessThan(rgb[2], 120, file: file, line: line)
            XCTAssertGreaterThan(rgb[0] - rgb[1], 60, file: file, line: line)
        } else {
            XCTAssertLessThan(abs(rgb[0] - rgb[1]), 20,
                "Waiting or lost recognition must remove the visible orange center", file: file, line: line)
            XCTAssertLessThan(abs(rgb[1] - rgb[2]), 20, file: file, line: line)
        }
    }

    @MainActor
    private func armPreviewCapture(in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 5), file: file, line: line)
        if app.buttons["captureGarment"].value as? String != "촬영 가능" { recognize.tap() }
        assertRecognitionGate(in: app, ready: true, file: file, line: line)
    }

    @MainActor
    private func assertAdvisoryContourGuidance(_ guidance: XCUIElement) {
        XCTAssertEqual(guidance.label, "옷 인식 완료! 촬영 버튼을 눌러주세요")
        // Hi-Fi labels the visible outline as recognition. Actual measurement
        // is still verified separately after the shutter in each flow test.
    }

    @MainActor
    private func assertPhotoAccessibilityBounds(_ photo: XCUIElement, in app: XCUIApplication) {
        let image = app.images["촬영한 옷과 측정점"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let loupe = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        XCTAssertFalse(loupe.exists, "The idle photo editor must not expose an offscreen or persistent loupe.")
        let frames = "Photo \(photo.frame), image \(image.frame)"
        attachScreenshot(app, name: "garment-point-editor-initial-photo-without-loupe")
        XCTAssertEqual(photo.frame.minX, image.frame.minX, accuracy: 0.01)
        XCTAssertEqual(photo.frame.minY, image.frame.minY, accuracy: 0.01, frames)
        XCTAssertEqual(photo.frame.width, image.frame.width, accuracy: 0.01,
                       "The three-times magnifier image must not inflate the photo's accessible bounds")
        XCTAssertEqual(photo.frame.height, image.frame.height, accuracy: 0.01)
        XCTAssertLessThanOrEqual(photo.frame.width, app.windows.firstMatch.frame.width + 0.01)
    }

    @MainActor
    private func waitForChangedCentimeters(_ element: XCUIElement, from original: Double) {
        let changed = NSPredicate { _, _ in
            guard let value = Self.centimeters(in: element.label) else { return false }
            return abs(value - original) > 0.1
        }
        expectation(for: changed, evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    private func waitForCentimeters(_ element: XCUIElement, equalTo expected: Double) {
        let restored = NSPredicate { _, _ in
            guard let value = Self.centimeters(in: element.label) else { return false }
            return abs(value - expected) < 0.01
        }
        expectation(for: restored, evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    nonisolated private static func centimeters(in text: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*cm"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    nonisolated private static func coordinates(in text: String) -> CGPoint? {
        measurementPhotoCoordinates(in: text)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let scrollViews = app.scrollViews
            let scroll = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
            guard scroll.exists else { return }
            let bars = app.navigationBars
            let bar = bars.element(boundBy: max(0, bars.count - 1))
            let top = max(scroll.frame.minY, bar.exists ? bar.frame.maxY : scroll.frame.minY) + 16
            let confirm = app.buttons["confirmGarmentMeasurement"]
            let bottom = min(scroll.frame.maxY - 20,
                             confirm.exists && confirm.isHittable ? confirm.frame.minY - 12 : scroll.frame.maxY - 20)
            if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
            // Returning from a lower photo diagnostic must also reach the
            // normal capture entry above it without resetting the lab state.
            let goingDown = element.frame.minY < top
            // Scroll in the outer margin. A gesture through a garment point
            // intentionally edits that point instead of scrolling the photo.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: goingDown ? 0.45 : 0.72))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: goingDown ? 0.65 : 0.52))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func rgbSample(in image: UIImage, at point: CGPoint, screen: CGRect,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let scaleX = CGFloat(cgImage.width) / screen.width
        let scaleY = CGFloat(cgImage.height) / screen.height
        let x = (point.x - screen.minX) * scaleX
        let y = (point.y - screen.minY) * scaleY
        // Average a tiny patch well inside the flat colored fixture regions.
        // This tolerates screenshot scaling without overlooking a framing jump.
        let patch = CGRect(x: x - 1.5 * scaleX, y: y - 1.5 * scaleY,
            width: 3 * scaleX, height: 3 * scaleY).integral.intersection(
                CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let pixels = try XCTUnwrap(cgImage.cropping(to: patch), file: file, line: line)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.interpolationQuality = .medium
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba.prefix(3).map(Int.init)
    }

    @MainActor
    private func attachFrame(_ frame: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: frame)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        // The full display avoids XCTest cropping a rotated app using its
        // portrait-coordinate bounds on some simulator runtimes.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
