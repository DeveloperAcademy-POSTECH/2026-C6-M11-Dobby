import Foundation

struct NaverCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let wholeCategoryName: String
}

struct NaverPublishRequest: Encodable {
    let productName: String
    let description: String
    let price: Int
    let categoryID: String
    let material: String
    let color: String
    let size: String
    let imageBase64: String
}

struct NaverPublishResult: Decodable {
    let originProductNo: Int
    let smartstoreChannelProductNo: Int
}

struct NaverErrorResponse: Decodable {
    let error: String?
    let message: String?
}

enum NaverStoreIntegrationError: LocalizedError {
    case backendNotConfigured
    case invalidPrice
    case missingImage
    case missingCategory
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "네이버 테스트 서버 주소가 설정되지 않았습니다."
        case .invalidPrice: "판매 가격은 10원 이상 입력해 주세요."
        case .missingImage: "등록할 상품 사진이 필요합니다."
        case .missingCategory: "상품 카테고리를 선택해 주세요."
        case .invalidResponse: "서버 응답을 확인할 수 없습니다."
        case .server(let message): message
        }
    }
}
