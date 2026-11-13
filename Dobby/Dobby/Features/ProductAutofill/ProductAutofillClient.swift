import Foundation

nonisolated struct ProductAutofillSource: Codable, Equatable, Sendable {
    let title: String
    let url: String

    /// Links are metadata, never executable or local-file URLs from model output.
    var publicURL: URL? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 300, url.count <= 2048,
              !url.contains(where: { $0.isWhitespace || $0 == "\\" }),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let result = components.url, let host = result.host()?.lowercased(),
              host.count <= 253, !host.hasSuffix("."), !host.contains(":"),
              !host.contains("%") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let reserved = ["localhost", "local", "localdomain", "internal", "lan", "home", "invalid", "test", "example", "onion"]
        guard labels.count >= 2, !reserved.contains(String(labels.last ?? "")),
              !host.hasSuffix(".home.arpa"),
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }),
              // Reject decimal, octal and hexadecimal IPv4 representations as well as ordinary IPs.
              !labels.allSatisfy({ label in
                  label.allSatisfy(\.isNumber)
                      || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit))
              }),
              labels.last?.contains(where: { $0.isLetter }) == true else { return nil }
        return result
    }
}

nonisolated struct ProductAutofillDraft: Codable, Equatable, Sendable {
    let productName: String
    let brand: String?
    let description: String
    let reviewNotes: [String]
    let sources: [ProductAutofillSource]

    init(productName: String, brand: String?, description: String, reviewNotes: [String],
         sources: [ProductAutofillSource] = []) {
        self.productName = productName
        self.brand = brand
        self.description = description
        self.reviewNotes = reviewNotes
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey { case productName, brand, description, reviewNotes, sources }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        productName = try values.decode(String.self, forKey: .productName)
        brand = try values.decodeIfPresent(String.self, forKey: .brand)
        description = try values.decode(String.self, forKey: .description)
        reviewNotes = try values.decode([String].self, forKey: .reviewNotes)
        sources = try values.decodeIfPresent([ProductAutofillSource].self, forKey: .sources) ?? []
    }

    /// Keep paragraph breaks intact; review notes are never merged into sales copy.
    var isValid: Bool {
        !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && productName.count <= 300
            && (brand.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 } ?? true)
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && description.count <= 1200
            && reviewNotes.count <= 14
            && reviewNotes.allSatisfy { !$0.isEmpty && $0.count <= 400 }
            && sources.count <= 3
            && sources.allSatisfy { $0.publicURL != nil }
    }
}

nonisolated protocol ProductAutofillGenerating: Sendable {
    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft
}

nonisolated enum ProductAutofillError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured, serverNotConfigured, unauthorized, invalidPhotos, unreadablePhoto, photoTooLarge
    case photoUnusable, offline, timeout, busy, serverUnavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "AI 연결을 준비하지 못했어요. 지금은 제품 정보를 직접 입력해 주세요."
        case .serverNotConfigured: "AI 서버의 연결 설정을 확인해야 해요. 지금은 제품 정보를 직접 입력할 수 있어요."
        case .unauthorized: "AI 연결 인증을 확인해 주세요. 지금은 제품 정보를 직접 입력할 수 있어요."
        case .invalidPhotos: "같은 제품에서 선택한 사진이 필요해요. 사진을 다시 선택해 주세요."
        case .unreadablePhoto: "선택한 사진을 읽지 못했어요. 사진을 다시 선택해 주세요."
        case .photoTooLarge: "AI에 보낼 사진의 용량을 줄이지 못했어요. 다른 사진으로 다시 시도해 주세요."
        case .photoUnusable: "사진에서 의류를 확인하기 어려워요. 제품 전체와 라벨이 선명한 사진을 선택해 주세요."
        case .offline: "인터넷 연결을 확인하고 다시 시도해 주세요. 제품 정보를 직접 입력할 수도 있어요."
        case .timeout: "AI 응답 시간이 길어지고 있어요. 다시 시도하거나 제품 정보를 직접 입력해 주세요."
        case .busy: "AI 요청이 많아요. 잠시 후 다시 시도하거나 제품 정보를 직접 입력해 주세요."
        case .serverUnavailable: "AI 정보를 생성하지 못했어요. 다시 시도하거나 제품 정보를 직접 입력해 주세요."
        case .invalidResponse: "생성된 정보를 확인하지 못했어요. 다시 시도하거나 제품 정보를 직접 입력해 주세요."
        }
    }
}

