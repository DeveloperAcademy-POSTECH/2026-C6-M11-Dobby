import Foundation
import Security

/// App-level access plus a stable installation owner. OpenAI credentials stay on the Worker.
nonisolated struct DobbyAppAuthorization: Equatable, Sendable {
    let appAPIKey: String
    let installationToken: String
}

nonisolated enum DobbyInstallationAuthError: Error, Equatable, LocalizedError, Sendable {
    case storageUnavailable, generationFailed, invalidStoredToken

    var errorDescription: String? {
        switch self {
        case .storageUnavailable, .invalidStoredToken:
            "안전한 연결 정보를 읽을 수 없습니다. 기기 잠금을 해제한 후 다시 시도해 주세요."
        case .generationFailed:
            "연결 정보를 만들 수 없습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}

/// Instagram and the AI Worker use the same existing app key and installation owner.
/// Never replace an existing owner: connected Instagram accounts are associated with it.
nonisolated enum DobbyInstallationAuth {
    static func appAPIKey(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "InstagramAppAPIKey") as? String,
              isValidAppAPIKey(value) else { return nil }
        return value
    }

    static func isValidAppAPIKey(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 1024
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
            && !value.contains("$(")
            && !value.uppercased().contains("YOUR_")
            && !value.uppercased().contains("YOUR-")
    }

    static func isValidInstallationToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func authorization(appAPIKey: String?,
                              store: any DobbyInstallationTokenStoring = DobbyInstallationKeychain(),
                              makeToken: @Sendable () throws -> String = makeInstallationToken) throws -> DobbyAppAuthorization? {
        // Missing or unresolved app configuration must not create a new Keychain owner.
        guard let appAPIKey, isValidAppAPIKey(appAPIKey) else { return nil }
        return DobbyAppAuthorization(appAPIKey: appAPIKey,
            installationToken: try installationToken(store: store, makeToken: makeToken))
    }

    static func installationToken(store: any DobbyInstallationTokenStoring = DobbyInstallationKeychain(),
                                  makeToken: @Sendable () throws -> String = makeInstallationToken) throws -> String {
        if let existing = try store.load() {
            guard isValidInstallationToken(existing) else { throw DobbyInstallationAuthError.invalidStoredToken }
            return existing
        }
        let generated = try makeToken()
        guard isValidInstallationToken(generated) else { throw DobbyInstallationAuthError.generationFailed }
        if try store.addIfAbsent(generated) { return generated }
        // Another first-use request won the insert. Reuse its owner instead of
        // overwriting it or returning an unpersisted token to either service.
        guard let winner = try store.load() else { throw DobbyInstallationAuthError.storageUnavailable }
        guard isValidInstallationToken(winner) else { throw DobbyInstallationAuthError.invalidStoredToken }
        return winner
    }

    static func makeInstallationToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DobbyInstallationAuthError.generationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated protocol DobbyInstallationTokenStoring: Sendable {
    func load() throws -> String?
    /// True if this token was inserted; false if another request already stored an owner.
    func addIfAbsent(_ token: String) throws -> Bool
}

nonisolated struct DobbyInstallationKeychain: DobbyInstallationTokenStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.dobby.instagram",
         kSecAttrAccount as String: "installation-token"]
    }

    func load() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw DobbyInstallationAuthError.storageUnavailable
        }
        return token
    }

    func addIfAbsent(_ token: String) throws -> Bool {
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw DobbyInstallationAuthError.storageUnavailable }
        return true
    }
}
