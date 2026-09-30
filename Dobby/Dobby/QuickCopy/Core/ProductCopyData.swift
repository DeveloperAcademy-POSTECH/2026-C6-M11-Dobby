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
    var title: String { self == .fruits ? "후르츠패밀리" : "Instagram" }
    var destination: URL {
        URL(string: self == .fruits ? "https://fruitsfamily.com/" : "https://www.instagram.com/")!
    }
}

nonisolated enum CopyExperimentMode: String, Codable, CaseIterable, Identifiable {
    case direct, foreground, foregroundAndOpen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .direct: "직접 복사 실험"
        case .foreground: "앱에서 복사 · 직접 복귀"
        case .foregroundAndOpen: "앱에서 복사 · 서비스 링크 열기"
        }
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
    let mode: CopyExperimentMode
    let payload: ProductCopyPayload
    let createdAt: Date
    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= 8 * 60 * 60 }
}

@MainActor
enum ProductCopyStore {
    private static let sessionKey = "quickCopy.session.v1"
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
