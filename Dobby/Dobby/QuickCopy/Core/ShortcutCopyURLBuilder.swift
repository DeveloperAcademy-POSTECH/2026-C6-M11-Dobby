import Foundation

nonisolated enum ShortcutCopyURLBuilder {
    static let testShortcutName = "Dobby 테스트 복사"

    static func url(forAppShortcutNamed name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name)
        ]
        return components.url
    }

    static func url(for field: ProductCopyField) -> URL? {
        url(forAppShortcutNamed: field.appShortcutName)
    }

    static var testURL: URL? { url(forAppShortcutNamed: testShortcutName) }
}
