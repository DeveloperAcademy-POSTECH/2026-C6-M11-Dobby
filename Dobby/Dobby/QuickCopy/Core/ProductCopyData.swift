import Foundation
import OSLog

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
    var copiedMessage: String {
        switch self {
        case .productName: "상품명이 복사되었습니다."
        case .description: "설명이 복사되었습니다."
        case .brand: "브랜드명이 복사되었습니다."
        case .measurements: "실측 사이즈가 복사되었습니다."
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

nonisolated struct ProductCopyPayload: Codable, Equatable, Hashable {
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

nonisolated struct ProductCopyValues: Codable, Equatable, Hashable {
    let productName: String
    let description: String
    let brand: String
    let measurements: String
    var measurementItems: [ProductCopyMeasurement]? = nil

    func value(for field: ProductCopyField) -> String {
        switch field {
        case .productName: productName
        case .description: description
        case .brand: brand
        case .measurements: measurements
        }
    }
}

/// Live Activity에 표시할 실제 저장 실측값이다. 의류 종류를 추측하지 않고
/// SwiftData의 `MeasuredValue`와 같은 표시명/값 순서를 그대로 전달한다.
nonisolated struct ProductCopyMeasurement: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let value: String
}

nonisolated struct ProductCopySession: Codable, Identifiable {
    let id: UUID
    let channel: CopyChannel
    let productID: String
    let payload: ProductCopyPayload
    var measurementItems: [ProductCopyMeasurement]? = nil
    let createdAt: Date

    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= 8 * 60 * 60 }

    func canReuse(productID: String, payload: ProductCopyPayload,
                  measurementItems: [ProductCopyMeasurement]) -> Bool {
        !isExpired && self.productID == productID && self.payload == payload
            && (self.measurementItems ?? []) == measurementItems
    }
}

@MainActor
enum ProductCopyStore {
    private static let sessionKey = "quickCopy.session.v3"
    private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "QuickCopy")

    static func save(_ session: ProductCopySession) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(session), forKey: sessionKey)
        logger.notice("Copy session saved. session=\(session.id.uuidString, privacy: .public) product=\(session.productID, privacy: .public)")
    }

    static func load() -> ProductCopySession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(ProductCopySession.self, from: data),
              !session.isExpired else {
            return nil
        }
        return session
    }

    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }
}
