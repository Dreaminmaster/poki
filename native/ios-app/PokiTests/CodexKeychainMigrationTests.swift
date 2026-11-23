import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import Poki

@MainActor
final class CodexKeychainMigrationTests: XCTestCase {
    private var createdServices: [String] = []
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for service in createdServices {
            deleteAllItems(in: service)
        }
        createdServices.removeAll()
        for dir in createdDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirectories.removeAll()
        super.tearDown()
    }

    func testPrepareStorageMigratesLegacyContainerCredentialAndRemovesOldKey() throws {
        let service = makeTestService()
        let root = try makeTempDirectory()
        let realTarget = root.appendingPathComponent("real-container", isDirectory: true)
        try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
        let symlinkParent = root.appendingPathComponent("symlink-container", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: realTarget)

        // New home does not exist yet and goes through a symlink, mirroring /var -> /private/var before directory creation.
        let newHome = symlinkParent.appendingPathComponent("CodexVoice", isDirectory: true)
        let oldHome = root.appendingPathComponent("old-container/CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)

        let oldAccount = try expectedAccountKey(for: oldHome)
        let secretAccess = "tok-migration-secret-\(UUID().uuidString)"
        let secretRefresh = "ref-migration-secret-\(UUID().uuidString)"
        let rawCredential = try makeCredentialData(
            accessToken: secretAccess,
            refreshToken: secretRefresh,
            lastRefresh: "2026-11-20T08:30:00Z"
        )
        let unrelatedData = Data("keep-me".utf8)

        try addRawKeychainItem(
            service: service,
            account: oldAccount,
            data: rawCredential,
            accessible: kSecAttrAccessibleWhenUnlocked
        )
        try addRawKeychainItem(
            service: service,
            account: "other|keep",
            data: unrelatedData,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )

        let logCountBefore = AppLog.shared.lines.count
        CodexAccount.prepareStorage(service: service, home: newHome)

        XCTAssertTrue(FileManager.default.fileExists(atPath: newHome.path(percentEncoded: false)))
        let newAccount = try expectedAccountKey(for: newHome)
        XCTAssertNotEqual(oldAccount, newAccount)

        let migrated = try XCTUnwrap(Keychain.readWithAttributes(newAccount, service: service))
        XCTAssertEqual(migrated.data, rawCredential)
        XCTAssertNotNil(migrated.modified)
        XCTAssertEqual(migrated.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(try Keychain.read(oldAccount, service: service))
        XCTAssertEqual(try Keychain.read("other|keep", service: service), unrelatedData)
        XCTAssertEqual(CodexAccount.readAccessToken(service: service, home: newHome), secretAccess)

        let addedLogs = AppLog.shared.lines.dropFirst(logCountBefore)
        XCTAssertFalse(addedLogs.isEmpty, "Migration must record a voice log entry")
        for line in addedLogs {
            XCTAssertFalse(line.contains(secretAccess), "AppLog must never include access_token")
            XCTAssertFalse(line.contains(secretRefresh), "AppLog must never include refresh_token")
        }

        // Running prepareStorage again must be idempotent.
        CodexAccount.prepareStorage(service: service, home: newHome)
        let afterRepeat = try XCTUnwrap(Keychain.readWithAttributes(newAccount, service: service))
        XCTAssertEqual(afterRepeat.data, rawCredential)
        XCTAssertEqual(afterRepeat.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testPrepareStorageSelectsNewestCredentialByLastRefreshThenJWTExpiry() throws {
        // 1) last_refresh (fractional vs non-fractional ISO-8601) takes precedence over JWT exp,
        // and replaces a corrupt current-container item.
        let serviceA = makeTestService()
        let homeA = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        let currentA = try expectedAccountKey(for: homeA)

        try addRawKeychainItem(
            service: serviceA,
            account: currentA,
            data: Data("{corrupt-json".utf8),
            accessible: kSecAttrAccessibleWhenUnlocked
        )

        let olderRefreshHigherExp = try makeCredentialData(
            accessToken: makeJWT(exp: 4_000_000_000, subject: "older-refresh"),
            lastRefresh: "2026-11-20T10:00:00Z"
        )
        let newerFractionalRefresh = try makeCredentialData(
            accessToken: makeJWT(exp: 2_000_000_000, subject: "newer-fractional"),
            lastRefresh: "2026-11-20T10:00:00.500Z"
        )
        let nonChatGPT = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "api_key",
            "last_refresh": "2026-12-31T23:59:59Z",
            "tokens": ["access_token": makeJWT(exp: 9_000_000_000, subject: "ignored")]
        ])

        try addRawKeychainItem(service: serviceA, account: "cli|1111111111111111", data: olderRefreshHigherExp, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceA, account: "cli|2222222222222222", data: newerFractionalRefresh, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceA, account: "cli|3333333333333333", data: nonChatGPT, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: serviceA, home: homeA)

        let pickedA = try XCTUnwrap(Keychain.readWithAttributes(currentA, service: serviceA))
        XCTAssertEqual(pickedA.data, newerFractionalRefresh)
        XCTAssertEqual(pickedA.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(try Keychain.read("cli|1111111111111111", service: serviceA))
        XCTAssertNil(try Keychain.read("cli|2222222222222222", service: serviceA))

        // 2) Equal last_refresh breaks ties by JWT exp.
        let serviceB = makeTestService()
        let homeB = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        let currentB = try expectedAccountKey(for: homeB)

        let lowerExp = try makeCredentialData(
            accessToken: makeJWT(exp: 1_800_000_000, subject: "lower-exp"),
            lastRefresh: "2026-11-20T10:00:00Z"
        )
        let higherExp = try makeCredentialData(
            accessToken: makeJWT(exp: 1_900_000_000, subject: "higher-exp"),
            lastRefresh: "2026-11-20T10:00:00Z"
        )
        try addRawKeychainItem(service: serviceB, account: "cli|aaaaaaaaaaaaaaaa", data: lowerExp, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceB, account: "cli|bbbbbbbbbbbbbbbb", data: higherExp, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: serviceB, home: homeB)

        let pickedB = try XCTUnwrap(Keychain.readWithAttributes(currentB, service: serviceB))
        XCTAssertEqual(pickedB.data, higherExp)
        XCTAssertNil(try Keychain.read("cli|aaaaaaaaaaaaaaaa", service: serviceB))
        XCTAssertNil(try Keychain.read("cli|bbbbbbbbbbbbbbbb", service: serviceB))

        // 3) Missing last_refresh and non-JWT tokens break ties by Keychain modification date.
        let olderModified = try makeCredentialData(accessToken: "opaque-older", lastRefresh: nil)
        let newerModified = try makeCredentialData(accessToken: "opaque-newer", lastRefresh: nil)
        let selected = CodexAccount.selectNewestCredential(
            from: [
                (account: "cli|cccccccccccccccc", data: olderModified, modified: Date(timeIntervalSince1970: 1_700_000_100), accessible: nil),
                (account: "cli|dddddddddddddddd", data: newerModified, modified: Date(timeIntervalSince1970: 1_700_000_200), accessible: nil),
                (account: "other|eeeeeeeeeeee", data: newerModified, modified: Date(timeIntervalSince1970: 1_700_000_999), accessible: nil),
            ],
            excluding: "cli|ffffffffffffffff"
        )
        XCTAssertEqual(selected?.account, "cli|dddddddddddddddd")
        XCTAssertEqual(selected?.data, newerModified)
    }

    func testEnsureAfterFirstUnlockAndPrepareStorageUpgradeWhenUnlockedItem() throws {
        // 1) ensureAfterFirstUnlock upgrades a freshly written WhenUnlocked item.
        let service1 = makeTestService()
        let home1 = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home1, withIntermediateDirectories: true)
        let account1 = try expectedAccountKey(for: home1)
        let data1 = try makeCredentialData(accessToken: "tok-upgrade-ensure", lastRefresh: "2026-11-20T12:00:00Z")

        try addRawKeychainItem(service: service1, account: account1, data: data1, accessible: kSecAttrAccessibleWhenUnlocked)
        let before1 = try XCTUnwrap(Keychain.readWithAttributes(account1, service: service1))
        XCTAssertEqual(before1.accessible, kSecAttrAccessibleWhenUnlocked as String)

        CodexAccount.ensureAfterFirstUnlock(service: service1, home: home1)

        let after1 = try XCTUnwrap(Keychain.readWithAttributes(account1, service: service1))
        XCTAssertEqual(after1.data, data1)
        XCTAssertEqual(after1.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        // 2) prepareStorage also upgrades an existing valid current-container WhenUnlocked item in place.
        let service2 = makeTestService()
        let home2 = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home2, withIntermediateDirectories: true)
        let account2 = try expectedAccountKey(for: home2)
        let data2 = try makeCredentialData(accessToken: "tok-upgrade-prepare", lastRefresh: "2026-11-20T12:05:00Z")

        try addRawKeychainItem(service: service2, account: account2, data: data2, accessible: kSecAttrAccessibleWhenUnlocked)
        CodexAccount.prepareStorage(service: service2, home: home2)

        let after2 = try XCTUnwrap(Keychain.readWithAttributes(account2, service: service2))
        XCTAssertEqual(after2.data, data2)
        XCTAssertEqual(after2.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testClearStoredCredentialsRemovesCurrentAndLegacyItemsAndPreventsRevival() throws {
        let service = makeTestService()
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let currentAccount = try expectedAccountKey(for: home)

        let currentData = try makeCredentialData(accessToken: "tok-current", lastRefresh: "2026-11-20T14:00:00Z")
        let legacyData1 = try makeCredentialData(accessToken: "tok-legacy-1", lastRefresh: "2026-11-19T14:00:00Z")
        let legacyData2 = try makeCredentialData(accessToken: "tok-legacy-2", lastRefresh: "2026-11-18T14:00:00Z")
        let unrelatedData = Data("non-cli-entry".utf8)

        try addRawKeychainItem(service: service, account: currentAccount, data: currentData, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try addRawKeychainItem(service: service, account: "cli|deadbeef00000001", data: legacyData1, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|deadbeef00000002", data: legacyData2, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "other|keep", data: unrelatedData, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        try CodexAccount.clearStoredCredentials(service: service)

        XCTAssertNil(try Keychain.read(currentAccount, service: service))
        XCTAssertNil(try Keychain.read("cli|deadbeef00000001", service: service))
        XCTAssertNil(try Keychain.read("cli|deadbeef00000002", service: service))
        XCTAssertEqual(try Keychain.read("other|keep", service: service), unrelatedData)

        // Subsequent prepareStorage and readAccessToken must not revive any signed-out credentials.
        CodexAccount.prepareStorage(service: service, home: home)
        XCTAssertNil(CodexAccount.readAccessToken(service: service, home: home))
        let remainingCLI = try Keychain.readAll(service: service).filter { $0.account.hasPrefix("cli|") }
        XCTAssertTrue(remainingCLI.isEmpty)
    }

    // MARK: - Helpers

    private func makeTestService() -> String {
        let service = "Codex Auth Test.\(UUID().uuidString)"
        createdServices.append(service)
        return service
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-keychain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirectories.append(dir)
        return dir
    }

    private func expectedAccountKey(for home: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(home.path(percentEncoded: false), nil))
        defer { free(resolved) }
        let path = String(cString: resolved)
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "cli|\(hash)"
    }

    private func makeCredentialData(
        accessToken: String,
        refreshToken: String = "ref-fixture",
        lastRefresh: String?
    ) throws -> Data {
        var json: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken
            ]
        ]
        if let lastRefresh {
            json["last_refresh"] = lastRefresh
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeJWT(exp: Int, subject: String) throws -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let payload = try JSONSerialization.data(withJSONObject: ["exp": exp, "sub": subject])
        return "\(base64URL(header)).\(base64URL(payload)).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func addRawKeychainItem(
        service: String,
        account: String,
        data: Data,
        accessible: CFString
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "SecItemAdd failed with OSStatus \(status)")
    }

    private func deleteAllItems(in service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
