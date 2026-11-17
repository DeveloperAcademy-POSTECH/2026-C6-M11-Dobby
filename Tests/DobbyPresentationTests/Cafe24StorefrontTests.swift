import XCTest
@testable import Dobby

@MainActor
final class Cafe24StorefrontTests: XCTestCase {
    func testStorefrontUsesTheMallThatReceivedTheProduct() {
        let first = Cafe24PublishResult(productNo: 12, mallID: "dobbyisvintage")
        let second = Cafe24PublishResult(productNo: 34, mallID: "another-shop")

        XCTAssertEqual(first.storefrontURL?.absoluteString, "https://dobbyisvintage.cafe24.com/")
        XCTAssertEqual(second.storefrontURL?.absoluteString, "https://another-shop.cafe24.com/")
        XCTAssertNotEqual(first.storefrontURL, second.storefrontURL)
    }

    func testStorefrontNormalizesTheMallID() {
        let result = Cafe24PublishResult(productNo: 1, mallID: " MyShop123 \n")

        XCTAssertEqual(result.storefrontURL?.absoluteString, "https://myshop123.cafe24.com/")
    }

    func testInvalidMallIDCannotChangeTheBrowserDestination() {
        for mallID in ["", "a", "-shop", "shop.example.com", "https://shop", "shop/path", "shop?next=elsewhere", "shop@elsewhere", String(repeating: "a", count: 41)] {
            let result = Cafe24PublishResult(productNo: 1, mallID: mallID)
            XCTAssertNil(result.storefrontURL, mallID)
        }
    }
}
