#if DEBUG
import Foundation
import XCTest
@testable import Dobby

@MainActor
final class ProductAutofillDevelopmentAuthTests: XCTestCase {
    func testLaunchBootstrapPersistsAndVerifiesCredentialBeforeAnyGenerationRequest() {
        let store = DevelopmentAuthMemoryStore()
        let date = Date(timeIntervalSince1970: 42)
        let status = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: "startup-unit-test-token",
                                                             store: store, checkedAt: date)
        XCTAssertTrue(status.readiness)
        XCTAssertTrue(status.runtimePresent)
        XCTAssertTrue(status.storedCredentialPresent)
        XCTAssertTrue(status.bootstrapSucceeded)
        XCTAssertEqual(status.checkedAt, date)
        XCTAssertNil(status.errorCode)
        XCTAssertEqual(store.token, "startup-unit-test-token")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.loadCount, 1, "Startup must verify that persistence really succeeded")
    }

    func testStartupImportSurvivesRelaunchWithoutRuntimeEnvironment() {
        let store = DevelopmentAuthMemoryStore()
        _ = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: "startup-unit-test-token", store: store)
        let relaunched = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: nil, store: store)
        XCTAssertTrue(relaunched.readiness)
        XCTAssertFalse(relaunched.runtimePresent)
        XCTAssertTrue(relaunched.storedCredentialPresent)
        XCTAssertTrue(relaunched.bootstrapSucceeded)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testStartupMissingCredentialAndStorageFailureReturnSafeStatusWithoutThrowing() {
        let missing = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: nil, store: DevelopmentAuthMemoryStore())
        XCTAssertFalse(missing.readiness)
        XCTAssertFalse(missing.runtimePresent)
        XCTAssertFalse(missing.storedCredentialPresent)
        XCTAssertFalse(missing.bootstrapSucceeded)
        XCTAssertEqual(missing.errorCode, "missing_credential")
        let failed = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: "startup-unit-test-token",
            store: DevelopmentAuthMemoryStore(failsWriting: true))
        XCTAssertFalse(failed.readiness)
        XCTAssertTrue(failed.runtimePresent)
        XCTAssertFalse(failed.bootstrapSucceeded)
        XCTAssertEqual(failed.errorCode, "storage_unavailable")
    }

    func testStartupRejectsAWriteThatCannotBeReadBack() {
        let status = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: "startup-unit-test-token",
            store: DevelopmentAuthMemoryStore(ignoresWriting: true))
        XCTAssertFalse(status.readiness)
        XCTAssertFalse(status.storedCredentialPresent)
        XCTAssertFalse(status.bootstrapSucceeded)
        XCTAssertEqual(status.errorCode, "credential_verification_failed")
    }

    func testStartupDiagnosticsNeverSerializeTheCredential() throws {
        let credential = "startup-diagnostic-unit-test-token"
        let status = ProductAutofillDevelopmentAuth.bootstrap(environmentValue: credential,
            store: DevelopmentAuthMemoryStore())
        let data = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["readiness", "runtimePresent", "storedCredentialPresent", "bootstrapSucceeded", "checkedAt"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(credential))
    }

    func testLaunchBootstrapSkipsFixturesAndXCTestHosts() {
        XCTAssertFalse(ProductAutofillDevelopmentAuth.shouldBootstrapAtLaunch(arguments: ["Dobby", "--flow-preview"], environment: [:]))
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"] {
            XCTAssertFalse(ProductAutofillDevelopmentAuth.shouldBootstrapAtLaunch(arguments: ["Dobby"], environment: [key: "test-fixture"]))
        }
        XCTAssertTrue(ProductAutofillDevelopmentAuth.shouldBootstrapAtLaunch(arguments: ["Dobby"], environment: [:]))
    }

    func testRuntimeCredentialIsPersistedWithoutReadingAnOlderValue() throws {
        let store = DevelopmentAuthMemoryStore(token: "previous-unit-test-token")
        let result = try ProductAutofillDevelopmentAuth.resolve(environmentValue: "runtime-unit-test-token", store: store)
        XCTAssertEqual(result, "runtime-unit-test-token")
        XCTAssertEqual(store.token, "runtime-unit-test-token")
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testLaterLaunchWithoutEnvironmentUsesPersistedCredential() throws {
        let store = DevelopmentAuthMemoryStore()
        _ = try ProductAutofillDevelopmentAuth.resolve(environmentValue: "runtime-unit-test-token", store: store)
        let laterLaunch = try ProductAutofillDevelopmentAuth.resolve(environmentValue: nil, store: store)
        XCTAssertEqual(laterLaunch, "runtime-unit-test-token")
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(store.saveCount, 1, "A later launch must not require another credential import")
    }

    func testNoEnvironmentAndNoStoredCredentialReturnsNil() throws {
        let store = DevelopmentAuthMemoryStore()
        XCTAssertNil(try ProductAutofillDevelopmentAuth.resolve(environmentValue: nil, store: store))
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testInvalidRuntimeValueNeverFallsBackToAnOlderCredentialOrRewritesIt() {
        for invalid in ["", "has space", "newline\n", "\rheader", "tab\tvalue", String(repeating: "x", count: 1025)] {
            let store = DevelopmentAuthMemoryStore(token: "previous-unit-test-token")
            XCTAssertThrowsError(try ProductAutofillDevelopmentAuth.resolve(environmentValue: invalid, store: store)) {
                XCTAssertEqual($0 as? ProductAutofillError, .notConfigured)
            }
            XCTAssertEqual(store.token, "previous-unit-test-token")
            XCTAssertEqual(store.loadCount, 0)
            XCTAssertEqual(store.saveCount, 0)
        }
    }

    func testInvalidStoredCredentialIsNotReturnedForAnHTTPHeader() {
        let store = DevelopmentAuthMemoryStore(token: "invalid\nheader")
        XCTAssertThrowsError(try ProductAutofillDevelopmentAuth.resolve(environmentValue: nil, store: store)) {
            XCTAssertEqual($0 as? ProductAutofillError, .notConfigured)
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testReadAndWriteFailuresDoNotPretendAuthenticationIsReady() {
        let readFailure = DevelopmentAuthMemoryStore(failsReading: true)
        XCTAssertThrowsError(try ProductAutofillDevelopmentAuth.resolve(environmentValue: nil, store: readFailure))
        let writeFailure = DevelopmentAuthMemoryStore(failsWriting: true)
        XCTAssertThrowsError(try ProductAutofillDevelopmentAuth.resolve(environmentValue: "unit-test-token", store: writeFailure))
        XCTAssertNil(writeFailure.token)
    }
}

/// Synthetic values only; these tests never read or change a developer's real Keychain or environment.
private nonisolated final class DevelopmentAuthMemoryStore: ProductAutofillDevelopmentTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?
    private var loads = 0
    private var saves = 0
    private let failsReading: Bool
    private let failsWriting: Bool
    private let ignoresWriting: Bool
    var token: String? { lock.withLock { storedToken } }
    var loadCount: Int { lock.withLock { loads } }
    var saveCount: Int { lock.withLock { saves } }

    init(token: String? = nil, failsReading: Bool = false, failsWriting: Bool = false, ignoresWriting: Bool = false) {
        storedToken = token
        self.failsReading = failsReading
        self.failsWriting = failsWriting
        self.ignoresWriting = ignoresWriting
    }
    func load() throws -> String? {
        try lock.withLock {
            loads += 1
            if failsReading { throw MemoryError.unavailable }
            return storedToken
        }
    }
    func save(_ token: String) throws {
        try lock.withLock {
            saves += 1
            if failsWriting { throw MemoryError.unavailable }
            if ignoresWriting { return }
            storedToken = token
        }
    }
    private enum MemoryError: Error { case unavailable }
}
#endif
