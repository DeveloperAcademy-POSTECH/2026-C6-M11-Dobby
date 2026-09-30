import SwiftUI

struct ProductCopyControlLabel: View {
    let field: ProductCopyField
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc").foregroundStyle(.orange)
            Text(field.title).font(.caption2.weight(.medium)).foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)) }
    }
}

struct ProductCopyPanel: View {
    let sessionID: UUID
    let mode: CopyExperimentMode
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { control(.productName); control(.description) }
            HStack(spacing: 8) { control(.brand); control(.measurements) }
        }
    }
    private func control(_ field: ProductCopyField) -> some View {
        Link(destination: CopyRoute.url(sessionID: sessionID, field: field)) {
            ProductCopyControlLabel(field: field)
        }.buttonStyle(.plain)
    }
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
}
