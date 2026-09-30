import Foundation

@main struct QuickCopyLogicChecks {
    static func main() throws {
        let fruits = ProductCopyPayload.sample(for: .fruits)
        let instagram = ProductCopyPayload.sample(for: .instagram)
        precondition(fruits.price == "56000" && fruits.description.contains("Price- 56,000\n\n"))
        precondition(!fruits.description.contains("55,000"))
        precondition(instagram.description.contains("65,000 >팔로우 시 55,000"))
        precondition(fruits.description.contains("\n\nSize 59 43 32\n"))
        precondition(fruits.description.contains("😘") && fruits.description.contains("@okaoka_vtg"))
        precondition([fruits.length, fruits.waist, fruits.thigh] == ["59", "43", "32"])
        precondition(fruits.value(for: .brand) == "LEVI'S")
        precondition(fruits.value(for: .measurements) == "총장 59 cm\n허리 단면 43 cm\n허벅지 단면 32 cm")
        let id = UUID(), now = Date()
        let session = ProductCopySession(id: id, channel: .fruits, productID: "selected-product", payload: fruits, createdAt: now)
        let restored = try JSONDecoder().decode(ProductCopySession.self, from: JSONEncoder().encode(session))
        precondition(restored.id == id && restored.productID == "selected-product")
        precondition(restored.payload == fruits && !restored.isExpired)
        let expired = ProductCopySession(id: id, channel: .fruits, productID: "selected-product", payload: fruits, createdAt: now.addingTimeInterval(-9 * 3600))
        precondition(expired.isExpired)
        precondition(session.canReuse(productID: "selected-product", payload: fruits))
        precondition(!session.canReuse(productID: "another-product", payload: fruits))
        precondition(!session.canReuse(productID: "selected-product", payload: instagram))
        precondition(!expired.canReuse(productID: "selected-product", payload: fruits))
        precondition(fruits != instagram)
        precondition(ProductCopyField(rawValue: "unknown") == nil)
        print("PASS: channel data, paragraphs, copy field mapping, measurements, selected-product session restore and expiration")
    }
}
