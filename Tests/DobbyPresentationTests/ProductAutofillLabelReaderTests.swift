import XCTest
import UIKit
@testable import Dobby

@MainActor
final class ProductAutofillLabelReaderTests: XCTestCase {
    func testNormalizedCropUsesTopLeftCoordinatesAndClipsPadding() {
        let box = ProductAutofillLabelReader.Box(x: 0.25, y: 0.1, width: 0.5, height: 0.3)
        XCTAssertEqual(ProductAutofillLabelReader.pixelRect(box, width: 100, height: 200),
            CGRect(x: 17, y: 12, width: 66, height: 76))
        XCTAssertNil(ProductAutofillLabelReader.pixelRect(.init(x: .nan, y: 0, width: 1, height: 1), width: 100, height: 100))
        XCTAssertNil(ProductAutofillLabelReader.pixelRect(.init(x: 0.8, y: 0, width: 0.5, height: 1), width: 100, height: 100))
    }

    func testNativeVisionReadsRotatedSyntheticLabelAndPreservesOriginalPhotoID() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 300))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 700, height: 300))
            ("ACME" as NSString).draw(at: CGPoint(x: 80, y: 80), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 110), .foregroundColor: UIColor.black,
            ])
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let photos = [ProductAutofillPhotoEncoder.Photo(id: "original-label", role: "detail",
            imageDataUrl: "data:image/jpeg;base64," + data.base64EncodedString())]
        let region = ProductAutofillLabelReader.Region(photoId: "original-label", kind: "neck_print",
            box: .init(x: 0, y: 0, width: 1, height: 1))
        let crops = try await ProductAutofillLabelReader.prepare(photos: photos, regions: [region])
        let crop = try XCTUnwrap(crops.first)
        XCTAssertEqual(crop.sourcePhotoId, "original-label")
        XCTAssertTrue(crop.ocrText.contains("ACME"))
        let angles = Set(crop.ocrText.split(separator: "\n").filter { $0.contains("ACME") }.compactMap { $0.split(separator: "°").first })
        XCTAssertGreaterThanOrEqual(angles.count, 2)
        XCTAssertLessThanOrEqual(crop.ocrText.count, 1200)
    }
}
