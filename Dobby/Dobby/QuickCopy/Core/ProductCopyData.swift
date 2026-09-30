import Foundation
import OSLog

nonisolated enum ProductCopyField: String, Codable, CaseIterable, Identifiable {
    case productName, description, brand, measurements
    var id: String { rawValue }
    var title: String {
        switch self {
        case .productName: "제품명 복사"
        case .description: "설명 복사"
        case .brand: "브랜드명 복사"
        case .measurements: "실측 사이즈 복사"
        }
    }
    var copiedMessage: String {
        switch self {
        case .productName: "상품명이 복사되었습니다."
        case .description: "설명이 복사되었습니다."
        case .brand: "브랜드명이 복사되었습니다."
        case .measurements: "실측 사이즈가 복사되었습니다."
        }
    }
    var copyFailureMessage: String {
        switch self {
        case .productName: "상품명 복사를 확인하지 못했습니다."
        case .description: "설명 복사를 확인하지 못했습니다."
        case .brand: "브랜드명 복사를 확인하지 못했습니다."
        case .measurements: "실측 사이즈 복사를 확인하지 못했습니다."
        }
    }
}

nonisolated enum CopyChannel: String, Codable, CaseIterable, Identifiable {
    case fruits, instagram
    var id: String { rawValue }
    var title: String { self == .fruits ? "후루츠패밀리" : "Instagram" }
    var destination: URL {
        URL(string: self == .fruits ? "https://fruitsfamily.com/" : "https://www.instagram.com/")!
    }
}

nonisolated enum CopyWriteStrategy: String, Codable, CaseIterable, Identifiable {
    case setItemsLocalOnly
    case setItemsShared
    case stringProperty
    case setObjects

    var id: String { rawValue }
    var title: String {
        switch self {
        case .setItemsLocalOnly: "setItems · localOnly"
        case .setItemsShared: "setItems · 공유 허용"
        case .stringProperty: "pasteboard.string"
        case .setObjects: "setObjects · localOnly"
        }
    }
}

nonisolated enum CopyInteractionMode: String, Codable, CaseIterable, Identifiable {
    case direct
    case foreground
    case foregroundAndOpen

    var id: String { rawValue }
    var title: String {
        switch self {
        case .direct: "Island에서 직접 복사"
        case .foreground: "Dobby에서 복사 · 직접 복귀"
        case .foregroundAndOpen: "Dobby에서 복사 · 후루츠 다시 열기"
        }
    }
}

nonisolated struct ProductCopyPayload: Codable, Equatable {
    let productName: String
    let description: String
    let brand: String
    let measurements: String
    let price: String
    let length: String
    let waist: String
    let thigh: String

    func value(for field: ProductCopyField) -> String {
        switch field {
        case .productName: productName
        case .description: description
        case .brand: brand
        case .measurements: measurements
        }
    }


}

nonisolated struct ProductCopySession: Codable, Identifiable {
    let id: UUID
    let channel: CopyChannel
    let productID: String
    let payload: ProductCopyPayload
    let createdAt: Date
    let writeStrategy: CopyWriteStrategy?
    let diagnosticToken: String?
    let diagnosticCondition: String?
    let interactionMode: CopyInteractionMode?
    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= 8 * 60 * 60 }
    var effectiveWriteStrategy: CopyWriteStrategy { writeStrategy ?? .stringProperty }

    init(
        id: UUID,
        channel: CopyChannel,
        productID: String,
        payload: ProductCopyPayload,
        createdAt: Date,
        writeStrategy: CopyWriteStrategy? = nil,
        diagnosticToken: String? = nil,
        diagnosticCondition: String? = nil,
        interactionMode: CopyInteractionMode? = nil
    ) {
        self.id = id
        self.channel = channel
        self.productID = productID
        self.payload = payload
        self.createdAt = createdAt
        self.writeStrategy = writeStrategy
        self.diagnosticToken = diagnosticToken
        self.diagnosticCondition = diagnosticCondition
        self.interactionMode = interactionMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, channel, productID, payload, createdAt
        case writeStrategy, diagnosticToken, diagnosticCondition, interactionMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        channel = try values.decode(CopyChannel.self, forKey: .channel)
        productID = try values.decode(String.self, forKey: .productID)
        payload = try values.decode(ProductCopyPayload.self, forKey: .payload)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        writeStrategy = try values.decodeIfPresent(CopyWriteStrategy.self, forKey: .writeStrategy)
        diagnosticToken = try values.decodeIfPresent(String.self, forKey: .diagnosticToken)
        diagnosticCondition = try values.decodeIfPresent(String.self, forKey: .diagnosticCondition)
        interactionMode = try values.decodeIfPresent(CopyInteractionMode.self, forKey: .interactionMode)
    }

    func canReuse(productID: String, payload: ProductCopyPayload, writeStrategy: CopyWriteStrategy = .stringProperty) -> Bool {
        !isExpired && self.productID == productID && self.payload == payload
            && effectiveWriteStrategy == writeStrategy && diagnosticToken == nil
    }
}

