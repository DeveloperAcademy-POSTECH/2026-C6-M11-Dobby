import Foundation

nonisolated enum ProductCopyField: String, Codable, CaseIterable, Identifiable {
    case productName, description, brand, measurements
    var id: String { rawValue }
    var title: String {
        switch self {
        case .productName: "제품명 복사"
        case .description: "설명 복사"
        case .brand: "브랜드명 복사"
        case .measurements: "실측 사이즈 복사"
        }
    }
}

nonisolated enum CopyChannel: String, Codable, CaseIterable, Identifiable {
    case fruits, instagram
    var id: String { rawValue }
    var title: String { self == .fruits ? "후루츠패밀리" : "Instagram" }
    var destination: URL {
        URL(string: self == .fruits ? "https://fruitsfamily.com/" : "https://www.instagram.com/")!
    }
}

nonisolated struct ProductCopyPayload: Codable, Equatable {
    let productName: String
    let description: String
    let brand: String
    let measurements: String
    let price: String
    let length: String
    let waist: String
    let thigh: String

    func value(for field: ProductCopyField) -> String {
        switch field {
        case .productName: productName
        case .description: description
        case .brand: brand
        case .measurements: measurements
        }
    }


}

nonisolated struct ProductCopySession: Codable, Identifiable {
    let id: UUID
    let channel: CopyChannel
    let productID: String
    let payload: ProductCopyPayload
    let createdAt: Date
    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= 8 * 60 * 60 }

    func canReuse(productID: String, payload: ProductCopyPayload) -> Bool {
        !isExpired && self.productID == productID && self.payload == payload
    }
}

@MainActor
enum ProductCopyStore {
    private static let sessionKey = "quickCopy.session.v2"
    static func save(_ session: ProductCopySession) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(session), forKey: sessionKey)
    }
    static func load() -> ProductCopySession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(ProductCopySession.self, from: data),
              !session.isExpired else { return nil }
        return session
    }
    static func invalidate() { UserDefaults.standard.removeObject(forKey: sessionKey) }
}
