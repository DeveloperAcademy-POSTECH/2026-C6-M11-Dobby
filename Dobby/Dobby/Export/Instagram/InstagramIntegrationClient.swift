import AuthenticationServices
import Foundation
import Security
import OSLog
import UIKit

struct InstagramAccount: Decodable {
    let id: String
    let username: String
    let profilePictureURL: URL?
}

struct InstagramAccountResponse: Decodable {
    let connected: Bool
    let account: InstagramAccount?
    let connectionMode: String?
}

struct InstagramPublishResult: Decodable {
    let published: Bool
    let mediaID: String
    let username: String
}

private struct InstagramErrorResponse: Decodable {
    let message: String?
    let code: Int?
    let subcode: Int?
    let traceID: String?
}

enum InstagramIntegrationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): value }
    }
}

@MainActor
final class InstagramIntegrationClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let maximumImageCount = 10
    private static let logger = Logger(subsystem: "com.dobby.instagram", category: "Publishing")
    private let session: URLSession
    private var authenticationSession: ASWebAuthenticationSession?

    init(session: URLSession = .shared) { self.session = session; super.init() }

    func account() async throws -> InstagramAccount? {
        let result: InstagramAccountResponse = try await send(path: "account", body: nil)
        guard result.connectionMode == "oauth" else {
            throw InstagramIntegrationError.message("Instagram 서버를 OAuth 로그인 버전으로 업데이트해 주세요.")
        }
        return result.connected ? result.account : nil
    }

    func connect() async throws -> InstagramAccount {
        guard authenticationSession == nil else { throw InstagramIntegrationError.message("이미 로그인 중입니다.") }
        let start: LoginStart = try await send(path: "oauth/start", body: Data("{}".utf8))
        guard let url = URL(string: start.authorizationURL), url.scheme == "https",
              url.host == "www.instagram.com", url.path == "/oauth/authorize" else {
            throw InstagramIntegrationError.message("Instagram 로그인 주소를 확인할 수 없습니다.")
        }
        defer { authenticationSession = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "dobby-copy") { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: InstagramIntegrationError.message("Instagram 로그인을 취소했습니다.")); return
                }
                guard error == nil, let callback, callback.scheme == "dobby-copy",
                      callback.host == "instagram", callback.path == "/oauth",
                      let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                      parts.queryItems?.first(where: { $0.name == "attempt" })?.value == start.attempt else {
                    continuation.resume(throwing: InstagramIntegrationError.message("로그인 응답을 확인할 수 없습니다. 다시 연결해 주세요.")); return
                }
                let status = parts.queryItems?.first(where: { $0.name == "status" })?.value
                guard status == "success" else {
                    continuation.resume(throwing: InstagramIntegrationError.message(status == "denied"
                        ? "Instagram 권한 승인이 취소되었습니다."
                        : "Instagram 연결에 실패했습니다. 프로페셔널 계정과 앱 테스트 권한을 확인해 주세요.")); return
                }
                continuation.resume()
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = true
            authenticationSession = auth
            if !auth.start() { continuation.resume(throwing: InstagramIntegrationError.message("로그인 창을 열 수 없습니다.")) }
        }
        guard let account = try await account() else { throw InstagramIntegrationError.message("연결이 저장되지 않았습니다. 다시 연결해 주세요.") }
        return account
    }

    func disconnect() async throws {
        let result: DisconnectResult = try await send(path: "disconnect", body: Data("{}".utf8))
        guard result.disconnected else { throw InstagramIntegrationError.message("연결을 해제하지 못했습니다.") }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        preconditionFailure("Instagram 로그인 창을 표시할 활성 화면이 없습니다.")
    }

    func publish(images: [Data], caption: String, accountID: String, requestID: String) async throws -> InstagramPublishResult {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 2200 else {
            throw InstagramIntegrationError.message("게시물 내용은 1~2,200자 이내로 입력해 주세요.")
        }
        guard !images.isEmpty else {
            throw InstagramIntegrationError.message("게시할 사진이 필요합니다.")
        }
        guard images.count <= Self.maximumImageCount else {
            throw InstagramIntegrationError.message("Instagram에는 사진을 최대 10장까지 게시할 수 있습니다.")
        }
        let jpegs = try Self.prepareImages(images)
        let body = try JSONEncoder().encode(Payload(caption: text,
            imagesBase64: jpegs.map { $0.base64EncodedString() }, accountID: accountID, requestID: requestID))
        let result: InstagramPublishResult = try await send(path: "publish", body: body)
        guard result.published else { throw InstagramIntegrationError.message("게시 완료를 확인하지 못했습니다. Instagram에서 확인 후 다시 시도해 주세요.") }
        return result
    }

    // Fit the complete image on a white canvas when its aspect ratio is outside feed bounds.
    static func prepareImage(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw InstagramIntegrationError.message("사진을 읽을 수 없습니다.")
        }
        let ratio = boundedRatio(for: image)
        return try prepareImage(image, ratio: ratio)
    }

    /// Instagram crops carousel items to the first item's ratio, so render every image on one canvas ratio.
    static func prepareImages(_ data: [Data]) throws -> [Data] {
        guard let firstData = data.first, let firstImage = UIImage(data: firstData),
              firstImage.size.width > 0, firstImage.size.height > 0 else {
            throw InstagramIntegrationError.message("사진을 읽을 수 없습니다.")
        }
        let ratio = boundedRatio(for: firstImage)
        return try data.map { item in
            guard let image = UIImage(data: item), image.size.width > 0, image.size.height > 0 else {
                throw InstagramIntegrationError.message("사진을 읽을 수 없습니다.")
            }
            return try prepareImage(image, ratio: ratio)
        }
    }

    static func publishingOrder(_ images: [Data], selectedIndex: Int) -> [Data] {
        guard images.indices.contains(selectedIndex) else { return images }
        var ordered = images
        let selected = ordered.remove(at: selectedIndex)
        ordered.insert(selected, at: 0)
        return ordered
    }

    private static func boundedRatio(for image: UIImage) -> CGFloat {
        min(max(image.size.width / image.size.height, 0.8), 1.91)
    }

    private static func prepareImage(_ image: UIImage, ratio: CGFloat) throws -> Data {
        let canvas = CGSize(width: 1080, height: 1080 / ratio)
        let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.85), jpeg.count <= 8 * 1024 * 1024 else {
            throw InstagramIntegrationError.message("사진 용량을 줄일 수 없습니다. 다른 사진을 선택해 주세요.")
        }
        return jpeg
    }

    private struct Payload: Encodable { let caption: String; let imagesBase64: [String]; let accountID: String; let requestID: String }
    private struct LoginStart: Decodable { let authorizationURL: String; let attempt: String }
    private struct DisconnectResult: Decodable { let disconnected: Bool }

    private func installationToken() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.dobby.instagram", kSecAttrAccount as String: "installation-token"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) { return token }
        guard status == errSecItemNotFound else { throw InstagramIntegrationError.message("안전한 연결 정보를 읽을 수 없습니다. 기기 잠금을 해제한 후 다시 시도해 주세요.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw InstagramIntegrationError.message("연결 정보를 만들 수 없습니다.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw InstagramIntegrationError.message("연결 정보를 안전하게 저장하지 못했습니다.") }
        return token
    }

    private func send<T: Decodable>(path: String, body: Data?) async throws -> T {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "InstagramBackendBaseURL") as? String,
              let url = URL(string: address), url.scheme == "https", url.host != nil,
              !address.contains("YOUR-"), !address.contains("$("),
              let key = Bundle.main.object(forInfoDictionaryKey: "InstagramAppAPIKey") as? String,
              !key.isEmpty, !key.contains("YOUR_"), !key.contains("$(") else {
            throw InstagramIntegrationError.message("Instagram 서버 주소와 앱 접근 키를 로컬 설정에 입력해 주세요.")
        }
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "X-Dobby-App-Key")
        request.setValue("Bearer \(try installationToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            let code = (error as NSError).code
            Self.logger.error("[Instagram] /\(path, privacy: .public) network code=\(code)")
            throw InstagramIntegrationError.message(path == "publish"
                ? "게시 결과를 확인하지 못했습니다. 중복 게시를 막기 위해 Instagram 계정을 먼저 확인해 주세요. (\(code))"
                : "서버에 연결할 수 없습니다. 네트워크를 확인해 주세요. (\(code))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw InstagramIntegrationError.message("서버 응답을 확인할 수 없습니다.")
        }
        Self.logger.info("[Instagram] /\(path, privacy: .public) HTTP \(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(InstagramErrorResponse.self, from: data)
            // Do not log raw responses: upstream messages can contain URLs or credentials.
            Self.logger.error("[Instagram] code=\(failure?.code ?? 0) subcode=\(failure?.subcode ?? 0) trace=\(failure?.traceID ?? "none", privacy: .public)")
            var message = failure?.message ?? "서버 요청에 실패했습니다. HTTP \(http.statusCode)"
            if let code = failure?.code { message += "\n오류 코드: \(code)" }
            if let trace = failure?.traceID { message += "\n추적 ID: \(trace)" }
            if path == "publish" { message += "\n재시도 전에 Instagram에 게시물이 생성되었는지 확인해 주세요." }
            throw InstagramIntegrationError.message(message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            throw InstagramIntegrationError.message("응답 형식을 확인할 수 없습니다. 게시 요청이었다면 Instagram에서 결과를 먼저 확인해 주세요.")
        }
    }
}
