import CoreText
import UIKit
import XCTest
@testable import Dobby

/// Runs in the built application, so missing target resources or an omitted
/// UIAppFonts entry fail even when the source files exist in the checkout.
@MainActor
final class GarmentHiFiResourceTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: ARKitCaptureProvider.self) }

    func testOriginalIdleAndReadyShuttersAreBundledAt92Points() throws {
        try assertImage("MeasurementShutterIdle", size: .init(width: 92, height: 92))
        try assertImage("MeasurementShutterReady", size: .init(width: 92, height: 92))
    }

    func testPlacementTutorialLoadsOriginalShirtAndFractionalPointAsset() throws {
        try assertImage("GarmentCaptureTutorialShirt", size: .init(width: 768, height: 1024))
        // Asset compilation may round a fractional SVG canvas to a device pixel.
        try assertImage("GarmentCaptureTutorialMeasurementPoint",
                        size: .init(width: 21.8698, height: 21.8698), tolerance: 0.5)
    }

    func testResultDragTutorialLoadsTheOriginal76By111Finger() throws {
        try assertImage("MeasurementPointTutorial", size: .init(width: 76, height: 111))
    }

    func testPretendardRegularIsDeclaredBundledAndRegisteredFromTheApp() throws {
        let declaredFonts = try XCTUnwrap(appBundle.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertTrue(declaredFonts.contains("Pretendard-Regular.otf"),
                      "The app must declare its bundled font; the test must not register it on the app's behalf.")
        let fontURL = try XCTUnwrap(appBundle.url(forResource: "Pretendard-Regular", withExtension: "otf"),
                                    "The synchronized resource group must copy the font to the app bundle.")
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor])
        let descriptor = try XCTUnwrap(descriptors.first)
        let postScriptName = try XCTUnwrap(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
        XCTAssertEqual(postScriptName, "Pretendard-Regular", "Check the file's real face name, not just its filename.")

        let font = try XCTUnwrap(UIFont(name: "Pretendard-Regular", size: 14),
                                 "UIAppFonts must register Pretendard before a SwiftUI .custom call uses it.")
        XCTAssertEqual(font.fontName, postScriptName)
        XCTAssertEqual(font.familyName, "Pretendard")
        let resolvedFont = CTFontCreateWithName(font.fontName as CFString, 14, nil)
        let resolvedURL = try XCTUnwrap(CTFontCopyAttribute(resolvedFont, kCTFontURLAttribute) as? URL)
        XCTAssertEqual(resolvedURL.standardizedFileURL.resolvingSymlinksInPath(),
                       fontURL.standardizedFileURL.resolvingSymlinksInPath(),
                       "A globally installed face must not hide a missing or unregistered app font.")
    }

    func testBundledFontIncludesItsRedistributionLicense() throws {
        let licenseURL = try XCTUnwrap(appBundle.url(forResource: "Pretendard-LICENSE", withExtension: "txt"))
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        XCTAssertTrue(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(license.contains("Copyright (c) 2021, Kil Hyung-jin"))
    }

    private func assertImage(_ name: String, size: CGSize, tolerance: CGFloat = 0.01,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(UIImage(named: name, in: appBundle, compatibleWith: nil),
                                  "The application must contain the Figma asset named \(name).", file: file, line: line)
        XCTAssertEqual(image.size.width, size.width, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(image.size.height, size.height, accuracy: tolerance, file: file, line: line)
        // Force decoding/rasterization instead of relying only on catalog metadata.
        let rendered = UIGraphicsImageRenderer(size: .init(width: 48, height: 48)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        XCTAssertNotNil(rendered.cgImage, file: file, line: line)
    }
}
