import Foundation
import OSLog

@MainActor
final class NaverStoreIntegrationClient {
    private static let logger = Logger(subsystem: "com.dobby.naver", category: "NaverCommerceAPI")
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    var isConfigured: Bool { backendBaseURL != nil && appAPIKey != nil }

    func searchCategories(query: String) async throws -> [NaverCategory] {
        var components = URLComponents(url: try requireBackendURL().appendingPathComponent("categories"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw NaverStoreIntegrationError.invalidResponse }
        return try await send(request(url: url, method: "GET"), as: [NaverCategory].self)
    }

    func publish(product: ExportProduct, price: Int, category: NaverCategory,
                 material: String, color: String, size: String) async throws -> NaverPublishResult {
        guard price >= 10 else { throw NaverStoreIntegrationError.invalidPrice }
        guard let imageData = product.imageData else { throw NaverStoreIntegrationError.missingImage }
        var request = try request(url: requireBackendURL().appendingPathComponent("products"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let description = [product.fruits.description, product.fruits.measurements]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        request.httpBody = try JSONEncoder().encode(NaverPublishRequest(
            productName: product.name,
            description: description,
            price: price,
            categoryID: category.id,
            material: material,
            color: color,
            size: size,
            imageBase64: imageData.base64EncodedString()
        ))
        return try await send(request, as: NaverPublishResult.self)
    }

    private var backendBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NaverBackendBaseURL") as? String,
              !value.isEmpty, !value.contains("$("), let url = URL(string: value) else { return nil }
        return url
    }

    private var appAPIKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "Cafe24AppAPIKey") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func requireBackendURL() throws -> URL {
        guard let backendBaseURL else { throw NaverStoreIntegrationError.backendNotConfigured }
        return backendBaseURL
    }

    private func request(url: URL, method: String) throws -> URLRequest {
        guard let appAPIKey else { throw NaverStoreIntegrationError.backendNotConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(appAPIKey, forHTTPHeaderField: "X-Dobby-App-Key")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, as: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NaverStoreIntegrationError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<응답 본문 없음>"
            Self.logger.error("[Naver] HTTP \(http.statusCode, privacy: .public) | \(body, privacy: .public)")
            let error = try? JSONDecoder().decode(NaverErrorResponse.self, from: data)
            throw NaverStoreIntegrationError.server(error?.message ?? error?.error ?? body)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch {
            Self.logger.error("[Naver] decoding failed: \(error.localizedDescription, privacy: .public)")
            throw NaverStoreIntegrationError.invalidResponse
        }
    }
}
