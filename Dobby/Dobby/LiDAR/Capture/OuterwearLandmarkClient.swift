import CoreGraphics
import Foundation

/// Returned points are normalized to the uploaded upright image. The core
/// landmark policy alone maps them back into the original RGB/depth frame.
nonisolated protocol OuterwearLandmarkProviding: Sendable {
    func recognize(image: CGImage, orientation: ImageOrientation, category: String,
                   requestID: UUID) async throws -> OuterwearLandmarkResponse
}

nonisolated protocol OuterwearCenterRefining: Sendable {
    func refineCenters(image: CGImage, context: NormalizedRect, crops: [OuterwearComparisonCrop],
                       category: String, requestID: UUID) async throws -> OuterwearLengthRefinementResponse
}

nonisolated enum OuterwearLandmarkClientError: Error, Equatable, LocalizedError, Sendable,
    AutomaticMeasurementFailureClassifying {
    case notConfigured, serverNotConfigured, unauthorized, invalidImage, imageTooLarge
    case photoUnusable, offline, timeout, busy, serverUnavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured, .serverNotConfigured:
            "아우터 AI 연결 설정을 확인해야 해요. 잠시 후 다시 시도해 주세요."
        case .unauthorized: "아우터 AI 연결 인증을 확인해 주세요."
        case .invalidImage, .imageTooLarge: "촬영한 사진을 AI에 전달하지 못했어요. 다시 시도해 주세요."
        case .photoUnusable: "사진에서 아우터의 측정점을 확인하지 못했어요. 이 사진에서 점을 직접 확인해 주세요."
        case .offline: "인터넷 연결을 확인하고 다시 시도해 주세요."
        case .timeout: "아우터 AI 응답 시간이 길어지고 있어요. 다시 시도해 주세요."
        case .busy: "아우터 AI 요청이 많아요. 잠시 후 다시 시도해 주세요."
        case .serverUnavailable: "아우터 측정점을 가져오지 못했어요. 다시 시도해 주세요."
        case .invalidResponse: "아우터 AI 측정점을 확인하지 못했어요. 다시 시도해 주세요."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .notConfigured, .serverNotConfigured, .unauthorized: .invalidConfiguration
        default: .providerFailure
        }
    }
}

