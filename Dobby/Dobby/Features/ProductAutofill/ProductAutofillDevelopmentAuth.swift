#if DEBUG
import Foundation
import Security

/// Development credentials arrive at runtime, then survive ordinary app relaunches in this device's Keychain.
/// Neither the shared Worker credential nor the OpenAI key belongs in the app bundle.
nonisolated enum ProductAutofillDevelopmentAuth {
    /// Import the Xcode-only runtime credential before a user can disconnect or relaunch the app.
    /// Diagnostics contain readiness flags only; never serialize the credential or environment.
    static func bootstrapAtLaunch() {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        guard shouldBootstrapAtLaunch(arguments: process.arguments, environment: environment),
              NSClassFromString("XCTestCase") == nil else { return }
        let status = bootstrap(environmentValue: environment["DOBBY_AI_AUTH_TOKEN"],
                               store: ProductAutofillDevelopmentKeychain())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) {
            let destination = URL.documentsDirectory.appending(path: "dobby-ai-auth-status.json")
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                // A debug diagnostics failure must never block opening the user's product library.
            }
        }
        print("[Dobby AI auth] readiness=\(status.readiness) runtimePresent=\(status.runtimePresent) storedCredentialPresent=\(status.storedCredentialPresent) bootstrapSucceeded=\(status.bootstrapSucceeded) errorCode=\(status.errorCode ?? "none")")
    }

    static func shouldBootstrapAtLaunch(arguments: [String], environment: [String: String]) -> Bool {
        !arguments.contains("--flow-preview") && ![
            "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"
        ].contains(where: { environment[$0] != nil })
    }

    /// Only the returned flags may leave the credential provider. This operation never throws into App.init.
    static func bootstrap(environmentValue: String?, store: any ProductAutofillDevelopmentTokenStoring,
                          checkedAt: Date = .now) -> ProductAutofillDevelopmentAuthStatus {
        var storedCredentialPresent = false
        func status(ready: Bool, errorCode: String? = nil) -> ProductAutofillDevelopmentAuthStatus {
            .init(readiness: ready, runtimePresent: environmentValue != nil,
                  storedCredentialPresent: storedCredentialPresent, bootstrapSucceeded: ready,
                  checkedAt: checkedAt, errorCode: errorCode)
        }
        do {
            guard let credential = try resolve(environmentValue: environmentValue, store: store) else {
                return status(ready: false, errorCode: "missing_credential")
            }
            if environmentValue != nil {
                let saved = try store.load()
                storedCredentialPresent = saved != nil
                guard saved == credential else {
                    return status(ready: false, errorCode: "credential_verification_failed")
                }
            } else {
                storedCredentialPresent = true
            }
            return status(ready: true)
        } catch is ProductAutofillError {
            return status(ready: false, errorCode: "invalid_credential")
        } catch {
            return status(ready: false, errorCode: "storage_unavailable")
        }
    }

    static func token() throws -> String? {
        try resolve(environmentValue: ProcessInfo.processInfo.environment["DOBBY_AI_AUTH_TOKEN"],
                    store: ProductAutofillDevelopmentKeychain())
    }

    static func resolve(environmentValue: String?, store: any ProductAutofillDevelopmentTokenStoring) throws -> String? {
        if let environmentValue {
            try validate(environmentValue)
            try store.save(environmentValue)
            return environmentValue
        }
        guard let stored = try store.load() else { return nil }
        try validate(stored)
        return stored
    }

    private static func validate(_ token: String) throws {
        guard !token.isEmpty, token.count <= 1024, !token.contains(where: \.isWhitespace) else {
            throw ProductAutofillError.notConfigured
        }
    }
}

/// Safe to inspect through developer tooling. No credential, credential fragment or raw error is stored.
nonisolated struct ProductAutofillDevelopmentAuthStatus: Codable, Equatable, Sendable {
    let readiness: Bool
    let runtimePresent: Bool
    let storedCredentialPresent: Bool
    let bootstrapSucceeded: Bool
    let checkedAt: Date
    let errorCode: String?
}

nonisolated protocol ProductAutofillDevelopmentTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
}

nonisolated struct ProductAutofillDevelopmentKeychain: ProductAutofillDevelopmentTokenStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.dobby.ai.development",
         kSecAttrAccount as String: "draft-api-token",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { throw StorageError.unavailable }
        return token
    }

    func save(_ token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageError.unavailable }
        let add = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        // Concurrent first use must not turn a successfully stored credential into a failure.
        if added == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw StorageError.unavailable
            }
        } else if added != errSecSuccess {
            throw StorageError.unavailable
        }
    }

    private enum StorageError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "AI 연결 정보를 안전하게 읽거나 저장하지 못했어요. 기기 잠금을 해제한 후 다시 시도해 주세요."
        }
    }
}
#endif
