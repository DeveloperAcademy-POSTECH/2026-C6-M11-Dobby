import Foundation

nonisolated enum ForegroundCopyURLBuilder {
    static func url(for field: ProductCopyField) -> URL? {
        var components = URLComponents()
        components.scheme = "dobby-copy"
        components.host = "copy"
        components.queryItems = [URLQueryItem(name: "field", value: field.rawValue)]
        return components.url
    }

    static var testURL: URL {
        URL(string: "dobby-copy://copy-test")!
    }
}