nonisolated struct CopyDiagnosticResult: Codable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let field: ProductCopyField
    let executionMode: String
    let canContinueInForeground: Bool
    let processName: String
    let bundleIdentifier: String
    let beforeChangeCount: Int
    let afterChangeCount: Int
    let readBackMatches: Bool
    let elapsedMilliseconds: Int
    let createdAt: Date
    let writeStrategy: CopyWriteStrategy?
    let diagnosticToken: String?
    let diagnosticCondition: String?

    init(
        id: UUID,
        sessionID: UUID,
        field: ProductCopyField,
        executionMode: String,
        canContinueInForeground: Bool,
        processName: String,
        bundleIdentifier: String,
        beforeChangeCount: Int,
        afterChangeCount: Int,
        readBackMatches: Bool,
        elapsedMilliseconds: Int,
        createdAt: Date,
        writeStrategy: CopyWriteStrategy? = nil,
        diagnosticToken: String? = nil,
        diagnosticCondition: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.field = field
        self.executionMode = executionMode
        self.canContinueInForeground = canContinueInForeground
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.beforeChangeCount = beforeChangeCount
        self.afterChangeCount = afterChangeCount
        self.readBackMatches = readBackMatches
        self.elapsedMilliseconds = elapsedMilliseconds
        self.createdAt = createdAt
        self.writeStrategy = writeStrategy
        self.diagnosticToken = diagnosticToken
        self.diagnosticCondition = diagnosticCondition
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, field, executionMode, canContinueInForeground
        case processName, bundleIdentifier, beforeChangeCount, afterChangeCount
        case readBackMatches, elapsedMilliseconds, createdAt
        case writeStrategy, diagnosticToken, diagnosticCondition
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        field = try values.decode(ProductCopyField.self, forKey: .field)
        executionMode = try values.decode(String.self, forKey: .executionMode)
        canContinueInForeground = try values.decode(Bool.self, forKey: .canContinueInForeground)
        processName = try values.decode(String.self, forKey: .processName)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        beforeChangeCount = try values.decode(Int.self, forKey: .beforeChangeCount)
        afterChangeCount = try values.decode(Int.self, forKey: .afterChangeCount)
        readBackMatches = try values.decode(Bool.self, forKey: .readBackMatches)
        elapsedMilliseconds = try values.decode(Int.self, forKey: .elapsedMilliseconds)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        writeStrategy = try values.decodeIfPresent(CopyWriteStrategy.self, forKey: .writeStrategy)
        diagnosticToken = try values.decodeIfPresent(String.self, forKey: .diagnosticToken)
        diagnosticCondition = try values.decodeIfPresent(String.self, forKey: .diagnosticCondition)
    }

    var writeVerified: Bool {
        afterChangeCount > beforeChangeCount && readBackMatches
    }
}

@MainActor
enum ProductCopyStore {
    private static let sessionKey = "quickCopy.session.v2"
    private static let diagnosticsKey = "quickCopy.diagnostics.v1"
    private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "QuickCopy")

    static func save(_ session: ProductCopySession) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(session), forKey: sessionKey)
        logger.notice("Copy session saved. session=\(session.id.uuidString, privacy: .public) product=\(session.productID, privacy: .public)")
    }
    static func load() -> ProductCopySession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else {
            logger.error("Copy session data is missing from app UserDefaults")
            return nil
        }
        guard let session = try? JSONDecoder().decode(ProductCopySession.self, from: data) else {
            logger.error("Copy session data could not be decoded. byteCount=\(data.count)")
            return nil
        }
        guard !session.isExpired else {
            logger.error("Copy session expired. session=\(session.id.uuidString, privacy: .public)")
            return nil
        }
        return session
    }
    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
        logger.notice("Copy session invalidated")
    }

    static func saveDiagnostic(_ result: CopyDiagnosticResult) {
        let updated = Array(([result] + diagnostics()).prefix(100))
        guard let data = try? JSONEncoder().encode(updated) else {
            logger.error("Copy diagnostic result could not be encoded")
            return
        }
        UserDefaults.standard.set(data, forKey: diagnosticsKey)
    }

    static func diagnostics() -> [CopyDiagnosticResult] {
        guard let data = UserDefaults.standard.data(forKey: diagnosticsKey),
              let results = try? JSONDecoder().decode([CopyDiagnosticResult].self, from: data) else {
            return []
        }
        return results
    }

    static func clearDiagnostics() {
        UserDefaults.standard.removeObject(forKey: diagnosticsKey)
    }
}
