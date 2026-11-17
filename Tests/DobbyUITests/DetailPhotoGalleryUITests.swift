// Created by mason on 10/20/26.
import XCTest

final class DetailPhotoGalleryUITests: XCTestCase {
    @MainActor
    func testBrowsingAndReturnToCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let confirmedLabels = enterDetailCapture(app)
        defer { app.terminate() }
        XCTAssertFalse(confirmedLabels.isEmpty)
        let guide = app.buttons["camera.startDetailCapture"]
        let capture = app.buttons["camera.captureDetail"]
        for _ in 0..<2 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        assertFocused(app, index: 3, total: 4)
        XCTAssertGreaterThan(app.buttons["camera.galleryThumbnail.3"].frame.width,
                             app.buttons["camera.galleryThumbnail.2"].frame.width)
        let strip = app.scrollViews["camera.galleryStrip"]
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        assertFocused(app, index: 0, total: 4)
        XCTAssertGreaterThan(app.buttons["camera.galleryThumbnail.3"].frame.midX, app.frame.midX)
        app.buttons["camera.galleryThumbnail.3"].tap()
        assertFocused(app, index: 3, total: 4)
        pager.swipeRight()
        assertFocused(app, index: 2, total: 4)
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertPage(pager, "1 / 4")
        XCTAssertTrue(app.buttons["camera.galleryDelete"].isEnabled)
        app.buttons["camera.galleryThumbnail.1"].tap()
        assertPage(pager, "2 / 4")
        XCTAssertTrue(app.buttons["camera.galleryDelete"].isEnabled)
        let annotated = app.descendants(matching: .any)["camera.galleryMeasurement"].firstMatch
        XCTAssertTrue(annotated.waitForExistence(timeout: 5))
        XCTAssertTrue((annotated.value as? String)?.contains("cm") == true)
        for label in confirmedLabels {
            let fields = label.components(separatedBy: ", ")
            XCTAssertGreaterThanOrEqual(fields.count, 2)
            XCTAssertTrue((annotated.value as? String)?.contains(fields.prefix(2).joined(separator: " ")) == true)
        }
        XCTAssertFalse(app.buttons["enlargeGarmentPhoto"].exists)
        let measurementShot = XCTAttachment(screenshot: app.screenshot())
        measurementShot.name = "measurement-photo-gallery"; measurementShot.lifetime = .keepAlways; add(measurementShot)
        app.buttons["camera.galleryThumbnail.2"].tap()
        assertFocused(app, index: 2, total: 4)
        let frames = (0..<4).map { app.buttons["camera.galleryThumbnail.\($0)"].frame }
        let compactGap = frames[1].minX - frames[0].maxX
        XCTAssertGreaterThan(frames[2].minX - frames[1].maxX, compactGap)
        XCTAssertGreaterThan(frames[3].minX - frames[2].maxX, compactGap)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-photo-gallery"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["camera.galleryDelete"].isEnabled)
        XCTAssertEqual(pager.value as? String, "3 / 4")
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertFalse(guide.exists)
        capture.tap()
        let next = app.buttons["camera.selectPhotos"]
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        assertInformationPhotoCount(app, count: 5)
    }

    @MainActor
    func testMeasurementOnlyGalleryCentersBothEnds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        app.buttons["camera.openGallery"].tap()
        assertFocused(app, index: 0, total: 2)
        app.buttons["camera.galleryThumbnail.1"].tap()
        assertFocused(app, index: 1, total: 2)
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertFocused(app, index: 0, total: 2)
        XCTAssertFalse(app.buttons["camera.galleryThumbnail.2"].exists)
        XCTAssertTrue(app.buttons["camera.galleryDelete"].isEnabled)
    }

    @MainActor
    func testOverflowingFilmstripScrollsToBothEndsAndReopensAtLatest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        let capture = app.buttons["camera.captureDetail"]
        // 실측 2개 + 상세 16개: iPhone 17의 화면 너비를 넘는 필름스트립.
        for _ in 0..<16 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        assertFocused(app, index: 17, total: 18)
        let strip = app.scrollViews["camera.galleryStrip"]
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        for _ in 0..<6 {
            if pager.value as? String == "1 / 18" { break }
            strip.swipeRight()
        }
        assertFocused(app, index: 0, total: 18)
        for _ in 0..<6 {
            if pager.value as? String == "18 / 18" { break }
            strip.swipeLeft()
        }
        assertFocused(app, index: 17, total: 18)
        pager.swipeRight()
        assertFocused(app, index: 16, total: 18)
        app.buttons["촬영으로 돌아가기"].tap()
        XCTAssertTrue(gallery.wait(for: \.isHittable, toEqual: true, timeout: 10)); gallery.tap()
        assertFocused(app, index: 17, total: 18)
    }

    @MainActor
    func testDeletionCancelAllTypesAndRecapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        let capture = app.buttons["camera.captureDetail"]
        for _ in 0..<2 {
            XCTAssertTrue(capture.wait(for: \.isEnabled, toEqual: true, timeout: 10)); capture.tap()
        }
        let gallery = app.buttons["camera.openGallery"]
        XCTAssertTrue(gallery.wait(for: \.isEnabled, toEqual: true, timeout: 10)); gallery.tap()
        assertFocused(app, index: 3, total: 4)
        XCTAssertFalse(app.alerts["camera.galleryDeleteConfirmation"].exists,
            "닫힌 확인창이 빈 접근성 알림으로 남으면 안 된다")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "gallery-trash-layout"; before.lifetime = .keepAlways; add(before)
        let trashFrame = app.buttons["camera.galleryDelete"].frame
        app.buttons["camera.galleryDelete"].tap()
        let delete = app.buttons["camera.galleryConfirmDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        // 유리 배경은 접근성 프레임에 포함되지 않으므로 버튼과 내부 여백 14pt로 검증한다.
        XCTAssertEqual(delete.frame.width + 28, 300, accuracy: 1)
        XCTAssertEqual(app.frame.maxX - delete.frame.maxX - 14, 20, accuracy: 1)
        let gapAboveTrash = trashFrame.minY - delete.frame.maxY - 14
        // 시스템 글라스 버튼의 접근성 경계는 보이는 원보다 작을 수 있다.
        XCTAssertGreaterThanOrEqual(gapAboveTrash, 0, "확인창과 휴지통이 겹치면 안 된다")
        XCTAssertLessThanOrEqual(gapAboveTrash, 32, "확인창은 하단 조작 영역 바로 위에 있어야 한다")
        // 확인창 내부의 설명을 탭해도 취소나 삭제가 발생하지 않는다.
        app.staticTexts["삭제된 사진은 복구할 수 없어요"].tap()
        XCTAssertTrue(delete.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gallery-delete-confirmation"; shot.lifetime = .keepAlways; add(shot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(delete.wait(for: \.exists, toEqual: false, timeout: 5))
        XCTAssertFalse(app.alerts["camera.galleryDeleteConfirmation"].exists)
        assertFocused(app, index: 3, total: 4)
        XCTAssertTrue(app.buttons["camera.galleryDelete"].isHittable)
        // 하단 버튼 영역도 확인창 외부다. 취소만 하고 사진은 유지한다.
        app.buttons["camera.galleryDelete"].tap()
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: trashFrame.midX, dy: trashFrame.midY)).tap()
        XCTAssertTrue(delete.wait(for: \.exists, toEqual: false, timeout: 5))
        XCTAssertFalse(app.alerts["camera.galleryDeleteConfirmation"].exists)
        assertFocused(app, index: 3, total: 4)
        app.buttons["camera.galleryDelete"].tap(); delete.tap()
        assertFocused(app, index: 2, total: 3)
        app.buttons["camera.galleryThumbnail.0"].tap()
        assertFocused(app, index: 0, total: 3)
        app.buttons["camera.galleryDelete"].tap(); delete.tap()
        assertFocused(app, index: 0, total: 2)
        app.buttons["camera.galleryDelete"].tap(); delete.tap()
        assertFocused(app, index: 0, total: 1)
        app.buttons["camera.galleryDelete"].tap(); delete.tap()
        XCTAssertTrue(capture.wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertFalse(gallery.isEnabled)
        let next = app.buttons["camera.selectPhotos"]
        XCTAssertFalse(next.isEnabled)
        capture.tap()
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        assertInformationPhotoCount(app, count: 1)
    }
    @MainActor
    func testDeletedPhotosStayExcludedAfterInformationHandoffAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        _ = enterDetailCapture(app)
        defer { app.terminate() }
        tapReady(app, "camera.captureDetail")
        tapReady(app, "camera.captureDetail")
        tapReady(app, "camera.selectPhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        let originalIDs = informationPhotoIDs(app)
        XCTAssertEqual(originalIDs.count, 4)
        tapReady(app, "product-flow.back")
        tapReady(app, "camera.openGallery")
        tapReady(app, "camera.galleryThumbnail.1")
        assertFocused(app, index: 1, total: 4)
        tapReady(app, "camera.galleryDelete")
        tapReady(app, "camera.galleryConfirmDelete") // 저장된 실측 표시본 제외
        assertFocused(app, index: 1, total: 3)
        tapReady(app, "camera.galleryDelete")
        tapReady(app, "camera.galleryConfirmDelete") // 그 다음 상세 컷 제외
        assertFocused(app, index: 1, total: 2)
        tapReady(app, "촬영으로 돌아가기")
        tapReady(app, "camera.selectPhotos")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        let remainingIDs = [originalIDs[0], originalIDs[3]]
        XCTAssertEqual(informationPhotoIDs(app), remainingIDs)
        app.terminate()
        app.launch()
        tapReady(app, "home.resume")
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 30))
        XCTAssertEqual(informationPhotoIDs(app), remainingIDs, "삭제된 사진이 초안 복원으로 되살아나면 안 된다")
        tapReady(app, "product-flow.back")
        tapReady(app, "camera.openGallery")
        assertFocused(app, index: 1, total: 2)
    }

    @MainActor
    private func tapReady(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 20), identifier)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        button.tap()
    }

    @MainActor
    private func assertInformationPhotoCount(_ app: XCUIApplication, count: Int) {
        let header = app.descendants(matching: .any).matching(identifier: "product-info.photo-count").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.label, "제품 사진 \(count)장, 최대 10장")
    }

    @MainActor
    private func informationPhotoIDs(_ app: XCUIApplication) -> [String] {
        let countHeader = app.descendants(matching: .any).matching(identifier: "product-info.photo-count").firstMatch
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
    private func enterDetailCapture(_ app: XCUIApplication) -> [String] {
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString,
                               "--garment-preview-top"]
        app.launch()
        startMeasurementFromHome(in: app)
        let measure = app.buttons["captureGarment"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15))
        armSyntheticGarmentCapture(in: app)
        measure.tap()
        let confirm = app.buttons["confirmGarmentMeasurement"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        let labels = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "garmentMeasurementLabel_")).allElementsBoundByIndex.map(\.label)
        confirm.tap()
        let guide = app.buttons["camera.startDetailCapture"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10)); guide.tap()
        return labels
    }

    @MainActor
    private func assertFocused(_ app: XCUIApplication, index: Int, total: Int) {
        let pager = app.descendants(matching: .any)["camera.galleryPager"].firstMatch
        assertPage(pager, "\(index + 1) / \(total)")
        let thumbnail = app.buttons["camera.galleryThumbnail.\(index)"]
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(thumbnail.frame.midX - app.frame.midX) < 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        XCTAssertTrue(thumbnail.isSelected)
        XCTAssertEqual(thumbnail.value as? String, "현재 보는 사진")
    }
    @MainActor
    private func assertPage(_ pager: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
