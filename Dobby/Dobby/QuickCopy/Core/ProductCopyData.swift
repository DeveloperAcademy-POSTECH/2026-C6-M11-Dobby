import Foundation

enum ProductCopyField: String, Codable, CaseIterable, Identifiable {
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

enum CopyChannel: String, Codable, CaseIterable, Identifiable {
    case fruits, instagram
    var id: String { rawValue }
    var title: String { self == .fruits ? "후르츠패밀리" : "Instagram" }
    var destination: URL {
        URL(string: self == .fruits ? "https://fruitsfamily.com/" : "https://www.instagram.com/")!
    }
}

enum CopyExperimentMode: String, Codable, CaseIterable, Identifiable {
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

struct ProductCopyPayload: Codable {
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

    static func sample(for channel: CopyChannel) -> Self {
        let name = "LEVI'S 550 보로 사시코 커스텀 팬츠"
        let priceLine = channel == .fruits ? "56,000" : "65,000 >팔로우 시 55,000"
        return Self(productName: name, description: """
        \(name)

        Size 59 43 32
        (총장 허리 허벅지)단면cm

        Price- \(priceLine)

        기본 배송료 4,000
        2개이상 구매시 배송비 무료

        모든 상품은 세탁 및 고온 스팀 살균 작업까지
        마친 상품입니다 (특수 제품 제외)

        사이즈는 실측을 기준으로 본인 옷하고 비교하는것이 가장 정확합니다.
        모델의 스팩이나 표기사이즈는
        별 도움이 안됩니다

        착샷이 제일 실물과 색감이 비슷합니다

        자신에게 맞는 제품은 언젠가 들어오니 천천히 비교해 보고 구매하세요😘

        검수 중 미쳐 확인치 못한 오염이나 하자가 있을 수 있습니다.
        상세 사진들 원하시면 보내드리니 원하는 부위 dm으로 보내주세요
        교환이나 환불이 어려우니 신중한 구매 부탁드립니다.

        오프라인 매장 소식 @okaoka_vtg

        #okaoka#오카오카#빈티지샵#포항빈티지샵
        """, brand: "LEVI'S", measurements: "총장 59 cm\n허리 단면 43 cm\n허벅지 단면 32 cm",
                    price: channel == .fruits ? "56000" : "65000", length: "59", waist: "43", thigh: "32")
    }
}

struct ProductCopySession: Codable, Identifiable {
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
