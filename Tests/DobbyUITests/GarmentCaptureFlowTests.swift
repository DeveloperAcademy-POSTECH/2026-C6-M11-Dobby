import XCTest

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
            XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
            shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)).tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))

            if index == 0 {
                let actions = app.buttons["garmentResultActions"]
                actions.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
                let details = app.buttons["openGarmentMeasurementDetails"]
                XCTAssertTrue(details.waitForExistence(timeout: 5))
                details.tap()
                closeResultDetails(in: app)

                let retake = app.buttons["retakeGarmentMeasurement"]
                retake.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
                XCTAssertTrue(shutter.waitForExistence(timeout: 5))
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
        XCTAssertTrue(shutter.isEnabled)
        let guidance = app.descendants(matching: .any)["captureGuidance"].firstMatch
        XCTAssertFalse(guidance.label.contains("인식 완료"))
        recognize.tap()
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        assertAdvisoryContourGuidance(guidance)
        shutter.tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        attachScreenshot(app, name: "garment-reduced-motion-retake")
    }

    @MainActor
    func testSyntheticPreviewCanCaptureBeforeRecognitionAndRetakeForBothKinds() throws {
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
            XCTAssertTrue(guidance.label.contains("옷이 잘리지 않게 카메라 안에 넣어주세요"))
            XCTAssertFalse(guidance.label.contains("인식 완료"))
            XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
            shutter.tap()
            let confirm = app.buttons["confirmGarmentMeasurement"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists,
                          "This fixture verifies UI flow, never real camera recognition")
            let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "garmentMeasurementLabel_" + fixture.prefix))
            XCTAssertEqual(labels.count, fixture.count)
            assertSingleSideResult(in: app, top: fixture.prefix == "top.")
            let otherPrefix = fixture.prefix == "top." ? "bottom." : "top."
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "garmentMeasurementLabel_" + otherPrefix)).firstMatch.exists)
            attachScreenshot(app, name: "garment-\(fixture.prefix)-captured-before-recognition")

            app.buttons["retakeGarmentMeasurement"].tap()
            XCTAssertTrue(recognize.waitForExistence(timeout: 5))
            XCTAssertFalse(silhouette.exists)
            XCTAssertFalse(guidance.label.contains("인식 완료"))
            XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
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
        app.launchArguments = ["--garment-preview-top", "--garment-preview-processing"]
        launchLiDARLab(app)
        let preview = app.buttons["openGarmentPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: app)
        preview.tap()

        let shutter = app.buttons["captureGarment"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
        XCTAssertTrue(app.staticTexts["garmentPreviewProvenance"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["captureGuidance"].firstMatch.label.contains("인식 완료"))
        // The fixture intentionally holds its processing presentation long
        // enough to inspect it. It never exercises real model/depth accuracy.
        shutter.tap()
        let frozenPhoto = app.descendants(matching: .any)["garmentProcessingPhoto"].firstMatch
        XCTAssertTrue(frozenPhoto.waitForExistence(timeout: 5),
                      "Capture must keep the frozen photo visible while finding points and measuring")
        let progress = app.descendants(matching: .any)["garmentMeasurementProgress"].firstMatch
        XCTAssertTrue(progress.exists)
        let capturedProgress = NSPredicate { _, _ in
            guard let value = progress.value as? String else { return false }
            return value.contains("사진 완료") && value.contains("측정점") && value.contains("길이")
        }
        expectation(for: capturedProgress, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
        let stage = progress.value as? String ?? ""
        XCTAssertTrue(stage.contains("사진 완료"))
        XCTAssertTrue(stage.contains("측정점") && stage.contains("길이"),
                      "Progress must explain the remaining work instead of asking for live recognition")
        XCTAssertTrue(shutter.exists)
        XCTAssertFalse(shutter.isEnabled, "A frozen capture must not accept a second shutter request")
        XCTAssertFalse(app.buttons["confirmGarmentMeasurement"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentSilhouette"].firstMatch.exists,
                       "An advisory live contour must not overlay a different captured photo")
        attachScreenshot(app, name: "garment-top-frozen-photo-and-measurement-progress")

        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_top.")).count, 4)
        XCTAssertFalse(frozenPhoto.exists)
        XCTAssertFalse(progress.exists)
        attachScreenshot(app, name: "garment-top-result-after-frozen-photo-processing")

        app.buttons["retakeGarmentMeasurement"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled && shutter.isHittable)
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
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_top.")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 4)
        assertSingleSideResult(in: app, top: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_bottom.")).firstMatch.exists)
        XCTAssertTrue(app.buttons["garmentMeasurementLabel_top.totalLength"].label.contains("cm"))
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Top measurement labels must not cover each other")
            }
        }
        attachScreenshot(app, name: "garment-top-preview-measurement-result")
        let shoulderValue = app.buttons["garmentMeasurementLabel_top.shoulderWidth"].label
        openResultDetails(in: app)
        let reviewMenu = app.buttons["reviewAllGarmentMeasurementPoints"]
        reveal(reviewMenu, in: app)
        XCTAssertTrue(reviewMenu.exists)
        reviewMenu.tap()
        app.buttons["reviewGarmentItem_top.shoulderWidth"].tap()
        XCTAssertTrue(app.navigationBars["측정 테스트"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["A 지정됨"].exists)
        XCTAssertTrue(app.buttons["B 지정됨"].exists)
        app.buttons["완료"].tap()
        closeResultDetails(in: app)
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["garmentMeasurementLabel_top.shoulderWidth"].label, shoulderValue,
                       "Reviewing valid model points must preserve the automatic result")
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
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).firstMatch.exists)
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
        XCTAssertTrue(app.buttons["garmentMeasurementLabel_bottom.waist_left.waist_right"].exists)
        assertSingleSideResult(in: app, top: false)
        openResultDetails(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["garmentUnavailableSummary"].firstMatch.exists,
                       "An unavailable duplicate on the unused side must not prompt manual review")
        // Other visible values may still be uncertain and need review. Only
        // the hidden right-side failures must disappear from review actions.
        for id in ["bottom.hem_right_inner.hem_right_outer", "bottom.crotch.hem_right_inner", "bottom.crotch.hem_left_inner"] {
            XCTAssertFalse(app.buttons["reviewGarmentMeasurement_" + id].exists)
        }
        let leftHem = app.descendants(matching: .any)["garmentMeasurementValue_bottom.hem_left_inner.hem_left_outer"].firstMatch
        reveal(leftHem, in: app)
        XCTAssertTrue(leftHem.exists)
        XCTAssertTrue(leftHem.label.contains("cm"))
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_left_inner"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_right_inner"].firstMatch.exists)
        attachScreenshot(app, name: "garment-preview-missing-hidden-right-keeps-left-values")
    }

    @MainActor
    func testMissingMeasurementCanBeReviewedWithoutExpandingMeasurementRows() throws {
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
        openResultDetails(in: app)
        let unavailable = app.descendants(matching: .any)["garmentUnavailableSummary"].firstMatch
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.label.contains("2개 항목"),
                      "Missing both sides must report only the two displayed measurements")
        let missing = app.descendants(matching: .any)["garmentMeasurementValue_bottom.hem_left_inner.hem_left_outer"].firstMatch
        reveal(missing, in: app)
        XCTAssertTrue(missing.label.contains("측정 불가"))
        XCTAssertFalse(missing.label.contains("cm"))
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementValue_bottom.crotch.hem_right_inner"].firstMatch.exists)
        let review = app.buttons["reviewGarmentMeasurement_bottom.hem_left_inner.hem_left_outer"]
        reveal(review, in: app)
        XCTAssertTrue(review.exists)
        XCTAssertTrue(review.isEnabled, "Review must be enabled after the captured result finishes calculating")
        XCTAssertTrue(review.isHittable, "The clipped photo or loupe must not obstruct the review button")
        review.tap()
        XCTAssertTrue(app.navigationBars["측정 테스트"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["A 위치 지정"].exists)
        XCTAssertTrue(app.buttons["B 지정됨"].exists)
        let save = app.buttons["saveMeasurement"]
        reveal(save, in: app)
        XCTAssertTrue(save.exists)
        XCTAssertFalse(app.staticTexts["measurementSaved"].exists)
        attachScreenshot(app, name: "garment-missing-measurement-direct-review")
        app.buttons["완료"].tap()
        closeResultDetails(in: app)
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["garmentMeasurementLabel_bottom.hem_left_inner.hem_left_outer"].exists,
                       "Opening manual review must not replace an unavailable automatic value")
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
        let waist = app.buttons["garmentMeasurementLabel_bottom.waist_left.waist_right"]
        XCTAssertTrue(waist.exists)
        XCTAssertTrue(waist.label.contains("cm"))
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex
        XCTAssertEqual(labels.count, 4)
        assertSingleSideResult(in: app, top: false)
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) {
                XCTAssertFalse(label.frame.intersects(other.frame), "Measurement labels must not cover each other: \(label.identifier), \(other.identifier)")
            }
        }
        attachScreenshot(app, name: "garment-preview-measurement-result")

        app.buttons["garmentResultActions"].tap()
        let enlargePhoto = app.buttons["enlargeGarmentPhoto"]
        XCTAssertTrue(enlargePhoto.waitForExistence(timeout: 5))
        enlargePhoto.tap()
        XCTAssertTrue(app.navigationBars["촬영 사진"].waitForExistence(timeout: 5))
        app.buttons["확대"].tap()
        XCTAssertTrue(app.buttons["축소"].exists)
        app.navigationBars["촬영 사진"].buttons["닫기"].tap()
        XCTAssertTrue(waist.waitForExistence(timeout: 5))
        waist.tap()
        XCTAssertTrue(app.navigationBars["허리 단면"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "별도 기록")).firstMatch.exists)
        app.navigationBars["허리 단면"].buttons["닫기"].tap()

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

        let shoulder = app.buttons["garmentMeasurementLabel_top.shoulderWidth"]
        let chest = app.buttons["garmentMeasurementLabel_top.chestWidth"]
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
        XCTAssertTrue(magnifier.waitForExistence(timeout: 5))
        let rightShoulder = app.buttons["garmentMeasurementPoint_shoulder_right"]
        rightShoulder.tap()
        expectation(for: NSPredicate(format: "value == %@", try XCTUnwrap(rightShoulder.value as? String)),
                    evaluatedWith: magnifier)
        waitForExpectations(timeout: 5)
        point.tap()
        expectation(for: NSPredicate(format: "value == %@", originalPoint), evaluatedWith: magnifier)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: shoulder.label)), originalShoulder,
                       "Selecting a point must not change the measurement")
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: photo.frame.width * 0.05, dy: photo.frame.height * 0.025)))
        waitForChangedCentimeters(shoulder, from: originalShoulder)
        XCTAssertNotEqual(point.value as? String, originalPoint)
        XCTAssertTrue(magnifier.exists, "The selected point must remain available for inspection after dragging")
        XCTAssertEqual(magnifier.value as? String, point.value as? String)
        XCTAssertTrue(magnifier.label.contains("어깨"))
        XCTAssertLessThanOrEqual(magnifier.frame.minX, photo.frame.minX + 20)
        XCTAssertLessThanOrEqual(magnifier.frame.minY, photo.frame.minY + 20)
        XCTAssertTrue(photo.frame.contains(magnifier.frame), "The loupe must fit inside the photo's upper-left corner")

        let correctedShoulder = try XCTUnwrap(Self.centimeters(in: shoulder.label))
        XCTAssertLessThan(correctedShoulder, originalShoulder)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: chest.label)), originalChest,
                       "Moving a shoulder must preserve an unrelated chest measurement")
        XCTAssertTrue(app.staticTexts["garmentSyntheticResult"].exists)
        attachScreenshot(app, name: "garment-top-drag-selected-magnifier-and-correction")
        openResultDetails(in: app)
        let adjustment = app.descendants(matching: .any)["garmentMeasurementAdjustmentStatus"].firstMatch
        XCTAssertTrue(adjustment.waitForExistence(timeout: 5))
        reveal(adjustment, in: app)
        XCTAssertTrue(adjustment.label.contains("수동"))
        closeResultDetails(in: app)

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
        let shoulder = app.buttons["garmentMeasurementLabel_top.shoulderWidth"]
        let chest = app.buttons["garmentMeasurementLabel_top.chestWidth"]
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

        // Select the opposite point first, so the peripheral drag must also
        // select the intended left shoulder rather than retaining the loupe.
        otherPoint.tap()
        expectation(for: NSPredicate(format: "value == %@", originalOtherPoint), evaluatedWith: magnifier)
        waitForExpectations(timeout: 5)
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
        XCTAssertEqual(magnifier.value as? String, point.value as? String)
        XCTAssertTrue(magnifier.label.contains("왼쪽 어깨"))
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
        let chest = app.buttons["garmentMeasurementLabel_top.chestWidth"]
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
        XCTAssertEqual(magnifier.value as? String, left.value as? String)
        XCTAssertTrue(magnifier.label.contains("왼쪽 겨드랑이"))
        XCTAssertTrue(confirm.isEnabled)
        attachScreenshot(app, name: "garment-close-armpit-points-select-and-drag-nearest-marker")
    }

    @MainActor
    func testResettingDraggedBottomPointRestoresOriginalAndRetakeClearsSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPointEditingPreview(in: app)
        let waist = app.buttons["garmentMeasurementLabel_bottom.waist_left.waist_right"]
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
        XCTAssertTrue(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        openResultDetails(in: app)
        let reset = app.buttons["resetGarmentMeasurementPoints"]
        reveal(reset, in: app)
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        closeResultDetails(in: app)
        expectation(for: NSPredicate(format: "value == %@", originalPoint), evaluatedWith: point)
        waitForExpectations(timeout: 5)
        waitForCentimeters(waist, equalTo: originalWaist)
        XCTAssertEqual(try XCTUnwrap(Self.centimeters(in: waist.label)), originalWaist)
        attachScreenshot(app, name: "garment-bottom-drag-reset-original-measurement")

        app.buttons["retakeGarmentMeasurement"].tap()
        let recognize = app.buttons["previewRecognizeGarment"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        recognize.tap()
        app.buttons["captureGarment"].tap()
        XCTAssertTrue(app.buttons["confirmGarmentMeasurement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch.exists)
        XCTAssertEqual(point.value as? String, originalPoint)
        openResultDetails(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["garmentMeasurementAdjustmentStatus"].firstMatch.exists)
        closeResultDetails(in: app)
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
        let actual = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "garmentMeasurementLabel_")).allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(actual, Set(selected.map { "garmentMeasurementLabel_" + $0 }), file: file, line: line)
        let unusedPoints = top ? ["sleeve_end_right", "hem_left", "hem_right"] : ["hem_right_inner", "hem_right_outer"]
        for id in unusedPoints {
            XCTAssertFalse(app.buttons["garmentMeasurementPoint_" + id].exists,
                           "The unused side must not show an editable handle: \(id)", file: file, line: line)
        }
        let selectedPoints = top
            ? ["sleeve_end_left", "shoulder_right", "hem_center", "neck_left", "neck_right", "armpit_left", "armpit_right"]
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
    private func openResultDetails(in app: XCUIApplication) {
        let actions = app.buttons["garmentResultActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        let details = app.buttons["openGarmentMeasurementDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        let close = app.buttons["closeGarmentMeasurementDetails"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in close.isHittable }, evaluatedWith: close)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(close.isHittable)
    }

    @MainActor
    private func closeResultDetails(in app: XCUIApplication) {
        let close = app.buttons["closeGarmentMeasurementDetails"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in close.isHittable }, evaluatedWith: close)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(close.isHittable)
        close.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: close)
        waitForExpectations(timeout: 5)
        let confirm = app.buttons["confirmGarmentMeasurement"]
        expectation(for: NSPredicate { _, _ in confirm.isHittable }, evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(confirm.isHittable,
                      "Closing details must return to the editable result and its confirmation action")
    }

    @MainActor
    private func assertAdvisoryContourGuidance(_ guidance: XCUIElement) {
        XCTAssertTrue(guidance.label.contains("윤곽 미리보기"))
        XCTAssertTrue(guidance.label.contains("촬영 후"))
        XCTAssertFalse(guidance.label.contains("인식 완료"),
                       "An advisory contour must not claim that the captured garment was classified or measured")
    }

    @MainActor
    private func assertPhotoAccessibilityBounds(_ photo: XCUIElement, in app: XCUIApplication) {
        let image = app.images["촬영한 옷과 측정점"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let loupe = app.descendants(matching: .any)["garmentPointMagnifier"].firstMatch
        let frames = "Photo \(photo.frame), image \(image.frame), loupe \(loupe.frame)"
        attachScreenshot(app, name: "garment-point-editor-initial-photo-and-loupe")
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
        let pieces = text.split { $0 == " " || $0 == "," }
        guard pieces.count == 4, pieces[0] == "x", pieces[2] == "y",
              let x = Double(pieces[1]), let y = Double(pieces[3]) else { return nil }
        return CGPoint(x: x, y: y)
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
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        // The full display avoids XCTest cropping a rotated app using its
        // portrait-coordinate bounds on some simulator runtimes.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
