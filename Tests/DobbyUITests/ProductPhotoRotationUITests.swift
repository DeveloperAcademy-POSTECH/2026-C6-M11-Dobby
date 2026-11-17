import UIKit
import XCTest

/// Synthetic gallery UI coverage. Physical-device animation timing and Photos
/// behavior still require manual QA; no camera accuracy is asserted here.
final class ProductPhotoRotationUITests: XCTestCase {
    @MainActor
    func testPhotoOnlyRotationKeepsControlsPageAndTransparentMargins() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--flow-preview", "--flow-test-store", UUID().uuidString, "--garment-preview-top"]
        app.launch()
        defer { app.terminate() }
        startMeasurementFromHome(in: app)
        armSyntheticGarmentCapture(in: app)
        tap(app, "captureGarment")
        tap(app, "confirmGarmentMeasurement")
        tap(app, "camera.startDetailCapture")
        tap(app, "camera.captureDetail")
        tap(app, "camera.selectPhotos")
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 30))

        let strip = app.collectionViews["product-info.photo-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        let photoButtons = strip.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "product-info.photo."))
        XCTAssertTrue(photoButtons.firstMatch.waitForExistence(timeout: 10))
        let firstPhoto = photoButtons.allElementsBoundByIndex.filter { $0.frame.intersects(strip.frame) }
            .min { $0.frame.minX < $1.frame.minX }
        let first = try XCTUnwrap(firstPhoto)
        let firstPhotoID = first.identifier
        let underlyingScreen = XCUIScreen.main.screenshot().image
        first.tap()

        let rotate = app.buttons["product-gallery.rotate"]
        let close = app.buttons["product-gallery.close"]
        let pager = app.descendants(matching: .any)["product-gallery.pager"].firstMatch
        let pageControl = app.descendants(matching: .any)["product-gallery.page-control"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        XCTAssertTrue(pager.exists && close.exists && pageControl.exists)
        XCTAssertEqual(pager.value as? String, "1 / 3")
        let controlFrames = [close.frame, rotate.frame, pageControl.frame]
        let viewport = pager.frame
        // This fixture is 4:5; after a quarter turn it is landscape and leaves
        // a real empty margin inside the fixed gallery viewport. The old pager
        // filled this position with opaque black instead of the dimmed form.
        let samplePoint = try brightestBackdropPoint(in: underlyingScreen, viewport: viewport,
                                                     screenFrame: app.frame)
        for turn in 1...4 {
            rotate.tap()
            let expected = "왼쪽으로 \((turn % 4) * 90)도 회전"
            let orientation = expectation(for: NSPredicate(format: "value == %@", expected),
                                          evaluatedWith: rotate)
            wait(for: [orientation], timeout: 15)
            XCTAssertTrue(rotate.isEnabled)
            XCTAssertEqual(pager.value as? String, "1 / 3", "Rotation must not recreate the pager at another index")
            for (actual, expectedFrame) in zip([close.frame, rotate.frame, pageControl.frame], controlFrames) {
                assertSameFrame(actual, expectedFrame)
            }
            if turn == 1 {
                let screenshot = XCUIScreen.main.screenshot()
                let color = try pixel(in: screenshot.image, at: samplePoint, screenFrame: app.frame)
                XCTAssertGreaterThan(max(color.red, color.green, color.blue), 8,
                                     "A landscape image's empty margin must expose the dimmed form, not an opaque black rectangle")
                attach(screenshot, name: "photo-rotation-counterclockwise-no-black-bars")
            }
        }
        attach(XCUIScreen.main.screenshot(), name: "photo-rotation-four-turns-restored")
        close.tap()
        XCTAssertTrue(app.buttons["product-info.done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[firstPhotoID].exists, "Rotation must preserve photo identity")

        // A fifth turn is retained when the viewer is dismissed and reopened.
        tap(app, firstPhotoID)
        tap(app, "product-gallery.rotate")
        let retained = expectation(for: NSPredicate(format: "value == %@", "왼쪽으로 90도 회전"),
                                   evaluatedWith: app.buttons["product-gallery.rotate"])
        wait(for: [retained], timeout: 15)
        tap(app, "product-gallery.close")
        tap(app, firstPhotoID)
        XCTAssertEqual(app.buttons["product-gallery.rotate"].value as? String, "왼쪽으로 90도 회전")
        XCTAssertEqual(pager.value as? String, "1 / 3")
        pager.swipeLeft()
        let nextPage = expectation(for: NSPredicate(format: "value == %@", "2 / 3"), evaluatedWith: pager)
        wait(for: [nextPage], timeout: 10)
        XCTAssertEqual(app.buttons["product-gallery.rotate"].value as? String, "왼쪽으로 0도 회전",
                       "A turn must affect only the selected photo")
        pager.swipeDown()
        XCTAssertTrue(close.wait(for: \.exists, toEqual: false, timeout: 10))
        XCTAssertTrue(app.buttons["product-info.done"].exists)
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let element = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), identifier)
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 15), identifier)
        element.tap()
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func brightestBackdropPoint(in image: UIImage, viewport: CGRect, screenFrame: CGRect) throws -> CGPoint {
        let candidates = [CGFloat(0.35), 0.5, 0.65].flatMap { x in
            [CGFloat(0.08), 0.12].map { y in
                CGPoint(x: viewport.minX + viewport.width * x, y: viewport.minY + viewport.height * y)
            }
        }
        var selected = candidates[0]
        var brightest: UInt8 = 0
        for point in candidates {
            let color = try pixel(in: image, at: point, screenFrame: screenFrame)
            let brightness = max(color.red, color.green, color.blue)
            if brightness > brightest { selected = point; brightest = brightness }
        }
        XCTAssertGreaterThan(brightest, 80, "The comparison must use a visible background point")
        return selected
    }

    private func pixel(in image: UIImage, at point: CGPoint, screenFrame: CGRect) throws
        -> (red: UInt8, green: UInt8, blue: UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let x = min(cgImage.width - 1, max(0, Int((point.x - screenFrame.minX) / screenFrame.width * CGFloat(cgImage.width))))
        let y = min(cgImage.height - 1, max(0, Int((point.y - screenFrame.minY) / screenFrame.height * CGFloat(cgImage.height))))
        let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (rgba[0], rgba[1], rgba[2])
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
