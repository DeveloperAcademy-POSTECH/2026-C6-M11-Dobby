import Foundation

nonisolated enum ShortcutCopyURLBuilder {
    static let shortcutName = "Dobby 복사"

    static func url(for text: String) -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text)
        ]
        return components.url
    }

    static var shortcutsAppURL: URL {
        URL(string: "shortcuts://")!
    }
}
