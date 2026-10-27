import Foundation
import UIKit

enum SettingsInformation {
    static let privacyPolicyURL = URL(
        string: "https://profuse-list-349.notion.site/chak-404b4b9ddf0c806aa4f2ce677c724b0b?source=copy_link"
    )

    static var supportMailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "dobbyisvintage@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "[chak] 문의합니다"),
            URLQueryItem(name: "body", value: supportMailBody)
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

    private static var supportMailBody: String {
        """
        문의 내용을 작성해 주세요.


        ---
        앱 버전: \(appVersion)
        빌드: \(buildNumber)
        iOS 버전: \(UIDevice.current.systemVersion)
        기기: \(deviceDescription)
        """
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "알 수 없음"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "알 수 없음"
    }

    private static var deviceDescription: String {
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "시뮬레이터 (\(model))"
        }
        return "\(UIDevice.current.model) (\(deviceIdentifier))"
    }

    private static var deviceIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
