import XCTest
@testable import Dobby

@MainActor
final class Cafe24ExportDraftTests: XCTestCase {
    func testResetRestoresOriginalEditableValues() {
        var product = ExportProduct.demo
        product.photos = [Data([1]), Data([2])]
        var draft = Cafe24ExportDraft(product: product)
        let originalProductName = draft.productName
        let originalProductDescription = draft.productDescription
        let originalPriceText = draft.priceText

        draft.productName = "수정된 상품명"
        draft.productDescription = "수정된 상품 설명"
        draft.priceText = "10000"

        draft.resetProductName()
        draft.resetProductDescription()
        draft.resetPrice()

        XCTAssertEqual(draft.productName, originalProductName)
        XCTAssertEqual(draft.productDescription, originalProductDescription)
        XCTAssertEqual(draft.priceText, originalPriceText)
        XCTAssertEqual(draft.photos, [Data([1]), Data([2])])
    }

    func testValidationRequiresProductNameAndNumericPrice() {
        var draft = Cafe24ExportDraft(product: .demo)

        draft.productName = "   "
        XCTAssertEqual(draft.validationMessage, "상품명을 입력해 주세요.")

        draft.productName = "상품명"
        draft.priceText = ""
        XCTAssertEqual(draft.validationMessage, "판매가는 숫자로 입력해 주세요.")

        draft.priceText = "10,000"
        XCTAssertTrue(draft.canPublish)
        XCTAssertEqual(draft.price, 10000)
    }
}
