import XCTest
@testable import Dobby

@MainActor
final class InstagramExportDraftTests: XCTestCase {
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
}
