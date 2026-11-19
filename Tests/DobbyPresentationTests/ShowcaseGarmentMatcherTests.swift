import UIKit
import XCTest
@testable import Dobby

@MainActor
final class ShowcaseGarmentMatcherTests: XCTestCase {
    func testShortsMatchFromTheWideDisplayAndWaistLabelIndependently() throws {
        let bundle = Bundle(for: Self.self)
        for name in ["showcase-shorts-wide", "showcase-shorts-waist-label"] {
            let photo = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg"))
            XCTAssertEqual(try ShowcaseGarmentMatcher.match(photoURLs: [photo]), .zaraShorts, name)
        }
    }

    func testShortsMatchFromTheBackOnTheChakDisplayAndRejectAMixedSelection() throws {
        let back = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "showcase-shorts-back-wide", withExtension: "jpg"))
        XCTAssertEqual(try ShowcaseGarmentMatcher.match(photoURLs: [back]), .zaraShorts)

        let shirt = try reference("ShowcaseChakBack")
        XCTAssertNil(try ShowcaseGarmentMatcher.match(photoURLs: [back, shirt]))
    }

    func testEmptyChakDisplayAndOtherGarmentsFallThrough() throws {
        let display = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "showcase-empty-display", withExtension: "jpg"))
        let jacket = try XCTUnwrap(Bundle.main.url(forResource: "library-preview-polo-jacket", withExtension: "png"))
        for photo in [display, jacket] {
            XCTAssertNil(try ShowcaseGarmentMatcher.match(photoURLs: [photo]), photo.lastPathComponent)
        }
    }

    func testBothGarmentsMatchAfterThePrintOrPocketIsReframed() throws {
        for (name, expected) in [("ShowcaseChakChest", ShowcaseGarment.chakTee),
                                 ("ShowcaseZaraPockets", .zaraShorts)] {
            let url = try reference(name)
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            let capture = try temporaryPhoto { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
                context.cgContext.translateBy(x: 245, y: 215)
                context.cgContext.rotate(by: 0.16)
                let height = 330 * image.size.height / image.size.width
                image.draw(in: CGRect(x: -165, y: -height / 2, width: 330, height: height))
            }
            XCTAssertEqual(try ShowcaseGarmentMatcher.match(photoURLs: [capture]), expected, name)
        }
    }

    func testOtherBrandsColorsAndMixedSamplesFallThrough() throws {
        let other = try temporaryPhoto { context in
            UIColor(red: 0.68, green: 0.61, blue: 0.53, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemOrange, .font: UIFont.systemFont(ofSize: 55)
            ]
            ("ZARA" as NSString).draw(at: CGPoint(x: 180, y: 215), withAttributes: attributes)
        }
        XCTAssertNil(try ShowcaseGarmentMatcher.match(photoURLs: [other]))
        let mixed = try [reference("ShowcaseChakBack"), reference("ShowcaseZaraSeams")]
        XCTAssertNil(try ShowcaseGarmentMatcher.match(photoURLs: mixed))
        XCTAssertNil(try ShowcaseGarmentMatcher.match(photoURLs: []))
    }

    private func reference(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "jpg"))
    }

    private func temporaryPhoto(_ draw: (UIGraphicsImageRendererContext) -> Void) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 500), format: format)
            .image(actions: draw)
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
