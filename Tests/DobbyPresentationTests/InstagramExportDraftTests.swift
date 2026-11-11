import XCTest
@testable import Dobby

@MainActor
final class InstagramExportDraftTests: XCTestCase {
    func testCaptionFormatsPriceWithThousandsSeparators() {
        let thousandWonDraft = InstagramExportDraft(product: product(price: "1000"))
        let millionWonDraft = InstagramExportDraft(product: product(price: "1000000"))

        XCTAssertTrue(thousandWonDraft.caption.contains("가격: 1,000원"))
        XCTAssertTrue(millionWonDraft.caption.contains("가격: 1,000,000원"))
    }

    func testCaptionResetRestoresOriginalCaptionWithoutChangingPhotos() {
        let first = Data([1])
        let second = Data([2])
        var product = ExportProduct.demo
        product.photos = [first, second]
        var draft = InstagramExportDraft(product: product)
        let originalCaption = draft.caption

        draft.caption = "수정된 캡션"

        draft.resetCaption()
        XCTAssertEqual(draft.photos.map(\.data), [first, second])
        XCTAssertEqual(draft.caption, originalCaption)
    }

    private func product(price: String) -> ExportProduct {
        let payload = ProductCopyPayload(
            productName: "상품",
            description: "",
            brand: "",
            measurements: "",
            price: price,
            length: "",
            waist: "",
            thigh: ""
        )
        return ExportProduct(id: "product-\(price)", thumbnailData: nil,
                             marketplacePayload: payload, instagramPayload: payload)
    }
}
