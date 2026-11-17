import XCTest
import UIKit

/// Local AI fixtures exercise the real library editing navigation without API requests.
@MainActor
final class ProductInformationLoadingOverlayTests: XCTestCase {
    func testLoadingCoversToolbarAndRestoresEditingAfterGeneration() throws {
        continueAfterFailure = false
        let app = openEditing(result: "delay")
        defer { app.terminate() }
        let toolbarPoint = CGPoint(x: 80, y: app.buttons["product-flow.back"].frame.midY)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
        let bluePhoto = photos.element(boundBy: 0)
        let redPhoto = photos.element(boundBy: 1)
        XCTAssertTrue(bluePhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(redPhoto.waitForExistence(timeout: 5))
        // Sample both fixture thumbnails at the same height, clear of their
        // removal badges and of the centered loading card.
        let photoPoints = [bluePhoto, redPhoto].map {
            CGPoint(x: $0.frame.midX, y: $0.frame.minY + 20)
        }
        let beforeScreenshot = app.screenshot()

        startGeneration(in: app)
        let loading = app.descendants(matching: .any)["product-ai.loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        let screenshot = app.screenshot()
        // Keep both states even when a pixel assertion fails.
        for (name, capture) in [("library-ai-before-generation", beforeScreenshot),
                                ("library-ai-loading-above-toolbar", screenshot)] {
            let attachment = XCTAttachment(screenshot: capture)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let before = try brightness(of: beforeScreenshot.image, at: toolbarPoint, screenWidth: app.frame.width)
        let during = try brightness(of: screenshot.image, at: toolbarPoint, screenWidth: app.frame.width)
        XCTAssertLessThan(during, before * 0.65, "The dimmer must cover the native toolbar too")
        let loadingTitle = app.staticTexts["AI가 정보 생성 중..."].firstMatch
        for point in photoPoints {
            XCTAssertLessThan(point.y, loadingTitle.frame.minY - 20,
                              "The thumbnail samples must be outside the centered loading card")
        }
        let photosBefore = try photoPoints.map { try rgb(of: beforeScreenshot.image, at: $0, screenWidth: app.frame.width) }
        let photosDuring = try photoPoints.map { try rgb(of: screenshot.image, at: $0, screenWidth: app.frame.width) }
        let contrastBefore = zip(photosBefore[1], photosBefore[0]).map { $0 - $1 }
        let contrastDuring = zip(photosDuring[1], photosDuring[0]).map { $0 - $1 }
        let beforeMagnitude = sqrt(contrastBefore.reduce(0) { $0 + $1 * $1 })
        let duringMagnitude = sqrt(contrastDuring.reduce(0) { $0 + $1 * $1 })
        XCTAssertGreaterThan(beforeMagnitude, 30, "Use the distinct blue and red photo fixtures")
        // Disabled controls and the dimmer can mix in a neutral color. Taking
        // the red-minus-blue difference cancels that common color. Both its
        // contrast and direction must survive: gray skeletons lose this signal.
        XCTAssertGreaterThan(duringMagnitude, max(8, beforeMagnitude * 0.08),
                             "The two original photos must remain visibly distinct in their original positions")
        let dotProduct = zip(contrastBefore, contrastDuring).reduce(0.0) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(dotProduct / max(1, beforeMagnitude * duringMagnitude), 0.9,
                             "The red/blue color contrast must remain while only input fields use skeletons")
        let back = app.buttons["product-flow.back"]
        let done = app.buttons["product-info.done"]
        XCTAssertFalse(back.exists && back.isEnabled)
        XCTAssertFalse(done.exists && done.isEnabled)
        let generate = app.buttons["product-ai.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 12))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 5))
        XCTAssertTrue(generate.isEnabled)
        XCTAssertTrue(app.buttons["product-info.done"].isEnabled)
        XCTAssertEqual(app.textFields["product-info.name"].value as? String, "AI 테스트 네이비 집업 후드")
        XCTAssertEqual(generate.label, "다시 정보 생성하기")
        startGeneration(in: app)
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.waitForExistence(timeout: 12))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 5))
    }

    func testGenerationFailureRestoresErrorActionsAndManualEditing() {
        continueAfterFailure = false
        let app = openEditing(result: "failure")
        defer { app.terminate() }
        startGeneration(in: app)
        XCTAssertTrue(app.buttons["product-ai.retry"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["product-ai.loading"].exists)
        let manual = app.buttons["product-ai.manual"].firstMatch
        XCTAssertTrue(manual.isEnabled)
        manual.tap()
        XCTAssertTrue(app.buttons["product-ai.generate"].isEnabled)
        XCTAssertTrue(app.buttons["product-info.done"].isEnabled)
        XCTAssertEqual(app.textFields["product-info.name"].value as? String, "90s 나이키 트랙탑")
    }

    func testCloseCancelsGenerationPreservesInformationAndAllowsRetry() {
        continueAfterFailure = false
        let app = openEditing(result: "delay")
        defer { app.terminate() }
        let name = app.textFields["product-info.name"].value as? String
        let detail = app.textViews["product-info.detail"].value as? String
        let brand = app.textFields["product-info.brand"].value as? String
        startGeneration(in: app)
        let cancel = app.buttons["product-ai.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ai-loading-with-close-button"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        let loading = app.descendants(matching: .any)["product-ai.loading"].firstMatch
        XCTAssertTrue(loading.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["product-ai.generate"].isEnabled)
        XCTAssertTrue(app.buttons["product-info.done"].isEnabled)
        XCTAssertEqual(app.textFields["product-info.name"].value as? String, name)
        XCTAssertEqual(app.textViews["product-info.detail"].value as? String, detail)
        XCTAssertEqual(app.textFields["product-info.brand"].value as? String, brand)
        let unchanged = NSPredicate { _, _ in
            (app.textFields["product-info.name"].value as? String) != name
        }
        let lateResult = XCTNSPredicateExpectation(predicate: unchanged, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [lateResult], timeout: 6), .timedOut)
        XCTAssertFalse(app.buttons["product-ai.retry"].firstMatch.exists)
        startGeneration(in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["product-ai.generate"].waitForExistence(timeout: 12))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.textFields["product-info.name"].value as? String, "AI 테스트 네이비 집업 후드")
    }

    private func openEditing(result: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString]
        app.launchEnvironment["DOBBY_AI_FIXTURE_RESULT"] = result
        app.launch()
        XCTAssertTrue(app.buttons["product-flow.start"].waitForExistence(timeout: 15))
        app.tabBars.buttons["보관함"].tap()
        let sample = app.buttons["debug.export-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let edit = app.buttons["library.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.buttons["product-ai.generate"].waitForExistence(timeout: 5))
        return app
    }

    private func startGeneration(in app: XCUIApplication) {
        app.buttons["product-ai.generate"].tap()
        XCTAssertFalse(app.buttons["product-ai.replace"].firstMatch.exists)
        XCTAssertFalse(app.sheets["작성한 정보를 AI 내용으로 바꿀까요?"].exists)
    }

    private func brightness(of image: UIImage, at point: CGPoint, screenWidth: CGFloat) throws -> Double {
        try rgb(of: image, at: point, screenWidth: screenWidth).reduce(0, +) / 3
    }

    private func rgb(of image: UIImage, at point: CGPoint, screenWidth: CGFloat) throws -> [Double] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / screenWidth
        let pixel = try XCTUnwrap(cgImage.cropping(to: CGRect(x: point.x * scale, y: point.y * scale,
                                                            width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let values: [Double]? = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let values = bytes.bindMemory(to: UInt8.self)
            return [Double(values[0]), Double(values[1]), Double(values[2])]
        }
        return try XCTUnwrap(values)
    }
}
