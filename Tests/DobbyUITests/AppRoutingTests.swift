import UIKit
import XCTest

/// Checks the actual capture/library home and URL delivery. Flow fixtures use
/// isolated stores. The tab color check only visits the three main screens.
final class AppRoutingTests: XCTestCase {
    @MainActor
    func testMainTabBrandColorsFollowSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The default test scheme sets a store token, which adds an orange preview banner behind the glass.
        app.launchEnvironment["DOBBY_FLOW_TEST_STORE_TOKEN"] = ""
        app.launch()
        defer { app.terminate() }

        let titles = ["홈", "보관함", "설정"]
        for title in titles {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            if !tab.isSelected { tab.tap() }
            XCTAssertTrue(tab.wait(for: \.isSelected, toEqual: true, timeout: 5))
            XCTAssertFalse(app.staticTexts["연결 흐름 미리보기 · 합성 측정값"].exists)

            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "main-tab-colors-\(title)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let screen = app.frame
            let scaleX = CGFloat(image.width) / screen.width
            let scaleY = CGFloat(image.height) / screen.height
            for name in titles {
                let button = app.tabBars.buttons[name]
                let frame = button.frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
                    .applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
                let regions = frame.divided(atDistance: frame.height * 0.62, from: .minYEdge)
                for (part, region) in [("아이콘", regions.slice), ("제목", regions.remainder)] {
                    let crop = try XCTUnwrap(image.cropping(to: region.integral))
                    let counts = try tabInkCounts(in: crop)
                    let message = "\(title) 선택 중 \(name) \(part) · black \(counts.black), neutral600 \(counts.neutral)"
                    if name == title {
                        XCTAssertGreaterThan(counts.black, max(3, counts.neutral), message)
                    } else {
                        XCTAssertGreaterThan(counts.neutral, 3, message)
                        XCTAssertEqual(counts.black, 0, message)
                    }
                }
            }
        }
    }

    private func tabInkCounts(in image: CGImage) throws -> (black: Int, neutral: Int) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var black = 0
        var neutral = 0
        // Count ink inside the glyphs, allowing four sRGB levels for antialiasing.
        for i in stride(from: 0, to: image.height * context.bytesPerRow, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if abs(r - 16) <= 4 && abs(g - 16) <= 4 && abs(b - 15) <= 4 { black += 1 }
            if abs(r - 111) <= 4 && abs(g - 106) <= 4 && abs(b - 99) <= 4 { neutral += 1 }
        }
        return (black, neutral)
    }

    @MainActor
    func testDraggingSelectedTabToSettingsSwitchesScreens() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        let home = app.tabBars.buttons["홈"]
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(home.isSelected)
        let center = CGVector(dx: 0.5, dy: 0.5)
        home.coordinate(withNormalizedOffset: center).press(forDuration: 0.3,
            thenDragTo: settings.coordinate(withNormalizedOffset: center),
            withVelocity: .slow, thenHoldForDuration: 0.15)

        XCTAssertTrue(app.buttons["개인정보 처리방침"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isSelected)
        XCTAssertFalse(home.isSelected)
        attachScreenshot(app, name: "settings-after-tab-drag")

        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(app.buttons["library.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testCaptureAndEmptyLibraryRemainReachableWithLabHidden() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        expectHome(in: app)

        // This launches the explicitly labelled synthetic creation flow. Exit
        // before shutter/confirmation, so no product or measurement is stored.
        app.buttons["product-flow.start"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["captureGarment"].isEnabled)
        XCTAssertEqual(app.buttons["captureGarment"].value as? String, "옷 인식 대기")
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].exists)
        app.buttons["closeGarmentCapture"].tap()
        expectHome(in: app)

        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        let editLibrary = app.buttons["library.edit-mode"]
        XCTAssertTrue(editLibrary.waitForExistence(timeout: 5))
        XCTAssertEqual(editLibrary.label, "수정")
        XCTAssertFalse(editLibrary.isEnabled)
        attachScreenshot(app, name: "routing-empty-library-start-measurement")
        app.buttons["library.empty.start-measurement"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["product-flow.fixture"].exists)
        app.buttons["closeGarmentCapture"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertFalse(editLibrary.isEnabled)
        XCTAssertTrue(app.tabBars.buttons["보관함"].isSelected)
        app.tabBars.buttons["홈"].tap()
        expectHome(in: app)
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected)
        attachScreenshot(app, name: "routing-home-capture-library")

        // 탭 왕복 후에도 중간 화면 없이 실측 촬영으로 진입합니다.
        app.buttons["product-flow.start"].tap()
        XCTAssertTrue(app.buttons["captureGarment"].waitForExistence(timeout: 10))
        app.buttons["closeGarmentCapture"].tap()
        expectHome(in: app)
    }

    @MainActor
    func testColdCopyHomeWithoutSessionShowsGuidanceAndKeepsLibraryEmpty() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        app.terminate()

        // The route requests the current helper, with no copy field or foreign
        // destination. An absent/expired helper must not construct a demo item.
        // XCUIApplication.open launches/relaunches the app in this runner. Use
        // an explicit cold launch; this does not verify warm tab preservation.
        // The production nil-session guard only sets its alert and returns.
        app.open(URL(string: "dobby-copy://home")!)
        let alert = app.alerts["내보내기를 열 수 없어요"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "진행 중인 복사 도우미가 없어요")).firstMatch.exists)
        XCTAssertFalse(app.buttons["export.close"].exists)
        XCTAssertFalse(app.navigationBars["내보내기"].exists)
        XCTAssertFalse(app.navigationBars["상품 정보 복사"].exists)
        attachScreenshot(app, name: "routing-cold-url-empty-helper-guidance")
        alert.buttons["확인"].tap()

        expectHome(in: app)
        XCTAssertTrue(app.tabBars.buttons["홈"].isSelected)
        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)
        XCTAssertTrue(app.tabBars.buttons["보관함"].isSelected)
        XCTAssertFalse(app.buttons["export.close"].exists)
        XCTAssertFalse(app.buttons["closeLiDARLab"].exists)
        app.tabBars.buttons["홈"].tap()
        expectHome(in: app)
    }

    @MainActor
    func testDebugExportSampleOpensRealLibraryExportFlowWithoutDuplicates() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        app.tabBars.buttons["보관함"].tap()
        expectEmptyLibrary(in: app)

        let sampleButton = app.buttons["debug.export-sample"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 5))
        sampleButton.tap()

        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let photos = app.descendants(matching: .any)["product-detail.photos"].firstMatch
        let name = app.descendants(matching: .any)["product-detail.name"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertTrue(name.exists)
        XCTAssertLessThanOrEqual(photos.frame.maxY, name.frame.minY)
        XCTAssertTrue(name.staticTexts["90s 나이키 트랙탑"].exists)

        let exportButton = app.buttons["library.export"]
        XCTAssertTrue(exportButton.isHittable, "The upload action stays fixed below the detail content")
        attachScreenshot(app, name: "debug-library-detail-top")

        let photoButtons = app.buttons.matching(NSPredicate(format: "label == %@", "제품 사진 확대"))
        let photoCount = photoButtons.count
        XCTAssertGreaterThan(photoCount, 2)
        let secondPhoto = photoButtons.element(boundBy: 1)
        XCTAssertTrue(secondPhoto.isHittable)
        secondPhoto.tap()
        let pager = app.descendants(matching: .any)["product-gallery.pager"].firstMatch
        assertGalleryPage(pager, in: app, page: 2, total: photoCount)
        XCTAssertFalse(app.buttons["product-gallery.delete"].exists)
        let pageControl = app.descendants(matching: .any)["product-gallery.page-control"].firstMatch
        XCTAssertTrue(pageControl.exists)
        attachScreenshot(app, name: "debug-library-gallery-second-photo")
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        assertGalleryPage(pager, in: app, page: 3, total: photoCount)
        pager.swipeRight()
        assertGalleryPage(pager, in: app, page: 2, total: photoCount)
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        assertGalleryPage(pager, in: app, page: 3, total: photoCount)
        pager.swipeRight()
        assertGalleryPage(pager, in: app, page: 2, total: photoCount)
        attachScreenshot(app, name: "debug-library-gallery-snapped-photo")
        app.buttons["product-gallery.close"].tap()
        XCTAssertTrue(pager.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))

        photoButtons.firstMatch.tap()
        assertGalleryPage(pager, in: app, page: 1, total: photoCount)
        app.buttons["product-gallery.close"].tap()
        XCTAssertTrue(pager.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))

        app.buttons["library.edit"].tap()
        let information = app.navigationBars["제품 정보 수정"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        information.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))

        let price = app.descendants(matching: .any)["product-detail.price"].firstMatch
        reveal(price, in: app)
        XCTAssertTrue(price.staticTexts["89,000 원"].exists)
        XCTAssertTrue(app.staticTexts["나이키"].exists)
        let measurements = app.descendants(matching: .any)["product-detail.measurements"].firstMatch
        for _ in 0..<8 where !measurements.exists || measurements.frame.maxY > exportButton.frame.minY {
            app.swipeUp()
        }
        XCTAssertTrue(measurements.exists)
        XCTAssertLessThanOrEqual(measurements.frame.maxY, exportButton.frame.minY)
        for (key, title, value) in [
            ("shoulderWidth", "어깨", "56cm"),
            ("chestWidth", "가슴", "55cm"),
            ("totalLength", "기장", "68cm"),
            ("sleeveLengthLeft", "소매", "52cm")
        ] {
            let column = app.descendants(matching: .any)["library.measurement.\(key)"].firstMatch
            XCTAssertTrue(column.exists, key)
            XCTAssertTrue(column.staticTexts[title].exists, key)
            XCTAssertTrue(column.staticTexts[value].exists, key)
        }
        XCTAssertTrue(exportButton.isHittable)
        attachScreenshot(app, name: "debug-library-detail-measurements")
        exportButton.tap()

        XCTAssertTrue(app.buttons["export.close"].waitForExistence(timeout: 10))
        let fruits = app.buttons["후르츠패밀리에 업로드하기"]
        reveal(fruits, in: app)
        XCTAssertTrue(fruits.exists)
        attachScreenshot(app, name: "debug-library-sample-export-channels")

        app.buttons["export.close"].tap()
        expectHome(in: app)
        app.tabBars.buttons["보관함"].tap()
        let exportedProduct = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(exportedProduct.waitForExistence(timeout: 5))
        exportedProduct.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))
        app.buttons["library.edit"].tap()
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        let nameInput = app.descendants(matching: .any)["product-info.name"].firstMatch
        reveal(nameInput, in: app)
        tapVisibleInput(nameInput, in: app)
        nameInput.typeText(" 수정")
        let editedName = "90s 나이키 트랙탑 수정"
        XCTAssertEqual(nameInput.value as? String, editedName)
        let done = app.buttons["product-info.done"]
        XCTAssertTrue(done.isEnabled)
        done.tap()

        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 10))
        XCTAssertFalse(information.exists)
        XCTAssertFalse(app.descendants(matching: .any)["product-complete.screen"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["제품 정보 입력 완료 🎉"].exists)
        XCTAssertFalse(app.buttons["product-complete.library"].exists)
        XCTAssertTrue(app.buttons["library.edit"].isHittable)
        XCTAssertTrue(exportButton.isHittable)
        XCTAssertTrue(name.staticTexts[editedName].exists)
        XCTAssertTrue(price.staticTexts["89,000 원"].exists)
        attachScreenshot(app, name: "debug-library-detail-after-edit")

        app.navigationBars[editedName].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["보관함"].isHittable)
        let cardID = "library.product.53E00000-0000-4000-8000-000000000053"
        XCTAssertTrue(app.buttons[cardID].label.contains(editedName))
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "library.product."
        )).count, 1)

        app.buttons["debug.export-sample"].tap()
        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 5))
        app.navigationBars[editedName].buttons.firstMatch.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "library.product."
        )).count, 1)

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let savedCard = app.buttons[cardID]
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10))
        XCTAssertTrue(savedCard.label.contains(editedName))
        savedCard.tap()
        XCTAssertTrue(app.navigationBars[editedName].waitForExistence(timeout: 5))
        XCTAssertTrue(name.staticTexts[editedName].exists)
        XCTAssertFalse(app.buttons["product-complete.library"].exists)
    }

    @MainActor
    func testSavedProductPhotosCanBeDeletedFromThumbnailsAndGalleryAndPersist() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openSavedPhotoSample(in: app)
        XCTAssertEqual(inputPhotoDeleteButtons(in: app).count, 0)
        app.buttons["library.edit"].tap()
        let information = app.navigationBars["제품 정보 수정"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))

        let thumbnails = inputPhotoButtons(in: app)
        let deletes = inputPhotoDeleteButtons(in: app)
        let originalCount = thumbnails.count
        XCTAssertGreaterThan(originalCount, 2)
        XCTAssertEqual(deletes.count, originalCount)
        attachScreenshot(app, name: "saved-product-edit-photo-delete-controls")
        let secondPhotoID = thumbnails.element(boundBy: 1).identifier
            .replacingOccurrences(of: "product-info.photo.", with: "")
        let secondDelete = app.buttons["product-info.delete-photo.\(secondPhotoID)"]
        thumbnails.element(boundBy: 1).tap()

        let pager = app.descendants(matching: .any)["product-gallery.pager"].firstMatch
        assertGalleryPage(pager, in: app, page: 2, total: originalCount)
        let galleryDelete = app.buttons["product-gallery.delete"]
        XCTAssertTrue(galleryDelete.isHittable)
        XCTAssertEqual(galleryDelete.label, "제품 사진 삭제")
        XCTAssertEqual(galleryDelete.frame.width, 48, accuracy: 1)
        XCTAssertEqual(galleryDelete.frame.height, 48, accuracy: 1)
        XCTAssertFalse(galleryDelete.staticTexts["삭제"].exists)
        XCTAssertEqual(pager.frame.maxX - galleryDelete.frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(galleryDelete.frame.minY - pager.frame.minY, 10, accuracy: 1)
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        assertGalleryPage(pager, in: app, page: 3, total: originalCount)
        pager.swipeRight()
        assertGalleryPage(pager, in: app, page: 2, total: originalCount)
        XCTAssertTrue(galleryDelete.isEnabled)
        attachScreenshot(app, name: "saved-product-edit-expanded-photo-delete")
        galleryDelete.tap()
        assertGalleryPage(pager, in: app, page: 2, total: originalCount - 1)
        XCTAssertFalse(secondDelete.exists)
        app.buttons["product-gallery.close"].tap()
        XCTAssertTrue(pager.waitForNonExistence(timeout: 5))
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, originalCount - 1)
        XCTAssertEqual(deletes.count, originalCount - 1)

        let firstDelete = app.buttons[deletes.firstMatch.identifier]
        let firstPhotoID = firstDelete.identifier.replacingOccurrences(of: "product-info.delete-photo.", with: "")
        XCTAssertTrue(firstDelete.isHittable)
        firstDelete.tap()
        XCTAssertTrue(firstDelete.waitForNonExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, originalCount - 2)
        XCTAssertEqual(deletes.count, originalCount - 2)
        app.buttons["product-info.done"].tap()

        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        let detailPhotos = detailPhotoButtons(in: app)
        XCTAssertEqual(detailPhotos.count, originalCount - 2)
        XCTAssertFalse(app.buttons["product-detail.photo.\(secondPhotoID)"].exists)
        XCTAssertFalse(app.buttons["product-detail.photo.\(firstPhotoID)"].exists)
        XCTAssertEqual(deletes.count, 0)
        XCTAssertFalse(app.buttons["product-complete.library"].exists)
        attachScreenshot(app, name: "saved-product-detail-after-photo-deletion")

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        let savedCard = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10))
        savedCard.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))
        XCTAssertEqual(detailPhotos.count, originalCount - 2)
        XCTAssertFalse(app.buttons["product-detail.photo.\(secondPhotoID)"].exists)
        XCTAssertFalse(app.buttons["product-detail.photo.\(firstPhotoID)"].exists)
        app.buttons["library.edit"].tap()
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, originalCount - 2)
        XCTAssertEqual(deletes.count, originalCount - 2)
    }

    @MainActor
    func testDeletingLastSavedProductPhotosClosesGalleryAndPersistsEmptyState() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        openSavedPhotoSample(in: app)
        app.buttons["library.edit"].tap()
        let information = app.navigationBars["제품 정보 수정"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        let thumbnails = inputPhotoButtons(in: app)
        let deletes = inputPhotoDeleteButtons(in: app)
        let originalCount = deletes.count
        XCTAssertGreaterThan(originalCount, 2)
        for remaining in stride(from: originalCount - 1, through: 2, by: -1) {
            let delete = app.buttons[deletes.firstMatch.identifier]
            XCTAssertTrue(delete.isHittable)
            delete.tap()
            XCTAssertTrue(delete.waitForNonExistence(timeout: 5))
            XCTAssertEqual(deletes.count, remaining)
        }
        XCTAssertEqual(thumbnails.count, 2)
        thumbnails.element(boundBy: 1).tap()
        let pager = app.descendants(matching: .any)["product-gallery.pager"].firstMatch
        assertGalleryPage(pager, in: app, page: 2, total: 2)
        let galleryDelete = app.buttons["product-gallery.delete"]
        XCTAssertTrue(galleryDelete.isHittable)
        galleryDelete.tap()
        assertGalleryPage(pager, in: app, page: 1, total: 1)
        XCTAssertFalse(app.descendants(matching: .any)["product-gallery.page-control"].firstMatch.exists)
        galleryDelete.tap()
        XCTAssertTrue(pager.waitForNonExistence(timeout: 5))
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        let empty = app.descendants(matching: .any)["product-info.photos.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, 0)
        XCTAssertEqual(deletes.count, 0)
        attachScreenshot(app, name: "saved-product-edit-without-photos")

        let done = app.buttons["product-info.done"]
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
        XCTAssertEqual(detailPhotoButtons(in: app).count, 0)
        app.navigationBars["90s 나이키 트랙탑"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 5))
        let savedCard = app.buttons["library.product.53E00000-0000-4000-8000-000000000053"]
        XCTAssertTrue(savedCard.isHittable)
        attachScreenshot(app, name: "saved-product-library-without-thumbnail")

        app.terminate()
        app.launch()
        app.tabBars.buttons["보관함"].tap()
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10))
        savedCard.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 5))
        XCTAssertEqual(detailPhotoButtons(in: app).count, 0)
        app.buttons["library.edit"].tap()
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, 0)
        XCTAssertEqual(deletes.count, 0)
    }

    @MainActor
    func testNewProductDescriptionKeepsItsLastLineAboveKeyboardAsItGrows() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        startMeasurementFromHome(in: app)
        armSyntheticGarmentCapture(in: app)
        app.buttons["captureGarment"].tap()
        for identifier in ["confirmGarmentMeasurement", "camera.startDetailCapture", "camera.selectPhotos"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 15), identifier)
            XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 10), identifier)
            button.tap()
        }
        XCTAssertTrue(app.navigationBars["제품 정보 입력"].waitForExistence(timeout: 15))
        let description = app.textViews["product-info.detail"]
        tapVisibleInput(description, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertEditorBottomAboveKeyboard(description, in: app)
        let initialHeight = description.frame.height
        description.typeText(String(repeating: "line\n", count: 14) + "end")
        XCTAssertTrue((description.value as? String)?.hasSuffix("end") == true)
        XCTAssertGreaterThan(description.frame.height, initialHeight)
        assertEditorBottomAboveKeyboard(description, in: app)
        attachKeyboardScreenshot("new-product-description-keyboard")
    }

    @MainActor
    func testSavedProductEditorsMoveAboveKeyboard() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }

        let library = app.buttons["보관함"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        let edit = app.buttons["library.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.navigationBars["제품 정보 수정"].waitForExistence(timeout: 5))
        let description = app.textViews["product-info.detail"]
        let originalHeight = description.frame.height
        tapVisibleInput(description, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let originalText = description.value as? String
        let addedText = String(repeating: "\n", count: 16) + "end"
        description.typeText(addedText)
        XCTAssertTrue((description.value as? String)?.contains("end") == true)
        XCTAssertGreaterThan(description.frame.height, originalHeight)
        assertEditorBottomAboveKeyboard(description, in: app)
        attachKeyboardScreenshot("saved-product-description-keyboard")

        description.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: addedText.count))
        XCTAssertEqual(description.value as? String, originalText)
        XCTAssertEqual(description.frame.height, originalHeight, accuracy: 1)
        assertEditorBottomAboveKeyboard(description, in: app)

        dismissKeyboardByTappingBackground(beside: description, in: app)
        let price = app.textFields["product-info.price"]
        reveal(price, in: app)
        tapVisibleInput(price, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertEditorBottomAboveKeyboard(price, in: app)
    }

    @MainActor
    private func assertEditorBottomAboveKeyboard(_ editor: XCUIElement, in app: XCUIApplication,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let occlusion = app.frame.intersection(keyboard.frame)
            // A simulated hardware keyboard can leave an AX keyboard entirely offscreen.
            return occlusion.height > 100 && editor.frame.maxY <= occlusion.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Editor \(editor.frame), keyboard \(keyboard.frame), app \(app.frame)",
                       file: file, line: line)
    }

    @MainActor
    private func attachKeyboardScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProductInformationBackgroundTapDismissesKeyboardsWithoutLosingInput() {
        continueAfterFailure = false
        let app = fixtureApp()
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["보관함"].tap()
        app.buttons["debug.export-sample"].tap()
        XCTAssertTrue(app.buttons["library.edit"].waitForExistence(timeout: 10))
        app.buttons["library.edit"].tap()
        XCTAssertTrue(app.navigationBars["제품 정보 수정"].waitForExistence(timeout: 5))

        let name = app.descendants(matching: .any)["product-info.name"].firstMatch
        let detail = app.descendants(matching: .any)["product-info.detail"].firstMatch
        let price = app.textFields["product-info.price"]
        let shoulder = app.textFields["product-info.measurement.shoulderWidth"]
        let keyboard = app.keyboards.firstMatch

        reveal(name, in: app)
        tapVisibleInput(name, in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        name.typeText("X")
        let editedName = name.value as? String
        XCTAssertTrue(editedName?.contains("X") == true)
        dismissKeyboardByTappingBackground(beside: name, in: app)
        XCTAssertEqual(name.value as? String, editedName)

        tapVisibleInput(name, in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // Switch inputs while the keyboard is already open. A background
        // gesture must not consume the editor's tap or prevent typing.
        XCTAssertTrue(detail.isHittable)
        tapVisibleInput(detail, in: app)
        detail.typeText("Y")
        let editedDetail = detail.value as? String
        XCTAssertTrue(editedDetail?.contains("Y") == true)
        XCTAssertTrue(keyboard.exists)
        dismissKeyboardByTappingBackground(beside: detail, in: app)
        XCTAssertEqual(detail.value as? String, editedDetail)

        for input in [price, shoulder] {
            reveal(input, in: app)
            let value = input.value as? String
            tapVisibleInput(input, in: app)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            dismissKeyboardByTappingBackground(beside: input, in: app)
            XCTAssertEqual(input.value as? String, value)
            tapVisibleInput(input, in: app)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            dismissKeyboardByTappingBackground(beside: input, in: app)
        }
        XCTAssertEqual(name.value as? String, editedName)
        XCTAssertEqual(detail.value as? String, editedDetail)
        attachScreenshot(app, name: "product-info-background-dismissed-keyboard")
    }

    @MainActor
    private func openSavedPhotoSample(in app: XCUIApplication) {
        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(app.navigationBars["90s 나이키 트랙탑"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func inputPhotoButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
    }

    @MainActor
    private func inputPhotoDeleteButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.delete-photo."))
    }

    @MainActor
    private func detailPhotoButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-detail.photo."))
    }

    @MainActor
    private func tapVisibleInput(_ input: XCUIElement, in app: XCUIApplication) {
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let keyboardTop = app.keyboards.firstMatch.exists
            ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
        let top = max(input.frame.minY, barBottom + 12)
        let bottom = min(input.frame.maxY, keyboardTop - 12)
        XCTAssertGreaterThan(bottom, top)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: input.frame.maxX - min(4, input.frame.width / 2),
                                 dy: (top + min(bottom, top + 44)) / 2)).tap()
    }

    @MainActor
    private func dismissKeyboardByTappingBackground(beside input: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let top = app.navigationBars.firstMatch.frame.maxY + 20
        let bottom = keyboard.frame.minY - 20
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 8, dy: min(max(input.frame.midY, top), bottom))).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertGalleryPage(_ pager: XCUIElement, in app: XCUIApplication, page: Int, total: Int,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pager.waitForExistence(timeout: 5), file: file, line: line)
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "\(page) / \(total)"),
                                                 object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
        let photo = app.descendants(matching: .any)["product-gallery.photo.\(page)"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), file: file, line: line)
        let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let photoFrame = photo.frame
            let pagerFrame = pager.frame
            return !photoFrame.isEmpty && abs(photoFrame.minX - pagerFrame.minX) <= 1
                && abs(photoFrame.maxX - pagerFrame.maxX) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed,
                       "The selected photo \(photo.frame) must settle on pager \(pager.frame)", file: file, line: line)
        XCTAssertEqual(photo.frame.minX, pager.frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(photo.frame.maxX, pager.frame.maxX, accuracy: 1, file: file, line: line)
    }

    @MainActor
    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        return app
    }

    @MainActor
    private func expectHome(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["home.guidance"].waitForExistence(timeout: 10), file: file, line: line)
        let guidance = app.staticTexts["home.guidance"].label
        XCTAssertTrue(guidance.contains("줄자 버튼을 눌러서"), file: file, line: line)
        XCTAssertTrue(guidance.contains("실측 시작하기"), file: file, line: line)
        let entry = app.buttons["product-flow.start"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(entry.isHittable, file: file, line: line)
        XCTAssertFalse(app.buttons["openLiDARLab"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["openQuickCopy"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["openExportChannels"].exists, file: file, line: line)
    }

    @MainActor
    private func expectEmptyLibrary(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10), file: file, line: line)
        let title = app.staticTexts["library.empty.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(title.label, "보관함이 비어있어요", file: file, line: line)
        XCTAssertTrue(app.staticTexts["작업을 시작해보세요"].exists, file: file, line: line)
        let start = app.buttons["library.empty.start-measurement"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(start.label, "실측 시작하기", file: file, line: line)
        XCTAssertTrue(start.isHittable, file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "library.product.")).firstMatch.exists, file: file, line: line)
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
