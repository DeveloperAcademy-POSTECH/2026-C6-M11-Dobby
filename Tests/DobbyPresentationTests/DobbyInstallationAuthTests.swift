import Foundation
import XCTest
@testable import Dobby

@MainActor
final class DobbyInstallationAuthTests: XCTestCase {
    func testExistingInstagramInstallationOwnerIsReusedWithoutGeneratingOrReplacingIt() throws {
        let existing = String(repeating: "01ab", count: 16)
        let store = InstallationAuthMemoryStore(token: existing)
        let authorization = try XCTUnwrap(DobbyInstallationAuth.authorization(
            appAPIKey: "unit-test-common-app-key", store: store,
            makeToken: { throw InstallationAuthTestError.generationMustNotRun }))
        XCTAssertEqual(authorization.appAPIKey, "unit-test-common-app-key")
        XCTAssertEqual(authorization.installationToken, existing)
        XCTAssertEqual(store.token, existing)
        XCTAssertEqual(store.addCount, 0, "Existing Instagram ownership must survive the shared auth migration")
    }

    func testMissingUnresolvedOrInvalidAppConfigurationNeverReadsOrCreatesAnOwner() throws {
        let invalidKeys: [String?] = [nil, "", " ", "$(DOBBY_APP_API_KEY)", "YOUR_APP_API_KEY",
            "YOUR-DOBBY-APP-KEY", "invalid\nheader", "invalid\rheader", "invalid\tkey",
            "contains space", "비ASCII키", String(repeating: "k", count: 1025)]
        for key in invalidKeys {
            let store = InstallationAuthMemoryStore(token: String(repeating: "ab", count: 32))
            XCTAssertNil(try DobbyInstallationAuth.authorization(appAPIKey: key, store: store,
                makeToken: { throw InstallationAuthTestError.generationMustNotRun }))
            XCTAssertEqual(store.loadCount, 0)
            XCTAssertEqual(store.addCount, 0)
        }
    }

