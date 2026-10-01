import Foundation

@main struct QuickCopyLogicChecks {
    static func main() throws {
        let id = UUID()
        for field in ProductCopyField.allCases {
            let url = CopyRoute.url(sessionID: id, field: field)
            precondition(CopyRoute.parse(url) == CopyRequest(sessionID: id, field: field))
        }
        let valid = CopyRoute.url(sessionID: id, field: .brand).absoluteString
        for invalid in [
            "https://copy?session=\(id)&field=brand",
            "dobby-copy://copy?session=no-uuid&field=brand",
            "dobby-copy://copy?session=\(id)&field=unknown",
            "dobby-copy://copy?session=\(id)",
            valid + "&field=brand", valid + "&url=https://example.com",
            valid + "#fragment", "dobby-copy://copy/path?session=\(id)&field=brand",
            "dobby-copy://user@copy?session=\(id)&field=brand"
        ] {
            precondition(CopyRoute.parse(URL(string: invalid)!) == nil, invalid)
        }
        var gate = CopyRequestGate()
        let request = CopyRequest(sessionID: id, field: .brand)
        let now = Date()
        precondition(gate.accept(request, now: now))
        precondition(!gate.accept(request, now: now.addingTimeInterval(1)))
        precondition(gate.accept(request, now: now.addingTimeInterval(2)))
        precondition(gate.accept(CopyRequest(sessionID: id, field: .description), now: now.addingTimeInterval(2)))

        let fruits = ProductCopyPayload.sample(for: .fruits)
        let instagram = ProductCopyPayload.sample(for: .instagram)
        precondition(fruits.price == "56000" && fruits.description.contains("Price- 56,000\n\n"))
        precondition(!fruits.description.contains("55,000"))
        precondition(instagram.description.contains("65,000 >팔로우 시 55,000"))
        precondition(fruits.description.contains("\n\nSize 59 43 32\n"))
        precondition(fruits.description.contains("😘") && fruits.description.contains("@okaoka_vtg"))
        precondition([fruits.length, fruits.waist, fruits.thigh] == ["59", "43", "32"])
        let session = ProductCopySession(id: id, channel: .fruits, mode: .foreground, payload: fruits, createdAt: now)
        let restored = try JSONDecoder().decode(ProductCopySession.self, from: JSONEncoder().encode(session))
        precondition(restored.id == id && restored.payload.description == fruits.description && !restored.isExpired)
        let expired = ProductCopySession(id: id, channel: .fruits, mode: .direct, payload: fruits, createdAt: now.addingTimeInterval(-9 * 3600))
        precondition(expired.isExpired)
        print("PASS: route round-trips, malformed links, duplicate gate, channel prices, paragraphs, measurements, session restore and expiration")
    }
}
