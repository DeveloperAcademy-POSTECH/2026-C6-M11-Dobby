import XCTest
@testable import Dobby

@MainActor
final class InstagramExportDraftTests: XCTestCase {
    func testPhotoAndCaptionResetRestoreTheOriginalProductDraft() {
        let first = Data([1])
        let second = Data([2])
        var product = ExportProduct.demo
        product.photoData = [first, second]
        var draft = InstagramExportDraft(product: product)
        let originalCaption = draft.caption

        draft.removePhoto(id: draft.photos[0].id)
        draft.caption = "수정된 캡션"
        XCTAssertEqual(draft.photos.map(\.data), [second])

        draft.resetPhotos()
        draft.resetCaption()
        XCTAssertEqual(draft.photos.map(\.data), [first, second])
        XCTAssertEqual(draft.caption, originalCaption)
    }
}
