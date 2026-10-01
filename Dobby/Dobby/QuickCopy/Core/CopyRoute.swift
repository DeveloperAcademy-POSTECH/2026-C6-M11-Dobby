import Foundation

nonisolated struct CopyRequest: Equatable {
    let sessionID: UUID
    let field: ProductCopyField
}

nonisolated enum CopyRoute {
    static let home = URL(string: "dobby-copy://home")!
    static func url(sessionID: UUID, field: ProductCopyField) -> URL {
        var components = URLComponents()
        components.scheme = "dobby-copy"
        components.host = "copy"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID.uuidString), URLQueryItem(name: "field", value: field.rawValue)]
        return components.url!
    }
    static func parse(_ url: URL) -> CopyRequest? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "dobby-copy", c.host == "copy", c.path.isEmpty,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let items = c.queryItems, items.count == 2,
              items.filter({ $0.name == "session" }).count == 1,
              items.filter({ $0.name == "field" }).count == 1,
              let id = items.first(where: { $0.name == "session" })?.value.flatMap(UUID.init(uuidString:)),
              let field = items.first(where: { $0.name == "field" })?.value.flatMap(ProductCopyField.init(rawValue:)) else { return nil }
        return CopyRequest(sessionID: id, field: field)
    }
}

nonisolated struct CopyRequestGate {
    private var lastRequest: CopyRequest?
    private var lastTime = Date.distantPast
    mutating func accept(_ request: CopyRequest, now: Date = Date()) -> Bool {
        guard request != lastRequest || now.timeIntervalSince(lastTime) >= 2 else { return false }
        lastRequest = request; lastTime = now
        return true
    }
}
