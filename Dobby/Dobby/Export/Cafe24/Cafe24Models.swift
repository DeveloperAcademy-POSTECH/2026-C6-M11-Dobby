import Foundation

struct Cafe24ConnectionStatus: Decodable {
    let connected: Bool
    let mallID: String?
}

struct Cafe24DisconnectResult: Decodable {
    let disconnected: Bool
}

struct Cafe24PublishResult: Decodable {
    let productNo: Int
    let mallID: String
}

struct Cafe24ExportDraft {
    private let originalProductName: String
    private let originalProductDescription: String
    private let originalPriceText: String
    let category: String?
    let photos: [Data]
    var productName: String
    var productDescription: String
    var priceText: String

    var price: Int? {
        let digits = priceText.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    var validationMessage: String? {
        if productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "상품명을 입력해 주세요."
        }
        if photos.isEmpty {
            return Cafe24IntegrationError.missingImage.errorDescription
        }
        if photos.count > Cafe24IntegrationClient.maximumImageCount {
            return Cafe24IntegrationError.tooManyImages.errorDescription
        }
        if price == nil {
            return Cafe24IntegrationError.invalidPrice.errorDescription
        }
        return nil
    }

    var canPublish: Bool { validationMessage == nil }

    init(product: ExportProduct) {
        let productName = product.name.isEmpty ? "이름 없는 상품" : product.name
        let productDescription = [product.marketplacePayload.description, product.marketplacePayload.measurements]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        originalProductName = productName
        originalProductDescription = productDescription
        originalPriceText = product.marketplacePayload.price
        let category = product.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category?.isEmpty == false ? category : nil
        photos = product.exportPhotos
        self.productName = productName
        self.productDescription = productDescription
        priceText = product.marketplacePayload.price
    }

    mutating func resetProductName() {
        productName = originalProductName
    }

    mutating func resetProductDescription() {
        productDescription = originalProductDescription
    }

    mutating func resetPrice() {
        priceText = originalPriceText
    }
}

enum Cafe24IntegrationError: LocalizedError {
    case backendNotConfigured, invalidMallID, invalidProductName, invalidPrice, missingImage, tooManyImages
    case authenticationCancelled, invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "카페24 연동 서버 주소가 아직 설정되지 않았습니다."
        case .invalidMallID: "카페24 쇼핑몰 ID를 확인해 주세요."
        case .invalidProductName: "상품명을 입력해 주세요."
        case .invalidPrice: "판매가는 숫자로 입력해 주세요."
        case .missingImage: "카페24에 올릴 상품 사진이 필요해요."
        case .tooManyImages: "카페24에는 사진을 최대 20장까지 올릴 수 있어요."
        case .authenticationCancelled: "카페24 연결을 취소했습니다."
        case .invalidResponse: "서버 응답을 확인할 수 없습니다."
        case .server(let message): message
        }
    }
}

struct Cafe24PublishRequest: Encodable {
    let requestID: String
    let productName: String
    let description: String
    let category: String?
    let price: Int
    let supplyPrice: Int
    let imagesBase64: [String]
}

struct Cafe24ErrorResponse: Decodable {
    let error: String?
    let message: String?
}