    func testFirstUseAutomaticallyCreatesOne64HexOwnerAndSubsequentUseReusesIt() throws {
        // The real random generator runs, but all persistence stays in this test-owned memory store.
        let store = InstallationAuthMemoryStore()
        let first = try XCTUnwrap(DobbyInstallationAuth.authorization(
            appAPIKey: "unit-test-common-app-key", store: store))
        XCTAssertEqual(first.installationToken.utf8.count, 64)
        XCTAssertTrue(first.installationToken.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        })
        XCTAssertEqual(store.token, first.installationToken)
        XCTAssertEqual(store.addCount, 1)
        let second = try XCTUnwrap(DobbyInstallationAuth.authorization(
            appAPIKey: "unit-test-common-app-key", store: store,
            makeToken: { throw InstallationAuthTestError.generationMustNotRun }))
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.addCount, 1, "Reopening either integration must keep the original owner")
    }

    func testMalformedStoredOwnersFailWithoutOverwritingExistingInstagramOwnership() {
        for owner in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                      String(repeating: "A", count: 64), String(repeating: "g", count: 64), "bad\nheader"] {
            let store = InstallationAuthMemoryStore(token: owner)
            XCTAssertThrowsError(try DobbyInstallationAuth.installationToken(store: store,
                makeToken: { throw InstallationAuthTestError.generationMustNotRun })) { error in
                XCTAssertEqual(error as? DobbyInstallationAuthError, .invalidStoredToken)
            }
            XCTAssertEqual(store.token, owner)
            XCTAssertEqual(store.addCount, 0)
        }
    }

    func testMalformedGeneratedOwnerCannotBePersistedOrReturned() {
        for owner in ["", "not-a-64-hex-owner", String(repeating: "F", count: 64), "bad\rheader"] {
            let store = InstallationAuthMemoryStore()
            XCTAssertThrowsError(try DobbyInstallationAuth.installationToken(store: store,
                makeToken: { owner })) { error in
                XCTAssertEqual(error as? DobbyInstallationAuthError, .generationFailed)
            }
            XCTAssertNil(store.token)
            XCTAssertEqual(store.addCount, 0)
        }
    }

    func testConcurrentFirstUseReusesTheWinningPersistedOwnerInsteadOfItsLosingCandidate() throws {
        let winningOwner = String(repeating: "ab", count: 32)
        let losingCandidate = String(repeating: "cd", count: 32)
        let store = InstallationAuthMemoryStore(forceDuplicate: true, winningToken: winningOwner)
        let resolved = try DobbyInstallationAuth.installationToken(store: store, makeToken: { losingCandidate })
        XCTAssertEqual(resolved, winningOwner)
        XCTAssertEqual(store.token, winningOwner)
        XCTAssertNotEqual(resolved, losingCandidate)
        XCTAssertEqual(store.addCount, 1, "A duplicate must not trigger a destructive update")
    }

    func testDuplicateInsertWithoutAValidPersistedWinnerCannotReturnTheLosingCandidate() {
        for winner: String? in [nil, "bad-existing-owner"] {
            let store = InstallationAuthMemoryStore(forceDuplicate: true, winningToken: winner)
            XCTAssertThrowsError(try DobbyInstallationAuth.installationToken(store: store,
                makeToken: { String(repeating: "cd", count: 32) }))
            XCTAssertEqual(store.token, winner)
            XCTAssertEqual(store.addCount, 1)
        }
    }

    func testStorageFailuresDoNotPretendCommonAuthorizationIsReady() {
        let unreadable = InstallationAuthMemoryStore(failsReading: true)
        XCTAssertThrowsError(try DobbyInstallationAuth.authorization(
            appAPIKey: "unit-test-common-app-key", store: unreadable))
        XCTAssertEqual(unreadable.addCount, 0)
        let unwritable = InstallationAuthMemoryStore(failsAdding: true)
        XCTAssertThrowsError(try DobbyInstallationAuth.authorization(
            appAPIKey: "unit-test-common-app-key", store: unwritable,
            makeToken: { String(repeating: "ab", count: 32) }))
        XCTAssertNil(unwritable.token)
    }

    func testAppKeyUsesTheExistingInstagramConfigurationEntryAndRejectsUnresolvedValues() throws {
        for key: String? in [nil, "$(DOBBY_APP_API_KEY)", "YOUR_APP_API_KEY", "unit-test-common-app-key"] {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + ".bundle", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var info: [String: Any] = ["CFBundleIdentifier": "com.dobby.auth-test." + UUID().uuidString,
                                     "CFBundlePackageType": "BNDL"]
            info["InstagramAppAPIKey"] = key
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: directory.appending(path: "Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: directory))
            XCTAssertEqual(DobbyInstallationAuth.appAPIKey(in: bundle),
                key == "unit-test-common-app-key" ? key : nil)
        }
    }
}

/// No real Keychain, app configuration, credentials, or connected account is accessed by these tests.
private nonisolated final class InstallationAuthMemoryStore: DobbyInstallationTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?
    private var loads = 0
    private var adds = 0
    private let failsReading: Bool
    private let failsAdding: Bool
    private let forceDuplicate: Bool
    private let winningToken: String?

    var token: String? { lock.withLock { storedToken } }
    var loadCount: Int { lock.withLock { loads } }
    var addCount: Int { lock.withLock { adds } }

    init(token: String? = nil, failsReading: Bool = false, failsAdding: Bool = false,
         forceDuplicate: Bool = false, winningToken: String? = nil) {
        storedToken = token
        self.failsReading = failsReading
        self.failsAdding = failsAdding
        self.forceDuplicate = forceDuplicate
        self.winningToken = winningToken
    }

    func load() throws -> String? {
        try lock.withLock {
            loads += 1
            if failsReading { throw InstallationAuthTestError.storageUnavailable }
            return storedToken
        }
    }

    func addIfAbsent(_ token: String) throws -> Bool {
        try lock.withLock {
            adds += 1
            if failsAdding { throw InstallationAuthTestError.storageUnavailable }
            if forceDuplicate {
                storedToken = winningToken
                return false
            }
            guard storedToken == nil else { return false }
            storedToken = token
            return true
        }
    }
}

private nonisolated enum InstallationAuthTestError: Error {
    case generationMustNotRun, storageUnavailable
}
