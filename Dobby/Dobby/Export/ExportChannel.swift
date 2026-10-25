import Foundation

/// 내보내기 화면에 표시할 채널입니다. rawValue는 방문 기록 식별자로 유지합니다.
enum ExportChannel: String, CaseIterable, Identifiable, Codable {
    case instagram
    case naverStore
    case cafe24
    case fruitsFamily

    /// 현재 앱에서 새 내보내기에 사용할 수 있는 채널입니다.
    static let availableCases: [ExportChannel] = [.instagram, .cafe24, .fruitsFamily]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instagram:
            return "Instagram으로 내보내기"
        case .naverStore:
            return "네이버스토어로 내보내기"
        case .cafe24:
            return "카페24로 내보내기"
        case .fruitsFamily:
            return "후루츠패밀리로 내보내기"
        }
    }

    var shortTitle: String {
        switch self {
        case .instagram:
            return "Instagram"
        case .naverStore:
            return "네이버스토어"
        case .cafe24:
            return "Cafe24"
        case .fruitsFamily:
            return "후루츠패밀리"
        }
    }

    var imageName: String {
        switch self {
        case .instagram:
            return "InstagramLogo"
        case .naverStore:
            return "NaverStoreLogo"
        case .cafe24:
            return "Cafe24Logo"
        case .fruitsFamily:
            return "FruitsFamailyLogo"
        }
    }

    /// URL 열기 요청의 성공 여부를 채널별로 저장할 키입니다.
    var openedLinkStorageKey: String {
        "export.openedLink.\(rawValue)"
    }

    var destinationURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .instagram:
            components.host = "www.instagram.com"
            components.path = "/"
        case .naverStore:
            components.host = "sell.smartstore.naver.com"
            components.path = "/"
        case .cafe24:
            components.host = "eclogin.cafe24.com"
            components.path = "/Shop/"
        case .fruitsFamily:
            components.host = "fruitsfamily.com"
            components.path = "/"
        }
        guard let url = components.url else {
            preconditionFailure("내보내기 채널 URL 구성을 확인해 주세요.")
        }
        return url
    }
}
