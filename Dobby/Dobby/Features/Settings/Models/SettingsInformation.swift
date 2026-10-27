import Foundation

enum SettingsInformation {
    static let privacyPolicyURL = URL(
        string: "https://profuse-list-349.notion.site/chak-404b4b9ddf0c806aa4f2ce677c724b0b?source=copy_link"
    )

    static var supportMailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "dobbyisvintage@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "[chak] 문의합니다")
        ]
        return components.url
    }

    static var versionText: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return "버전 정보 없음"
        }
        return "현재 버전 v\(version)"
    }
}