/// Reuses the existing Worker and installation authorization. No OpenAI
/// credential, raw photo, or upstream diagnostic is logged by the client.
actor OuterwearLandmarkClient: OuterwearLandmarkProviding, OuterwearCenterRefining {
    typealias BearerTokenProvider = @Sendable () async throws -> String?
    typealias AppAuthorizationProvider = @Sendable () async throws -> DobbyAppAuthorization?
    static let endpoint = URL(string: "https://dobby-openai.dobbyisvintage.workers.dev/v4/garments/landmarks")!
    static let refinementEndpoint = URL(string: "https://dobby-openai.dobbyisvintage.workers.dev/v4/garments/landmark-refinement")!
    static let lengthRefinementEndpoint = URL(string: "https://dobby-openai.dobbyisvintage.workers.dev/v4/garments/length-refinement")!
    static let requestTimeout: TimeInterval = 25
    private let endpoint: URL
    private let refinementEndpoint: URL
    private let lengthRefinementEndpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let authorizationProvider: @Sendable () async throws -> RequestAuthorization?

    init(endpoint: URL = OuterwearLandmarkClient.endpoint, session: URLSession = .shared,
         timeout: TimeInterval = OuterwearLandmarkClient.requestTimeout,
         refinementEndpoint: URL = OuterwearLandmarkClient.refinementEndpoint,
         lengthRefinementEndpoint: URL = OuterwearLandmarkClient.lengthRefinementEndpoint,
         appAuthorizationProvider: @escaping AppAuthorizationProvider) {
        self.endpoint = endpoint
        self.refinementEndpoint = refinementEndpoint
        self.lengthRefinementEndpoint = lengthRefinementEndpoint
        self.session = session
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : Self.requestTimeout
        self.authorizationProvider = {
            guard let auth = try await appAuthorizationProvider() else { return nil }
            return RequestAuthorization(token: auth.installationToken, appAPIKey: auth.appAPIKey)
        }
    }

    init(endpoint: URL = OuterwearLandmarkClient.endpoint, session: URLSession = .shared,
         timeout: TimeInterval = OuterwearLandmarkClient.requestTimeout,
         refinementEndpoint: URL = OuterwearLandmarkClient.refinementEndpoint,
         lengthRefinementEndpoint: URL = OuterwearLandmarkClient.lengthRefinementEndpoint,
         bearerTokenProvider: @escaping BearerTokenProvider) {
        self.endpoint = endpoint
        self.refinementEndpoint = refinementEndpoint
        self.lengthRefinementEndpoint = lengthRefinementEndpoint
        self.session = session
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : Self.requestTimeout
        self.authorizationProvider = {
            guard let token = try await bearerTokenProvider() else { return nil }
            return RequestAuthorization(token: token, appAPIKey: nil)
        }
    }

    nonisolated static func makeDefault() -> OuterwearLandmarkClient {
        if let appAPIKey = DobbyInstallationAuth.appAPIKey() {
            return OuterwearLandmarkClient(appAuthorizationProvider: {
                try DobbyInstallationAuth.authorization(appAPIKey: appAPIKey)
            })
        }
        #if DEBUG
        // Compatibility with the same explicitly provisioned development
        // credential used by product autofill. Never retry using another identity.
        return OuterwearLandmarkClient(bearerTokenProvider: { try ProductAutofillDevelopmentAuth.token() })
        #else
        return OuterwearLandmarkClient(appAuthorizationProvider: { nil })
        #endif
    }

    func recognize(image: CGImage, orientation: ImageOrientation, category: String,
                   requestID: UUID) async throws -> OuterwearLandmarkResponse {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: OuterwearLandmarkResponse.self) { group in
            group.addTask {
                let encoded = try OuterwearLandmarkImageEncoder.encode(image, orientation: orientation)
                return try await self.performRequest(image: encoded, category: category, requestID: requestID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(self.timeout))
                throw OuterwearLandmarkClientError.timeout
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    /// At most one optional detail pass. Its entire encoding/network operation
    /// is bounded so a successful first pass can survive an unavailable retry.
    func refineCenters(image: CGImage, context: NormalizedRect, crops: [OuterwearComparisonCrop],
                       category: String, requestID: UUID) async throws -> OuterwearLengthRefinementResponse {
        guard crops.count == 2, Set(crops.map(\.region)) == Set([.upper, .hem]) else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        return try await withThrowingTaskGroup(of: OuterwearLengthRefinementResponse.self) { group in
            group.addTask {
                let encoded = try OuterwearLandmarkImageEncoder.encode(
                    OuterwearLandmarkImageEncoder.croppedImage(image, rect: context), orientation: .up)
                let regions = try crops.map { crop in
                    OuterwearLandmarkImageEncoder.Region(id: crop.region.rawValue,
                        image: try OuterwearLandmarkImageEncoder.encode(
                            OuterwearLandmarkImageEncoder.croppedImage(image, rect: crop.rect), orientation: .up))
                }
                try Task.checkCancellation()
                let data = try await self.sendRequest(image: encoded, regions: regions,
                    category: category, requestID: requestID, lengthOnly: true)
                do {
                    let result = try JSONDecoder().decode(OuterwearLengthRefinementResponse.self, from: data)
                    _ = try result.landmarkResponse(expectedRequestID: requestID.uuidString)
                    return result
                } catch { throw OuterwearLandmarkClientError.invalidResponse }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(min(12, self.timeout)))
                throw OuterwearLandmarkClientError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// The comparison runner persists these exact encoded inputs for replay.
    /// Each stage has its own deadline; refinement never retries a failed call.
    func recognizeEncoded(image: OuterwearLandmarkImageEncoder.Image,
                          regions: [OuterwearLandmarkImageEncoder.Region]? = nil,
                          category: String, requestID: UUID) async throws -> OuterwearLandmarkResponse {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: OuterwearLandmarkResponse.self) { group in
            group.addTask { try await self.performRequest(image: image, regions: regions, category: category, requestID: requestID) }
            group.addTask {
                try await Task.sleep(for: .seconds(self.timeout))
                throw OuterwearLandmarkClientError.timeout
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private func performRequest(image: OuterwearLandmarkImageEncoder.Image,
                                regions: [OuterwearLandmarkImageEncoder.Region]? = nil, category: String,
                                requestID: UUID) async throws -> OuterwearLandmarkResponse {
        let data = try await sendRequest(image: image, regions: regions, category: category, requestID: requestID)
        do {
            let decoded: OuterwearLandmarkResponse
            if regions != nil {
                let envelope = try JSONDecoder().decode(RefinementEnvelope.self, from: data)
                guard envelope.refinementVersion == "outerwear-front-gap-refinement-v4" else {
                    throw OuterwearLandmarkClientError.invalidResponse
                }
                decoded = envelope.localResponse
            } else {
                decoded = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: data)
            }
            guard decoded.schemaVersion == OuterwearLandmarkResponse.expectedGapSchemaVersion,
                  decoded.modelVersion == OuterwearLandmarkResponse.expectedGapModelVersion else {
                throw OuterwearLandmarkClientError.invalidResponse
            }
            try decoded.validate(expectedRequestID: requestID.uuidString)
            return decoded
        } catch { throw OuterwearLandmarkClientError.invalidResponse }
    }

    private func sendRequest(image: OuterwearLandmarkImageEncoder.Image,
                             regions: [OuterwearLandmarkImageEncoder.Region]? = nil, category: String,
                             requestID: UUID, lengthOnly: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let authorization: RequestAuthorization?
        do { authorization = try await authorizationProvider() }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw OuterwearLandmarkClientError.notConfigured
        }
        guard let authorization, !authorization.token.isEmpty, authorization.token.utf8.count <= 1024,
              authorization.token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw OuterwearLandmarkClientError.notConfigured
        }
        if let appAPIKey = authorization.appAPIKey {
            guard DobbyInstallationAuth.isValidAppAPIKey(appAPIKey),
                  DobbyInstallationAuth.isValidInstallationToken(authorization.token) else {
                throw OuterwearLandmarkClientError.notConfigured
            }
        }
        guard !category.isEmpty, category.utf8.count <= 100 else { throw OuterwearLandmarkClientError.invalidImage }
        try Task.checkCancellation()
        let body: Data
        if let regions {
            let expected = lengthOnly ? ["upper", "hem"] : OuterwearComparisonRegion.allCases.filter { $0 != .garment }.map(\.rawValue)
            guard regions.count == expected.count, Set(regions.map(\.id)) == Set(expected) else {
                throw OuterwearLandmarkClientError.invalidImage
            }
            body = try JSONEncoder().encode(RefinementRequest(requestId: requestID.uuidString, image: image, category: category, regions: regions))
        } else {
            body = try JSONEncoder().encode(Request(requestId: requestID.uuidString, image: image, category: category))
        }
        let url = lengthOnly ? lengthRefinementEndpoint : regions == nil ? endpoint : refinementEndpoint
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: lengthOnly ? min(12, timeout) : timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization")
        if let appAPIKey = authorization.appAPIKey {
            request.setValue(appAPIKey, forHTTPHeaderField: "X-Dobby-App-Key")
        }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, data.count <= 64 * 1024 else {
                throw OuterwearLandmarkClientError.invalidResponse
            }
            guard response.statusCode == 200 else { throw Self.failure(status: response.statusCode, data: data) }
            return data
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw OuterwearLandmarkClientError.timeout }
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                throw OuterwearLandmarkClientError.offline
            default: throw OuterwearLandmarkClientError.serverUnavailable
            }
        }
    }

    private static func failure(status: Int, data: Data) -> OuterwearLandmarkClientError {
        let code = (try? JSONDecoder().decode(FailureEnvelope.self, from: data))?.error.code
        if status == 401 || status == 403 { return .unauthorized }
        switch code {
        case "service_not_configured", "ai_configuration_error": return .serverNotConfigured
        case "photo_unusable": return .photoUnusable
        case "ai_timeout": return .timeout
        case "ai_rate_limited": return .busy
        case "photo_too_large", "request_too_large": return .imageTooLarge
        case "invalid_photo", "invalid_request", "invalid_json", "unsupported_content_type": return .invalidImage
        case "invalid_ai_response": return .invalidResponse
        default:
            if status == 429 { return .busy }
            if status == 504 { return .timeout }
            if status == 422 { return .photoUnusable }
            return .serverUnavailable
        }
    }

    private struct Request: Encodable, Sendable {
        let requestId: String
        let image: OuterwearLandmarkImageEncoder.Image
        let category: String
    }
    private struct RefinementRequest: Encodable, Sendable {
        let requestId: String
        let image: OuterwearLandmarkImageEncoder.Image
        let category: String
        let regions: [OuterwearLandmarkImageEncoder.Region]
    }
    private struct RefinementEnvelope: Decodable {
        let refinementVersion: String
        let localResponse: OuterwearLandmarkResponse
    }
    private struct RequestAuthorization: Sendable { let token: String; let appAPIKey: String? }
    private struct FailureEnvelope: Decodable { let error: FailureCode }
    private struct FailureCode: Decodable { let code: String }
}
