import Foundation

struct Cafe24ConnectionStatus: Decodable {
    let connected: Bool
    let mallID: String?
}

struct Cafe24PublishResult: Decodable {
    let productNo: Int
    let mallID: String
}

enum Cafe24IntegrationError: LocalizedError {
    case backendNotConfigured, invalidMallID, invalidPrice, authenticationCancelled, invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "카페24 연동 서버 주소가 아직 설정되지 않았습니다."
        case .invalidMallID: "카페24 쇼핑몰 ID를 확인해 주세요."
        case .invalidPrice: "판매가는 숫자로 입력해 주세요."
        case .authenticationCancelled: "카페24 연결을 취소했습니다."
        case .invalidResponse: "서버 응답을 확인할 수 없습니다."
        case .server(let message): message
        }
    }
}

struct Cafe24PublishRequest: Encodable {
    let productName: String
    let description: String
    let price: Int
    let supplyPrice: Int
    let imageBase64: String?
}

struct Cafe24ErrorResponse: Decodable {
    let error: String?
    let message: String?
}
