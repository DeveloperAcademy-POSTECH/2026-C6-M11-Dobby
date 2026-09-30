import Foundation

@main
struct QuickCopyLogicChecks {
    static func main() throws {
        let fruits = ProductCopyPayload.sample(for: .fruits)
        let instagram = ProductCopyPayload.sample(for: .instagram)

        precondition(fruits.price == "56000")
        precondition(fruits.description.contains("Price- 56,000\n\n"))
        precondition(!fruits.description.contains("55,000"))
        precondition(instagram.description.contains("65,000 >팔로우 시 55,000"))
        precondition(fruits.description.contains("\n\nSize 59 43 32\n"))
        precondition(fruits.description.contains("😘") && fruits.description.contains("@okaoka_vtg"))
        precondition([fruits.length, fruits.waist, fruits.thigh] == ["59", "43", "32"])
        precondition(fruits.value(for: .productName) == fruits.productName)
        precondition(fruits.value(for: .description) == fruits.description)
        precondition(fruits.value(for: .brand) == "LEVI'S")
        precondition(fruits.value(for: .measurements) == "총장 59 cm\n허리 단면 43 cm\n허벅지 단면 32 cm")

        precondition(ProductCopyField.productName.copiedMessage == "상품명이 복사되었습니다.")
        precondition(ProductCopyField.description.copiedMessage == "설명이 복사되었습니다.")
        precondition(ProductCopyField.brand.copiedMessage == "브랜드명이 복사되었습니다.")
        precondition(ProductCopyField.measurements.copiedMessage == "실측 사이즈가 복사되었습니다.")

        let values = ProductCopyValues(
            productName: fruits.productName,
            description: fruits.description,
            brand: fruits.brand,
            measurements: fruits.measurements
        )
        precondition(values.value(for: .productName) == fruits.productName)
        precondition(values.value(for: .description) == fruits.description)
        precondition(values.value(for: .brand) == fruits.brand)
        precondition(values.value(for: .measurements) == fruits.measurements)

        guard let shortcutURL = ForegroundCopyURLBuilder.url(for: .productName),
              let shortcutComponents = URLComponents(url: shortcutURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("단축어 복사 URL을 생성할 수 없음")
        }
        let shortcutQuery = Dictionary(uniqueKeysWithValues: shortcutComponents.queryItems?.compactMap {
            item in item.value.map { (item.name, $0) }
        } ?? [])
        precondition(shortcutComponents.scheme == "dobby-copy")
        precondition(shortcutComponents.host == "copy")
        precondition(shortcutQuery["field"] == ProductCopyField.productName.rawValue)
        precondition(ForegroundCopyURLBuilder.testURL.absoluteString == "dobby-copy://copy-test")

        let encodedValues = try JSONEncoder().encode(values)
        precondition(!encodedValues.isEmpty && encodedValues.count < 3_500)

        let id = UUID()
        let now = Date()
        let session = ProductCopySession(
            id: id,
            channel: .fruits,
            productID: "selected-product",
            payload: fruits,
            createdAt: now
        )
        let restored = try JSONDecoder().decode(
            ProductCopySession.self,
            from: JSONEncoder().encode(session)
        )
        precondition(restored.id == id && restored.productID == "selected-product")
        precondition(restored.payload == fruits && !restored.isExpired)
        precondition(session.canReuse(productID: "selected-product", payload: fruits))
        precondition(!session.canReuse(productID: "another-product", payload: fruits))
        precondition(!session.canReuse(productID: "selected-product", payload: instagram))

        let expired = ProductCopySession(
            id: id,
            channel: .fruits,
            productID: "selected-product",
            payload: fruits,
            createdAt: now.addingTimeInterval(-9 * 3_600)
        )
        precondition(expired.isExpired)
        print("PASS: product values, foreground relay URL, messages, attributes and session")
    }
}
