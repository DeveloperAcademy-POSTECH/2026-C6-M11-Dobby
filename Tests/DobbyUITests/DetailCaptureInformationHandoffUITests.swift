// Created by mason on 11/8/26.
import XCTest

final class DetailCaptureInformationHandoffUITests: XCTestCase {
    @MainActor
    func testMeasurementOnlyAndMoreThanTenPhotosReachInformation() {
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
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 2) // 실측 원본과 표시본은 상세 컷 없이도 전달된다.
        let measurementIDs = informationPhotoIDs(app)
        tap(app, "product-flow.back")
        for _ in 0..<9 { tap(app, "camera.captureDetail") }
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 11) // 폐기된 선택 화면의 최대 10장 제한을 적용하지 않는다.
        let allIDs = informationPhotoIDs(app)
        XCTAssertEqual(Array(allIDs.prefix(2)), measurementIDs)
        XCTAssertEqual(Set(allIDs).count, 11)
        tap(app, "product-flow.back")
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 11)
        XCTAssertEqual(informationPhotoIDs(app), allIDs)
        reveal(app.descendants(matching: .any)["product-info.photo-count"].firstMatch, in: app, towardStart: true)
        attachScreenshot(app, name: "product-info-overflow-11")

        enterRequiredInformation(in: app)
        let done = app.buttons["product-info.done"]
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].exists,
                      "An enabled Done button must still enforce the ten-photo registration limit")
        XCTAssertFalse(app.buttons["product-complete.export"].exists)
        let removedPhotoID = allIDs[0]
        let deleteID = removedPhotoID.replacingOccurrences(of: "product-info.photo.", with: "product-info.delete-photo.")
        reveal(app.buttons[deleteID], in: app, towardStart: true)
        tap(app, deleteID)
        assertInformation(app, count: 10)
        XCTAssertEqual(informationPhotoIDs(app), Array(allIDs.dropFirst()))
        XCTAssertTrue(done.wait(for: \.isEnabled, toEqual: true, timeout: 10),
                      "Removing overflow must restore completion once the remaining required information is valid")
        reveal(app.descendants(matching: .any)["product-info.photo-count"].firstMatch, in: app, towardStart: true)
        attachScreenshot(app, name: "product-info-repaired-10")
    }

    @MainActor
    func testRelaunchResumesInformationAndBackKeepsCaptureSession() {
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
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 3)
        let photoIDs = informationPhotoIDs(app)

        // Recreate the flow from its durable draft rather than live view state.
        app.terminate()
        app.launch()
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(resume.label.contains("제품 정보 입력 단계"))
        tap(app, "home.resume")
        assertInformation(app, count: 3)
        XCTAssertEqual(informationPhotoIDs(app), photoIDs)
        XCTAssertTrue(app.buttons["product-info.done"].isEnabled)
        tap(app, "product-flow.back")
        XCTAssertTrue(app.buttons["camera.captureDetail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews["camera.selectionGrid"].exists)
        XCTAssertFalse(app.staticTexts["product-flow.exit-title"].exists)
        XCTAssertFalse(app.buttons["camera.startDetailCapture"].exists)
        tap(app, "camera.openGallery")
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        XCTAssertEqual(pager.value as? String, "3 / 3")
        tap(app, "촬영으로 돌아가기")
        tap(app, "camera.selectPhotos")
        assertInformation(app, count: 3)
        XCTAssertEqual(informationPhotoIDs(app), photoIDs, "복귀·재완료로 사진을 다시 생성하지 않는다")
    }

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
        let doneExists = app.buttons["product-info.done"].waitForExistence(timeout: 30)
        let nameExists = app.descendants(matching: .any)["product-info.name"].firstMatch.waitForExistence(timeout: 5)
        let countHeader = app.staticTexts.matching(identifier: "product-info.photo-count").firstMatch
        let countExists = countHeader.waitForExistence(timeout: 5)
        let expectedLabel = "제품 사진 \(count)장, 최대 10장"
        if !doneExists || !nameExists || !countExists || countHeader.label != expectedLabel {
            attachInformationDiagnostic(app, name: "product-info-readiness-\(count)")
        }
        XCTAssertTrue(doneExists, "Information entry must expose its completion control, including while disabled")
        XCTAssertTrue(nameExists, "Information entry must expose its product-name field")
        XCTAssertFalse(app.scrollViews["camera.selectionGrid"].exists)
        XCTAssertTrue(countExists)
        XCTAssertEqual(countHeader.label, expectedLabel)
        XCTAssertFalse(app.staticTexts["product-info.photos.empty"].exists)
    }

    @MainActor
    private func informationPhotoIDs(_ app: XCUIApplication) -> [String] {
        let countHeader = app.staticTexts.matching(identifier: "product-info.photo-count").firstMatch
        guard let expectedCount = countHeader.label.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) else {
            attachInformationDiagnostic(app, name: "product-info-photo-count-unreadable")
            XCTFail("The photo-count header must expose the actual registered count")
            return []
        }
        reveal(countHeader, in: app, towardStart: true)
        let strip = app.collectionViews["product-info.photo-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let maximumSwipes = max(8, expectedCount * 2)
        guard resetPhotoStripToStart(strip, maximumSwipes: maximumSwipes) else {
            attachInformationDiagnostic(app, name: "product-info-photo-strip-start")
            XCTFail("The photo strip must return to its leading add-photo cell before reading order")
            return []
        }

        var orderedIDs: [String] = []
        var seen = Set<String>()
        var stalledPasses = 0
        for pass in 0...maximumSwipes {
            let previousCount = orderedIDs.count
            let visiblePhotos = strip.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
                .allElementsBoundByIndex.filter { $0.frame.intersects(strip.frame) }
                .sorted { $0.frame.minX < $1.frame.minX }
            for photo in visiblePhotos where seen.insert(photo.identifier).inserted {
                orderedIDs.append(photo.identifier)
            }
            if orderedIDs.count >= expectedCount { break }
            stalledPasses = orderedIDs.count == previousCount ? stalledPasses + 1 : 0
            if stalledPasses >= 3 || pass == maximumSwipes { break }
            dragPhotoStrip(strip, towardStart: false)
        }
        if orderedIDs.count != expectedCount {
            attachInformationDiagnostic(app, name: "product-info-photo-strip-incomplete")
        }
        XCTAssertEqual(orderedIDs.count, expectedCount, "Every registered photo must be reachable in the virtualized native strip")
        let restoredStart = resetPhotoStripToStart(strip, maximumSwipes: maximumSwipes)
        if !restoredStart {
            attachInformationDiagnostic(app, name: "product-info-photo-strip-reset")
        }
        XCTAssertTrue(restoredStart, "Reading photo IDs must leave the first photo available for deletion and later checks")
        return orderedIDs
    }

    @MainActor
    private func resetPhotoStripToStart(_ strip: XCUIElement, maximumSwipes: Int) -> Bool {
        let addPhoto = strip.buttons.matching(identifier: "product-info.add-photo").firstMatch
        for pass in 0...maximumSwipes {
            // Overflow disables Add, so frame visibility identifies the start
            // without requiring that button to be enabled or hittable.
            if addPhoto.exists, !addPhoto.frame.isEmpty,
               strip.frame.insetBy(dx: -1, dy: -1).contains(addPhoto.frame) { return true }
            if pass < maximumSwipes { dragPhotoStrip(strip, towardStart: true) }
        }
        return false
    }

    @MainActor
    private func dragPhotoStrip(_ strip: XCUIElement, towardStart: Bool) {
        // Short overlapping drags visit every cell while avoiding the remove
        // badges at the top of each thumbnail.
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: towardStart ? 0.2 : 0.8, dy: 0.8))
        let end = strip.coordinate(withNormalizedOffset: CGVector(dx: towardStart ? 0.8 : 0.2, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func attachInformationDiagnostic(_ app: XCUIApplication, name: String) {
        attachScreenshot(app, name: name)
        let diagnostic = XCTAttachment(string: app.debugDescription)
        diagnostic.name = "\(name)-hierarchy"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func enterRequiredInformation(in app: XCUIApplication) {
        for (key, text) in [("name", "Overflow jacket"), ("detail", "Captured photos retained"), ("price", "40000")] {
            let field = key == "detail" ? app.textViews["product-info.detail"] : app.textFields["product-info.\(key)"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            reveal(field, in: app)
            XCTAssertTrue(field.isHittable)
            if key == "detail" {
                let barBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                    .map { $0.frame.maxY }.max() ?? 100
                let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
                let visibleTop = max(field.frame.minY, barBottom + 12)
                let visibleBottom = min(field.frame.maxY, keyboardTop - 12)
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: field.frame.midX,
                    dy: (visibleTop + min(visibleBottom, visibleTop + 44)) / 2)).tap()
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            field.typeText(text)
            let valueMatches = expectation(for: NSPredicate(format: "value == %@", key == "price" ? "40,000" : text),
                                           evaluatedWith: field)
            wait(for: [valueMatches], timeout: 5)
        }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardStart: Bool = false) {
        for _ in 0..<14 {
            let bar = app.navigationBars.allElementsBoundByIndex.last
            let top = (bar?.frame.maxY ?? 68) + 12
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY - 12 : app.frame.maxY - 60
            if element.isHittable {
                if element.identifier == "product-info.detail",
                   min(element.frame.maxY, bottom) - max(element.frame.minY, top) >= 44 { return }
                if element.frame.minY >= top, element.frame.maxY <= bottom { return }
            }
            let frame = element.frame
            let hasVisibleHorizontalFrame = !frame.isEmpty && !frame.isNull && !frame.isInfinite
                && frame.maxX > app.frame.minX && frame.minX < app.frame.maxX
            let goDown = towardStart || (element.exists && hasVisibleHorizontalFrame && frame.minY < top)
            let height = max(40, bottom - top)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.30 : 0.80) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.97,
                dy: top + height * (goDown ? 0.80 : 0.30) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), identifier)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }
}