/// Product registration uses the web search pipeline.
/// This is part of the app configuration, independent of Xcode launch variables.
nonisolated enum ProductAutofillEndpoints {
    static let generation = URL(string: "https://dobby-openai.dobbyisvintage.workers.dev/v1/garments/autofill-web-detection")!
}

/// Builds the photo request for the web search pipeline.
nonisolated enum ProductAutofillWebRequest {
    static func make(photos: [ProductAutofillPhotoEncoder.Photo], endpoint: URL,
                     token: String, appAPIKey: String?) throws -> URLRequest {
        struct Body: Encodable { let photos: [ProductAutofillPhotoEncoder.Photo] }
        let body = try JSONEncoder().encode(Body(photos: photos))
        guard body.count <= 12 * 1024 * 1024 else { throw ProductAutofillError.photoTooLarge }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 95)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let appAPIKey { request.setValue(appAPIKey, forHTTPHeaderField: "X-Dobby-App-Key") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body
        return request
    }
}

/// The OpenAI key stays in the Worker. This client accepts an app authorization provider.
actor ProductAutofillClient: ProductAutofillGenerating {
    typealias BearerTokenProvider = @Sendable () async throws -> String?
    typealias AppAuthorizationProvider = @Sendable () async throws -> DobbyAppAuthorization?
    static let endpoint = ProductAutofillEndpoints.generation
    private let endpoint: URL
    private let session: URLSession
    private let diagnosticOrigin: String
    private let authorizationProvider: @Sendable () async throws -> RequestAuthorization?

    init(endpoint: URL = ProductAutofillClient.endpoint, session: URLSession = .shared,
         diagnosticOrigin: String = "productFlow", bearerTokenProvider: @escaping BearerTokenProvider) {
        self.endpoint = endpoint
        self.diagnosticOrigin = diagnosticOrigin
        self.session = session
        self.authorizationProvider = {
            guard let token = try await bearerTokenProvider() else { return nil }
            return RequestAuthorization(token: token, appAPIKey: nil)
        }
    }

    init(endpoint: URL = ProductAutofillClient.endpoint, session: URLSession = .shared,
         diagnosticOrigin: String = "productFlow", appAuthorizationProvider: @escaping AppAuthorizationProvider) {
        self.endpoint = endpoint
        self.diagnosticOrigin = diagnosticOrigin
        self.session = session
        self.authorizationProvider = {
            guard let authorization = try await appAuthorizationProvider() else { return nil }
            return RequestAuthorization(token: authorization.installationToken, appAPIKey: authorization.appAPIKey)
        }
    }

    @MainActor
    static func makeDefault(diagnosticOrigin: String = "productFlow") -> any ProductAutofillGenerating {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let mode = fixtureMode(environment: environment, isFixture: ProductAppStorage.fixtureDirectory != nil) {
            return ProductAutofillFixtureClient(mode: mode)
        }
        #endif
        if let appAPIKey = DobbyInstallationAuth.appAPIKey() {
            return ProductAutofillClient(diagnosticOrigin: diagnosticOrigin, appAuthorizationProvider: {
                try DobbyInstallationAuth.authorization(appAPIKey: appAPIKey)
            })
        }
        #if DEBUG
        // Compatibility for explicitly provisioned development installs only.
        // A configured common path never falls back or retries a failed AI request.
        return ProductAutofillClient(diagnosticOrigin: diagnosticOrigin, bearerTokenProvider: {
            try ProductAutofillDevelopmentAuth.token()
        })
        #else
        return ProductAutofillClient(diagnosticOrigin: diagnosticOrigin, appAuthorizationProvider: { nil })
        #endif
    }

    #if DEBUG
    nonisolated static func fixtureMode(environment: [String: String], isFixture: Bool) -> String? {
        guard isFixture, let mode = environment["DOBBY_AI_FIXTURE_RESULT"],
              ["success", "success-with-sources", "failure", "delay", "failure-once"].contains(mode) else { return nil }
        return mode
    }
    #endif

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ProductAutofillDraft.self) { group in
            group.addTask { try await self.performRequest(photos: photos) }
            group.addTask {
                try await Task.sleep(for: .seconds(105))
                throw ProductAutofillError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func performRequest(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        let processStarted = Date()
        var phaseTimes: [String: Double] = [:]
        try Task.checkCancellation()
        guard let authorization = try await authorizationProvider(), !authorization.token.isEmpty,
              authorization.token.count <= 1024, !authorization.token.contains(where: \.isWhitespace) else {
            throw ProductAutofillError.notConfigured
        }
        if let appAPIKey = authorization.appAPIKey {
            guard DobbyInstallationAuth.isValidAppAPIKey(appAPIKey),
                  DobbyInstallationAuth.isValidInstallationToken(authorization.token) else {
                throw ProductAutofillError.notConfigured
            }
        }
        let usesWebDetectionProcess = endpoint.path == "/v1/garments/autofill-web-detection"
        let usesLabelProcess = endpoint.path == "/v1/garments/autofill-labels"
        let encodingStarted = Date()
        let encodedPhotos = try ProductAutofillPhotoEncoder.encode(photos,
            totalBudget: usesLabelProcess ? 6 * 1024 * 1024 : ProductAutofillPhotoEncoder.maximumTotalBytes)
        try Task.checkCancellation()
        phaseTimes["encodingMs"] = Date().timeIntervalSince(encodingStarted) * 1000
        var labelCrops: [ProductAutofillLabelReader.Crop]? = nil
        if usesLabelProcess {
            let labelStarted = Date()
            do {
                let prepared = try await prepareLabelCrops(encodedPhotos, authorization: authorization)
                labelCrops = prepared.crops
                phaseTimes["labelDetectionMs"] = prepared.detectionMs
                phaseTimes["cropOCRMs"] = prepared.ocrMs
            }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Photo descriptions can still be generated, with an empty brand.
                labelCrops = []
            }
            phaseTimes["labelPreparationMs"] = Date().timeIntervalSince(labelStarted) * 1000
        }
        try Task.checkCancellation()
        var request: URLRequest
        if usesWebDetectionProcess {
            request = try ProductAutofillWebRequest.make(photos: encodedPhotos, endpoint: endpoint,
                token: authorization.token, appAPIKey: authorization.appAPIKey)
        } else {
            let body = try JSONEncoder().encode(Request(photos: encodedPhotos, labelCrops: labelCrops))
            guard body.count <= 12 * 1024 * 1024 else { throw ProductAutofillError.photoTooLarge }
            request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization")
            if let appAPIKey = authorization.appAPIKey {
                request.setValue(appAPIKey, forHTTPHeaderField: "X-Dobby-App-Key")
            }
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.httpBody = body
        }
        let finalRequestStarted = Date()
        #if DEBUG
        let diagnostic = ProductAutofillDiagnostics.begin(origin: diagnosticOrigin, endpoint: endpoint,
            encoded: encodedPhotos, assets: photos, labelCrops: labelCrops)
        var diagnosticOutcome = "interrupted"
        var diagnosticStatus: Int?
        var diagnosticDraft: ProductAutofillDraft?
        var diagnosticSearch: ProductAutofillDiagnostics.SearchActivity?
        defer {
            phaseTimes["finalRequestMs"] = Date().timeIntervalSince(finalRequestStarted) * 1000
            phaseTimes["totalMs"] = Date().timeIntervalSince(processStarted) * 1000
            ProductAutofillDiagnostics.finish(diagnostic, outcome: diagnosticOutcome, statusCode: diagnosticStatus,
                draft: diagnosticDraft, search: diagnosticSearch, timings: phaseTimes)
        }
        #endif
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw ProductAutofillError.invalidResponse }
            #if DEBUG
            diagnosticStatus = response.statusCode
            diagnosticSearch = .read(response)
            diagnosticOutcome = response.statusCode == 200 ? "invalidResponse" : "httpFailure"
            #endif
            guard data.count <= 64 * 1024 else { throw ProductAutofillError.invalidResponse }
            guard response.statusCode == 200 else {
                throw Self.failure(status: response.statusCode, data: data)
            }
            guard let draft = try? JSONDecoder().decode(ProductAutofillDraft.self, from: data), draft.isValid else {
                throw ProductAutofillError.invalidResponse
            }
            #if DEBUG
            diagnosticOutcome = "success"; diagnosticDraft = draft
            #endif
            return draft
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw ProductAutofillError.timeout }
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                throw ProductAutofillError.offline
            default: throw ProductAutofillError.serverUnavailable
            }
        }
    }

    private static func failure(status: Int, data: Data) -> ProductAutofillError {
        // Only known codes affect UI. Raw upstream messages, credentials and photos are not logged or shown.
        let code = (try? JSONDecoder().decode(FailureEnvelope.self, from: data))?.error.code
        if status == 401 || status == 403 { return .unauthorized }
        switch code {
        case "web_detection_configuration_error", "service_not_configured", "ai_configuration_error": return .serverNotConfigured
        case "photo_unusable": return .photoUnusable
        case "ai_timeout": return .timeout
        case "web_detection_rate_limited", "ai_rate_limited": return .busy
        case "web_detection_image_too_large", "photo_too_large", "photos_too_large", "request_too_large": return .photoTooLarge
        case "invalid_photo", "invalid_request", "invalid_photo_role", "invalid_json", "unsupported_content_type": return .invalidPhotos
        case "invalid_ai_response": return .invalidResponse
        default:
            if status == 429 { return .busy }
            if status == 504 { return .timeout }
            if status == 422 { return .photoUnusable }
            return .serverUnavailable
        }
    }

    private func prepareLabelCrops(_ photos: [ProductAutofillPhotoEncoder.Photo], authorization: RequestAuthorization) async throws -> (crops: [ProductAutofillLabelReader.Crop], detectionMs: Double, ocrMs: Double) {
        let detectionStarted = Date()
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("brand-label-regions")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization")
        if let key = authorization.appAPIKey { request.setValue(key, forHTTPHeaderField: "X-Dobby-App-Key") }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(Request(photos: photos, labelCrops: nil))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 64 * 1024 else { throw ProductAutofillError.invalidResponse }
        let regions = try JSONDecoder().decode(ProductAutofillLabelReader.Regions.self, from: data)
        let detectionMs = Date().timeIntervalSince(detectionStarted) * 1000
        let ocrStarted = Date()
        let crops = try await ProductAutofillLabelReader.prepare(photos: photos, regions: regions.regions)
        return (crops, detectionMs, Date().timeIntervalSince(ocrStarted) * 1000)
    }

    private struct Request: Encodable, Sendable {
        let photos: [ProductAutofillPhotoEncoder.Photo]
        let labelCrops: [ProductAutofillLabelReader.Crop]?
    }
    private struct RequestAuthorization: Sendable { let token: String; let appAPIKey: String? }
    private struct FailureEnvelope: Decodable { let error: FailureCode }
    private struct FailureCode: Decodable { let code: String }
}

#if DEBUG
/// Opt-in deterministic UI verification. It never contacts the Worker or OpenAI.
private actor ProductAutofillFixtureClient: ProductAutofillGenerating {
    let mode: String
    private var attempts = 0
    init(mode: String) { self.mode = mode }

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        guard !photos.isEmpty else { throw ProductAutofillError.invalidPhotos }
        attempts += 1
        let attempt = attempts
        try await Task.sleep(for: .milliseconds(mode == "delay" ? 5000 : 400))
        try Task.checkCancellation()
        if mode == "failure" || (mode == "failure-once" && attempt == 1) {
            throw ProductAutofillError.serverUnavailable
        }
        return ProductAutofillDraft(productName: "AI 테스트 네이비 집업 후드",
            brand: "TEST BRAND (테스트 브랜드)",
            description: "네이비 컬러와 전면 지퍼가 돋보이는 후드입니다.\n\n심플한 디자인으로 다양한 하의와 매치하기 좋습니다.",
            reviewNotes: ["라벨과 하자·오염 상태를 실물로 확인해 주세요."],
            sources: mode == "success-with-sources"
                ? [.init(title: "테스트 브랜드 아카이브", url: "https://example.com/archive/test-product")] : [])
    }
}
#endif
