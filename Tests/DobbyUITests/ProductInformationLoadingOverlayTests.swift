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
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo.")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        // Use the upper part of the first blue fixture thumbnail, clear of its
        // removal badge and of the centered loading card.
        let photoPoint = CGPoint(x: photo.frame.midX, y: photo.frame.minY + 20)
        let beforeScreenshot = app.screenshot()
        let before = try brightness(of: beforeScreenshot.image, at: toolbarPoint, screenWidth: app.frame.width)
        let photoBefore = try rgb(of: beforeScreenshot.image, at: photoPoint, screenWidth: app.frame.width)

        startGeneration(in: app)
        let loading = app.descendants(matching: .any)["product-ai.loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        let screenshot = app.screenshot()
        let during = try brightness(of: screenshot.image, at: toolbarPoint, screenWidth: app.frame.width)
        XCTAssertLessThan(during, before * 0.65, "The dimmer must cover the native toolbar too")
        let loadingTitle = app.staticTexts["AI가 정보 생성 중..."].firstMatch
        XCTAssertLessThan(photoPoint.y, loadingTitle.frame.minY - 20,
                          "The thumbnail sample must be outside the centered loading card")
        let photoDuring = try rgb(of: screenshot.image, at: photoPoint, screenWidth: app.frame.width)
        XCTAssertGreaterThan((photoBefore.max() ?? 0) - (photoBefore.min() ?? 0), 20,
                             "Use the colored photo fixture, not a loading placeholder")
        // A black dimmer changes brightness, but preserves the thumbnail's hue.
        // Replacing or moving the photo strip with gray skeletons fails this.
        for channel in 0..<3 {
            XCTAssertEqual(photoDuring[channel] / max(1, photoDuring.reduce(0, +)),
                           photoBefore[channel] / max(1, photoBefore.reduce(0, +)), accuracy: 0.06,
                           "The real photo must stay visible in place while only input fields use skeletons")
        }
        let back = app.buttons["product-flow.back"]
        let done = app.buttons["product-info.done"]
        XCTAssertFalse(back.exists && back.isEnabled)
        XCTAssertFalse(done.exists && done.isEnabled)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "library-ai-loading-above-toolbar"
        attachment.lifetime = .keepAlways
        add(attachment)

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
