import Foundation

nonisolated struct CopyRequest: Equatable {
    let sessionID: UUID
    let field: ProductCopyField
}

nonisolated enum CopyRoute {
    static func url(sessionID: UUID, field: ProductCopyField) -> URL {
        var components = URLComponents()
        components.scheme = "dobby-copy"
        components.host = "copy"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID.uuidString),
            URLQueryItem(name: "field", value: field.rawValue)
        ]
        return components.url!
    }

    static func parse(_ url: URL) -> CopyRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "dobby-copy",
              components.host == "copy",
              components.path.isEmpty,
              let items = components.queryItems,
              items.count == 2,
              items.filter({ $0.name == "session" }).count == 1,
              items.filter({ $0.name == "field" }).count == 1,
              let sessionID = items.first(where: { $0.name == "session" })?.value.flatMap(UUID.init(uuidString:)),
              let field = items.first(where: { $0.name == "field" })?.value.flatMap(ProductCopyField.init(rawValue:)) else {
            return nil
        }
        return CopyRequest(sessionID: sessionID, field: field)
    }
}
