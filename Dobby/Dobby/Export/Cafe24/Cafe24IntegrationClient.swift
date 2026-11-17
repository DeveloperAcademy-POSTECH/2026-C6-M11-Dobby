import AuthenticationServices
import Foundation
import OSLog
import Security
import UIKit

@MainActor
final class Cafe24IntegrationClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let maximumImageCount = 20

    private static let logger = Logger(subsystem: "com.dobby.cafe24", category: "Cafe24API")
    private let session: URLSession
    private var authenticationSession: ASWebAuthenticationSession?

    init(session: URLSession = .shared) { self.session = session }

    var isConfigured: Bool { backendBaseURL != nil && appAPIKey != nil }

    func connectionStatus() async throws -> Cafe24ConnectionStatus {
        try await send(authorizedRequest(path: "/connection", method: "GET"), as: Cafe24ConnectionStatus.self)
    }

    func disconnect() async throws {
        let result = try await send(
            authorizedRequest(path: "/connection", method: "DELETE"),
            as: Cafe24DisconnectResult.self
        )
        guard result.disconnected else {
            throw Cafe24IntegrationError.server("연결을 해제하지 못했습니다.")
        }
    }

    func connect(mallID rawMallID: String) async throws {
        let mallID = rawMallID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mallID.range(of: #"^[a-z0-9][a-z0-9_-]{1,39}$"#, options: .regularExpression) != nil else {
            throw Cafe24IntegrationError.invalidMallID
        }
        var components = URLComponents(url: try requireBackendURL().appendingPathComponent("oauth/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mall_id", value: mallID)]
        guard let url = components?.url else { throw Cafe24IntegrationError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try installationToken())", forHTTPHeaderField: "Authorization")
        request.setValue(try requireAppAPIKey(), forHTTPHeaderField: "X-Dobby-App-Key")
        let start = try await send(request, as: OAuthStartResponse.self)
        guard let authorizationURL = URL(string: start.authorizationURL) else { throw Cafe24IntegrationError.invalidResponse }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let auth = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: "dobby-copy") { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: Cafe24IntegrationError.authenticationCancelled); return
                }
                guard error == nil, let callbackURL,
                      URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "status" })?.value == "success" else {
                    continuation.resume(throwing: error ?? Cafe24IntegrationError.invalidResponse); return
                }
                continuation.resume()
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            authenticationSession = auth
            guard auth.start() else { continuation.resume(throwing: Cafe24IntegrationError.invalidResponse); return }
        }
    }

    func publish(productName rawProductName: String, description: String, price: Int,
                 images: [Data]) async throws -> Cafe24PublishResult {
        let productName = rawProductName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !productName.isEmpty else { throw Cafe24IntegrationError.invalidProductName }
        guard price >= 0 else { throw Cafe24IntegrationError.invalidPrice }
        guard !images.isEmpty else { throw Cafe24IntegrationError.missingImage }
        guard images.count <= Self.maximumImageCount else {
            throw Cafe24IntegrationError.tooManyImages
        }
        var request = try authorizedRequest(path: "/products", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Cafe24PublishRequest(
            productName: productName, description: description, price: price, supplyPrice: price,
            imagesBase64: images.map { $0.base64EncodedString() }))
        return try await send(request, as: Cafe24PublishResult.self)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        preconditionFailure("카페24 로그인 창을 표시할 활성 화면이 없습니다.")
    }

    private var backendBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "Cafe24BackendBaseURL") as? String,
              !value.contains("YOUR-WORKER"), let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }

    private func requireBackendURL() throws -> URL {
        guard let backendBaseURL else { throw Cafe24IntegrationError.backendNotConfigured }
        return backendBaseURL
    }

    private var appAPIKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "Cafe24AppAPIKey") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func requireAppAPIKey() throws -> String {
        guard let appAPIKey else { throw Cafe24IntegrationError.backendNotConfigured }
        return appAPIKey
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try requireBackendURL().appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(try installationToken())", forHTTPHeaderField: "Authorization")
        request.setValue(try requireAppAPIKey(), forHTTPHeaderField: "X-Dobby-App-Key")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, as: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Cafe24IntegrationError.invalidResponse }
        let method = request.httpMethod ?? "UNKNOWN"
        let path = request.url?.path ?? "(unknown path)"
        guard 200..<300 ~= http.statusCode else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes; not UTF-8>"
            Self.logger.error("[Cafe24] \(method, privacy: .public) \(path, privacy: .public) -> HTTP \(http.statusCode, privacy: .public) | \(responseBody, privacy: .public)")
            let decoded = try? JSONDecoder().decode(Cafe24ErrorResponse.self, from: data)
            throw Cafe24IntegrationError.server(decoded?.message ?? decoded?.error ?? "카페24 요청에 실패했습니다.")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes; not UTF-8>"
            Self.logger.error("[Cafe24] \(method, privacy: .public) \(path, privacy: .public) response decoding failed: \(error.localizedDescription, privacy: .public) | \(responseBody, privacy: .public)")
            throw Cafe24IntegrationError.invalidResponse
        }
    }

    private func installationToken() throws -> String {
        let service = "com.dobby.cafe24", account = "installation-token"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let token = String(data: data, encoding: .utf8) { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Cafe24IntegrationError.invalidResponse }
        let token = Data(bytes).base64EncodedString()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return token
    }
}

private struct OAuthStartResponse: Decodable { let authorizationURL: String }
