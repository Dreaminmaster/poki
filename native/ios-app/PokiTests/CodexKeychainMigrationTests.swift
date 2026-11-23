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

    override func tearDownWithError() throws {
        var firstError: Error?
        for service in createdServices {
            do {
                try deleteAllItems(in: service)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        createdServices.removeAll()
        for dir in createdDirectories {
            do {
                if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: dir)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        createdDirectories.removeAll()
        try super.tearDownWithError()
        if let firstError {
            throw firstError
        }
    }

    func testPrepareStorageMigratesLegacyContainerCredentialAndRemovesOldKey() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
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
        let secretID = try makeJWT(exp: 4_100_000_000, subject: "id-migration-secret")
        let rawCredential = try makeCredentialData(
            accessToken: secretAccess,
            refreshToken: secretRefresh,
            idToken: secretID,
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

        let logMarker = UUID().uuidString
        AppLog.shared.add("test", logMarker)
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

        let addedLogs = Array(AppLog.shared.lines.drop(while: { !$0.hasSuffix(logMarker) }).dropFirst())
        XCTAssertFalse(addedLogs.isEmpty, "Migration must record a voice log entry")
        for line in addedLogs {
            XCTAssertFalse(line.contains(secretAccess), "AppLog must never include access_token")
            XCTAssertFalse(line.contains(secretRefresh), "AppLog must never include refresh_token")
            XCTAssertFalse(line.contains(secretID), "AppLog must never include id_token")
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
        defer { assertServiceCleanedUp(serviceA) }
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
            "tokens": [
                "access_token": makeJWT(exp: 9_000_000_000, subject: "ignored"),
                "refresh_token": "ref-ignored",
                "id_token": makeJWT(exp: 9_000_000_000, subject: "id-ignored")
            ]
        ])

        try addRawKeychainItem(service: serviceA, account: "cli|1111111111111111", data: olderRefreshHigherExp, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceA, account: "cli|2222222222222222", data: newerFractionalRefresh, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceA, account: "cli|3333333333333333", data: nonChatGPT, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: serviceA, home: homeA)

        let pickedA = try XCTUnwrap(Keychain.readWithAttributes(currentA, service: serviceA))
        XCTAssertEqual(pickedA.data, newerFractionalRefresh)
        XCTAssertEqual(pickedA.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(
            try Keychain.read("cli|1111111111111111", service: serviceA),
            olderRefreshHigherExp,
            "Unselected legacy cli|* records must remain untouched after migration"
        )
        XCTAssertNil(try Keychain.read("cli|2222222222222222", service: serviceA))
        XCTAssertEqual(try Keychain.read("cli|3333333333333333", service: serviceA), nonChatGPT)

        // 2) Equal last_refresh breaks ties by JWT exp.
        let serviceB = makeTestService()
        defer { assertServiceCleanedUp(serviceB) }
        let homeB = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        let currentB = try expectedAccountKey(for: homeB)

        let lowerExp = try makeCredentialData(
            accessToken: makeJWT(exp: 3_800_000_000, subject: "lower-exp"),
            lastRefresh: "2026-11-20T10:00:00Z"
        )
        let higherExp = try makeCredentialData(
            accessToken: makeJWT(exp: 3_900_000_000, subject: "higher-exp"),
            lastRefresh: "2026-11-20T10:00:00Z"
        )
        try addRawKeychainItem(service: serviceB, account: "cli|aaaaaaaaaaaaaaaa", data: lowerExp, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: serviceB, account: "cli|bbbbbbbbbbbbbbbb", data: higherExp, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: serviceB, home: homeB)

        let pickedB = try XCTUnwrap(Keychain.readWithAttributes(currentB, service: serviceB))
        XCTAssertEqual(pickedB.data, higherExp)
        XCTAssertEqual(
            try Keychain.read("cli|aaaaaaaaaaaaaaaa", service: serviceB),
            lowerExp,
            "Unselected legacy cli|* records must remain untouched after migration"
        )
        XCTAssertNil(try Keychain.read("cli|bbbbbbbbbbbbbbbb", service: serviceB))
    }

    func testPrepareStorageBreaksTiesByRealKeychainModificationDate() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)

        let olderData = try makeCredentialData(accessToken: "opaque-older", lastRefresh: nil)
        let newerData = try makeCredentialData(accessToken: "opaque-newer", lastRefresh: nil)

        try addRawKeychainItem(
            service: service,
            account: "cli|cccccccccccccccc",
            data: olderData,
            accessible: kSecAttrAccessibleWhenUnlocked
        )
        let olderItem = try XCTUnwrap(Keychain.readWithAttributes("cli|cccccccccccccccc", service: service))
        let olderModified = try XCTUnwrap(olderItem.modified)

        // Advance past Keychain's modification timestamp resolution so the second real write has a strictly newer mdate.
        try addRawKeychainItem(
            service: service,
            account: "cli|dddddddddddddddd",
            data: newerData,
            accessible: kSecAttrAccessibleWhenUnlocked
        )
        var newerModified = try XCTUnwrap(Keychain.readWithAttributes("cli|dddddddddddddddd", service: service)?.modified)
        if newerModified <= olderModified {
            Thread.sleep(forTimeInterval: 1.1)
            let status = SecItemUpdate(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "cli|dddddddddddddddd"
                ] as CFDictionary,
                [kSecValueData as String: newerData] as CFDictionary
            )
            XCTAssertEqual(status, errSecSuccess)
            newerModified = try XCTUnwrap(Keychain.readWithAttributes("cli|dddddddddddddddd", service: service)?.modified)
        }
        XCTAssertGreaterThan(newerModified, olderModified)

        CodexAccount.prepareStorage(service: service, home: home)

        let picked = try XCTUnwrap(Keychain.readWithAttributes(current, service: service))
        XCTAssertEqual(picked.data, newerData)
        XCTAssertEqual(
            try Keychain.read("cli|cccccccccccccccc", service: service),
            olderData,
            "Unselected legacy cli|* records must remain untouched after migration"
        )
        XCTAssertNil(try Keychain.read("cli|dddddddddddddddd", service: service))
    }

    func testPrepareStorageRejectsIncompleteNewerRecordAndPreservesValidAndInvalidRecordsSafely() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)

        let validOlder = try makeCredentialData(
            accessToken: makeJWT(exp: 4_000_000_000, subject: "valid-older"),
            refreshToken: "ref-valid-older",
            lastRefresh: "2026-11-20T08:00:00Z"
        )
        let missingRefreshNewer = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-22T12:00:00Z",
            "tokens": [
                "access_token": makeJWT(exp: 4_500_000_000, subject: "no-refresh"),
                "id_token": makeJWT(exp: 4_500_000_000, subject: "id-no-refresh")
            ]
        ])
        let invalidIDTokenNewer = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-23T12:00:00Z",
            "tokens": [
                "access_token": makeJWT(exp: 4_600_000_000, subject: "bad-id"),
                "refresh_token": "ref-bad-id",
                "id_token": "not-a-three-part-jwt"
            ]
        ])
        let nonObjectIDTokenPayload = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-24T12:00:00Z",
            "tokens": [
                "access_token": makeJWT(exp: 4_700_000_000, subject: "array-id"),
                "refresh_token": "ref-array-id",
                "id_token": "\(base64URL(Data("{}".utf8))).\(base64URL(Data("[1,2]".utf8))).sig"
            ]
        ])

        try addRawKeychainItem(service: service, account: "cli|1000000000000001", data: validOlder, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|1000000000000002", data: missingRefreshNewer, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|1000000000000003", data: invalidIDTokenNewer, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|1000000000000004", data: nonObjectIDTokenPayload, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: service, home: home)

        let migrated = try XCTUnwrap(Keychain.readWithAttributes(current, service: service))
        XCTAssertEqual(migrated.data, validOlder, "Incomplete newer entries must be rejected in favor of a complete AuthDotJson")
        XCTAssertNil(try Keychain.read("cli|1000000000000001", service: service), "Migrated valid legacy copy should be removed after verification")
        // Unverified / incomplete legacy records must never be deleted by migration cleanup.
        XCTAssertEqual(try Keychain.read("cli|1000000000000002", service: service), missingRefreshNewer)
        XCTAssertEqual(try Keychain.read("cli|1000000000000003", service: service), invalidIDTokenNewer)
        XCTAssertEqual(try Keychain.read("cli|1000000000000004", service: service), nonObjectIDTokenPayload)
    }

    func testPrepareStorageRejectsMalformedLastRefreshAndInvalidIdClaimsAndRecoversValidLegacy() throws {
        // 1) Legacy entries with malformed last_refresh or invalid Rust IdClaims field types
        // must be rejected without deletion, while a valid older legacy record is recovered.
        let serviceA = makeTestService()
        defer { assertServiceCleanedUp(serviceA) }
        let homeA = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        let currentA = try expectedAccountKey(for: homeA)

        let validOlder = try makeCredentialData(
            accessToken: makeJWT(exp: 4_000_000_000, subject: "valid-older-m1"),
            refreshToken: "ref-valid-older-m1",
            idToken: makeCustomJWT(payload: [
                "sub": "user-valid",
                "email": "valid@example.com",
                "https://api.openai.com/profile": ["email": "profile@example.com"],
                "https://api.openai.com/auth": [
                    "chatgpt_plan_type": "plus",
                    "chatgpt_user_id": "user-1",
                    "chatgpt_account_id": "acct-1",
                    "chatgpt_account_is_fedramp": false
                ]
            ]),
            lastRefresh: "2026-11-20T08:00:00Z"
        )
        let malformedLastRefresh = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-date"),
            lastRefresh: "not-a-valid-rfc3339-date"
        )
        let trailingGarbageLastRefresh = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "trailing-date"),
            lastRefresh: "2026-11-24T10:00:00Z trailing"
        )
        let badEmailClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-email"),
            idToken: makeCustomJWT(payload: ["email": 123]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let badProfileClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-profile"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/profile": ["email": 456]]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let nonObjectAuthClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-auth-obj"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/auth": "not-an-object"]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let badPlanTypeClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-plan-type"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/auth": ["chatgpt_plan_type": 99]]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let badAccountIdClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-account-id"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": 42]]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let badFedrampTypeClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "bad-fedramp-type"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_is_fedramp": "yes"]]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )
        let nullFedrampClaim = try makeCredentialData(
            accessToken: makeJWT(exp: 4_900_000_000, subject: "null-fedramp"),
            idToken: makeCustomJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_is_fedramp": NSNull()]]),
            lastRefresh: "2026-11-24T10:00:00Z"
        )

        let invalidLegacy: [(String, Data)] = [
            ("cli|6000000000000002", malformedLastRefresh),
            ("cli|6000000000000003", trailingGarbageLastRefresh),
            ("cli|6000000000000004", badEmailClaim),
            ("cli|6000000000000005", badProfileClaim),
            ("cli|6000000000000006", nonObjectAuthClaim),
            ("cli|6000000000000007", badPlanTypeClaim),
            ("cli|6000000000000008", badAccountIdClaim),
            ("cli|6000000000000009", badFedrampTypeClaim),
            ("cli|600000000000000a", nullFedrampClaim),
        ]
        try addRawKeychainItem(service: serviceA, account: "cli|6000000000000001", data: validOlder, accessible: kSecAttrAccessibleWhenUnlocked)
        for (account, data) in invalidLegacy {
            try addRawKeychainItem(service: serviceA, account: account, data: data, accessible: kSecAttrAccessibleWhenUnlocked)
        }

        XCTAssertEqual(CodexAccount.prepareStorage(service: serviceA, home: homeA), .migrated)
        XCTAssertEqual(try Keychain.read(currentA, service: serviceA), validOlder)
        XCTAssertNil(try Keychain.read("cli|6000000000000001", service: serviceA))
        for (account, expectedData) in invalidLegacy {
            XCTAssertEqual(
                try Keychain.read(account, service: serviceA),
                expectedData,
                "Invalid legacy entry \(account) must not be selected or deleted"
            )
        }

        // 2) Current key failing strict last_refresh or IdClaims validation must NOT be treated as .ready
        // and must fall back to recovering a valid legacy record.
        for (label, badCurrent) in [
            ("malformed last_refresh", malformedLastRefresh),
            ("invalid IdClaims email", badEmailClaim),
            ("null chatgpt_account_is_fedramp", nullFedrampClaim),
        ] {
            let serviceB = makeTestService()
            defer { assertServiceCleanedUp(serviceB) }
            let homeB = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
            try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
            let currentB = try expectedAccountKey(for: homeB)

            try addRawKeychainItem(service: serviceB, account: currentB, data: badCurrent, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            try addRawKeychainItem(service: serviceB, account: "cli|7000000000000001", data: validOlder, accessible: kSecAttrAccessibleWhenUnlocked)

            XCTAssertEqual(
                CodexAccount.prepareStorage(service: serviceB, home: homeB),
                .migrated,
                "Current key with \(label) must not be accepted as .ready"
            )
            XCTAssertEqual(try Keychain.read(currentB, service: serviceB), validOlder, "Expected legacy recovery for \(label)")
            XCTAssertNil(try Keychain.read("cli|7000000000000001", service: serviceB))
        }

        // 3) Explicit null last_refresh, fractional nanosecond RFC 3339, and unknown PlanType strings remain valid.
        let serviceC = makeTestService()
        defer { assertServiceCleanedUp(serviceC) }
        let homeC = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: homeC, withIntermediateDirectories: true)
        let currentC = try expectedAccountKey(for: homeC)

        let nullLastRefreshData = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": NSNull(),
            "tokens": [
                "access_token": makeJWT(exp: 4_100_000_000, subject: "null-refresh"),
                "refresh_token": "ref-null-refresh",
                "id_token": makeCustomJWT(payload: [
                    "https://api.openai.com/auth": [
                        "chatgpt_plan_type": "future_custom_plan",
                        "user_id": "legacy-user-id"
                    ]
                ])
            ]
        ])
        try addRawKeychainItem(service: serviceC, account: currentC, data: nullLastRefreshData, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(CodexAccount.prepareStorage(service: serviceC, home: homeC), .ready)

        let nanoLastRefreshData = try makeCredentialData(
            accessToken: makeJWT(exp: 4_100_000_000, subject: "nano-refresh"),
            lastRefresh: "2026-11-23T10:00:00.123456789Z"
        )
        try Keychain.write(nanoLastRefreshData, account: currentC, service: serviceC)
        XCTAssertEqual(CodexAccount.prepareStorage(service: serviceC, home: homeC), .ready)
    }

    func testPrepareStorageScansLegacyWhenCurrentKeyIsIncomplete() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)

        let incompleteCurrent = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-23T12:00:00Z",
            "tokens": [
                "access_token": makeJWT(exp: 4_500_000_000, subject: "incomplete-current")
            ]
        ])
        let validLegacy = try makeCredentialData(
            accessToken: makeJWT(exp: 4_100_000_000, subject: "valid-legacy"),
            refreshToken: "ref-valid-legacy",
            lastRefresh: "2026-11-20T09:00:00Z"
        )

        try addRawKeychainItem(service: service, account: current, data: incompleteCurrent, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|2000000000000001", data: validLegacy, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: service, home: home)

        let recovered = try XCTUnwrap(Keychain.readWithAttributes(current, service: service))
        XCTAssertEqual(recovered.data, validLegacy, "An incomplete current key must not block recovery from legacy keys")
        XCTAssertNil(try Keychain.read("cli|2000000000000001", service: service))
    }

    func testPrepareStoragePrefersUnexpiredCredentialOverNewerExpiredCredential() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)

        let now = Int(Date().timeIntervalSince1970)
        let validUnexpired = try makeCredentialData(
            accessToken: makeJWT(exp: now + 3600, subject: "unexpired"),
            lastRefresh: "2026-11-20T08:00:00Z"
        )
        let expiredNewer = try makeCredentialData(
            accessToken: makeJWT(exp: now - 300, subject: "expired-newer"),
            lastRefresh: "2026-11-23T08:00:00Z"
        )

        try addRawKeychainItem(service: service, account: "cli|3000000000000001", data: validUnexpired, accessible: kSecAttrAccessibleWhenUnlocked)
        try addRawKeychainItem(service: service, account: "cli|3000000000000002", data: expiredNewer, accessible: kSecAttrAccessibleWhenUnlocked)

        CodexAccount.prepareStorage(service: service, home: home)

        let picked = try XCTUnwrap(Keychain.readWithAttributes(current, service: service))
        XCTAssertEqual(picked.data, validUnexpired, "An unexpired complete credential must win over an expired newer one")
        XCTAssertNil(try Keychain.read("cli|3000000000000001", service: service))
        XCTAssertEqual(
            try Keychain.read("cli|3000000000000002", service: service),
            expiredNewer,
            "Unselected legacy cli|* records must remain untouched after migration"
        )
    }

    func testEnsureAfterFirstUnlockAndPrepareStorageUpgradeWhenUnlockedItem() throws {
        // 1) ensureAfterFirstUnlock upgrades a freshly written WhenUnlocked item.
        let service1 = makeTestService()
        defer { assertServiceCleanedUp(service1) }
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
        defer { assertServiceCleanedUp(service2) }
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
        defer { assertServiceCleanedUp(service) }
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

    func testVoiceRequireAccountReloadsRuntimeCacheWhenStoredCredentialIsReady() async throws {
        try FileManager.default.createDirectory(at: CodexAccount.home, withIntermediateDirectories: true)
        let account = try expectedAccountKey(for: CodexAccount.home)
        let backup = try Keychain.readWithAttributes(account, service: "Codex Auth")
        defer {
            try? Keychain.remove(account, service: "Codex Auth")
            if let backup {
                try? Keychain.write(backup.data, account: account, service: "Codex Auth")
            }
        }
        try? Keychain.remove(account, service: "Codex Auth")
        let validData = try makeCredentialData(
            accessToken: makeJWT(exp: Int(Date().timeIntervalSince1970) + 3600, subject: "voice-reload"),
            lastRefresh: "2026-11-23T10:00:00Z"
        )
        try addRawKeychainItem(
            service: "Codex Auth",
            account: account,
            data: validData,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )

        var emit: (@MainActor (String) -> Void)?
        var sentMethods: [String] = []
        var reloaded = false
        func push(_ payload: [String: Any]) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in emit?(text) }
        }
        let voice = CodexVoice(
            startBridge: { _, next in
                emit = next
                return true
            },
            sendBridge: { text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let method = object["method"] as? String,
                      let id = object["id"] else { return false }
                sentMethods.append(method)
                switch method {
                case "account/read":
                    if reloaded {
                        push(["id": id, "result": ["account": ["type": "chatgpt"]]])
                    } else {
                        push(["id": id, "result": [:]])
                    }
                case "poki/account/reload":
                    reloaded = true
                    push(["id": id, "result": [:]])
                case "thread/start":
                    push(["id": id, "result": ["thread": ["id": "reloaded-thread"]]])
                default:
                    push(["id": id, "result": [:]])
                }
                return true
            }
        )
        defer { voice.stop() }

        try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
        XCTAssertTrue(reloaded, "CodexVoice must reload the runtime account cache when Keychain has a valid credential")
        XCTAssertTrue(sentMethods.contains("poki/account/reload"), "Expected poki/account/reload, got \(sentMethods)")
    }

    func testKeychainUpdateAccessibilityPreservesValueData() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let account = "cli|acc-upgrade-only"
        let original = try makeCredentialData(accessToken: "tok-original-bytes", lastRefresh: "2026-11-23T09:00:00Z")

        try addRawKeychainItem(
            service: service,
            account: account,
            data: original,
            accessible: kSecAttrAccessibleWhenUnlocked
        )
        let before = try XCTUnwrap(Keychain.readWithAttributes(account, service: service))
        XCTAssertEqual(before.accessible, kSecAttrAccessibleWhenUnlocked as String)

        try Keychain.updateAccessibility(
            account,
            service: service,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )

        let after = try XCTUnwrap(Keychain.readWithAttributes(account, service: service))
        XCTAssertEqual(after.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(after.data, original, "updateAccessibility must preserve kSecValueData verbatim")

        XCTAssertThrowsError(
            try Keychain.updateAccessibility(
                "cli|missing-item",
                service: service,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        ) { error in
            XCTAssertEqual((error as NSError).code, Int(errSecItemNotFound))
        }
    }

    func testVoiceStartRuntimeBlocksOnLockedStorageAndRetriesAfterUnlock() async throws {
        var storageState: CodexAccount.StorageState = .locked
        var startCount = 0
        var emit: (@MainActor (String) -> Void)?
        func push(_ payload: [String: Any]) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in emit?(text) }
        }

        let voice = CodexVoice(
            startBridge: { _, next in
                startCount += 1
                emit = next
                return true
            },
            sendBridge: { text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let method = object["method"] as? String,
                      let id = object["id"] else { return false }
                switch method {
                case "account/read":
                    push(["id": id, "result": ["account": ["type": "chatgpt"]]])
                case "thread/start":
                    push(["id": id, "result": ["thread": ["id": "unlocked-thread"]]])
                default:
                    push(["id": id, "result": [:]])
                }
                return true
            },
            prepareStorage: { storageState }
        )
        defer { voice.stop() }

        do {
            try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
            XCTFail("Locked Keychain storage must reject runtime startup with Failure.unavailable")
        } catch let error as CodexVoice.Failure {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(startCount, 0, "poki_codex_start must never be called while storage is .locked")

        storageState = .migrated
        try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
        XCTAssertEqual(startCount, 1, "Unlocking storage must allow a subsequent startup attempt")
    }

    func testVoiceReloadsAccountCacheWhenMigratedWhileAlreadyRunning() async throws {
        var storageState: CodexAccount.StorageState = .empty
        var emit: (@MainActor (String) -> Void)?
        var sentMethods: [String] = []
        var reloaded = false
        func push(_ payload: [String: Any]) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in emit?(text) }
        }

        let voice = CodexVoice(
            startBridge: { _, next in
                emit = next
                return true
            },
            sendBridge: { text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let method = object["method"] as? String,
                      let id = object["id"] else { return false }
                sentMethods.append(method)
                switch method {
                case "account/read":
                    if reloaded {
                        push(["id": id, "result": ["account": ["type": "chatgpt"]]])
                    } else {
                        push(["id": id, "result": [:]])
                    }
                case "poki/account/reload":
                    reloaded = true
                    push(["id": id, "result": [:]])
                case "thread/start":
                    push(["id": id, "result": ["thread": ["id": "migrated-while-running-thread"]]])
                default:
                    push(["id": id, "result": [:]])
                }
                return true
            },
            prepareStorage: {
                let current = storageState
                if current == .migrated {
                    storageState = .ready
                }
                return current
            }
        )
        defer { voice.stop() }

        // First call starts runtime while Keychain has no credentials yet.
        do {
            try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
            XCTFail("Empty storage with no account must fail with Failure.signIn")
        } catch let error as CodexVoice.Failure {
            XCTAssertEqual(error, .signIn)
        }
        voice.stop()

        // Runtime is now running; next prepare observes .migrated and must reload before reading account.
        storageState = .migrated
        try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
        XCTAssertTrue(reloaded)
        let reloadIndex = try XCTUnwrap(sentMethods.firstIndex(of: "poki/account/reload"))
        let lastReadIndex = try XCTUnwrap(sentMethods.lastIndex(of: "account/read"))
        XCTAssertLessThan(reloadIndex, lastReadIndex)
    }

    func testSignOutGateSuppressesMigrationAndReadAccessToken() throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)

        let legacyData = try makeCredentialData(
            accessToken: makeJWT(exp: 4_100_000_000, subject: "gated-legacy"),
            lastRefresh: "2026-11-23T08:00:00Z"
        )
        try addRawKeychainItem(
            service: service,
            account: "cli|4000000000000001",
            data: legacyData,
            accessible: kSecAttrAccessibleWhenUnlocked
        )

        var activeGates = 0
        defer {
            while activeGates > 0 {
                CodexAccount.endSignOut()
                activeGates -= 1
            }
        }
        CodexAccount.beginSignOut(); activeGates += 1
        CodexAccount.beginSignOut(); activeGates += 1

        XCTAssertEqual(CodexAccount.prepareStorage(service: service, home: home), .empty)
        XCTAssertNil(CodexAccount.readAccessToken(service: service, home: home))
        XCTAssertNil(try Keychain.read(current, service: service), "Migration write must be suppressed during sign-out")
        XCTAssertEqual(try Keychain.read("cli|4000000000000001", service: service), legacyData)

        // Nested sign-out must stay gated until the final endSignOut().
        CodexAccount.endSignOut(); activeGates -= 1
        XCTAssertEqual(CodexAccount.prepareStorage(service: service, home: home), .empty)
        XCTAssertNil(try Keychain.read(current, service: service))

        // After the outermost sign-out finishes, migration works normally again.
        CodexAccount.endSignOut(); activeGates -= 1
        XCTAssertEqual(CodexAccount.prepareStorage(service: service, home: home), .migrated)
        XCTAssertEqual(try Keychain.read(current, service: service), legacyData)
        XCTAssertNil(try Keychain.read("cli|4000000000000001", service: service))
    }

    func testSignOutIncludingVoicePreservesCurrentKeyForRemoteRevokeGatesMigrationAndClearsAllCredentials() async throws {
        let service = makeTestService()
        defer { assertServiceCleanedUp(service) }
        let home = try makeTempDirectory().appendingPathComponent("CodexVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let current = try expectedAccountKey(for: home)
        let legacyAccount = "cli|5000000000000001"

        let currentData = try makeCredentialData(accessToken: "tok-active-signout", lastRefresh: "2026-11-23T11:00:00Z")
        let legacyData = try makeCredentialData(accessToken: "tok-legacy-signout", lastRefresh: "2026-11-20T11:00:00Z")
        try addRawKeychainItem(service: service, account: current, data: currentData, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try addRawKeychainItem(service: service, account: legacyAccount, data: legacyData, accessible: kSecAttrAccessibleWhenUnlocked)

        var emit: (@MainActor (String) -> Void)?
        var sentMethods: [String] = []
        var logoutObservedCurrentBeforeDelete: Data?
        var logoutObservedLegacyBeforeDelete: Data?
        var gatePrepareState: CodexAccount.StorageState?
        var gateReadToken: String?
        var currentAfterGatedProbe: Data?
        var legacyAfterGatedProbe: Data?
        var logoutHookError: Error?
        func push(_ payload: [String: Any]) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in emit?(text) }
        }

        let voice = CodexVoice(
            startBridge: { _, next in
                emit = next
                return true
            },
            sendBridge: { text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let method = object["method"] as? String,
                      let id = object["id"] else { return false }
                sentMethods.append(method)
                switch method {
                case "account/read":
                    push(["id": id, "result": ["account": ["type": "chatgpt"]]])
                case "thread/start":
                    push(["id": id, "result": ["thread": ["id": "signout-thread"]]])
                case "account/logout":
                    do {
                        logoutObservedCurrentBeforeDelete = try Keychain.read(current, service: service)
                        logoutObservedLegacyBeforeDelete = try Keychain.read(legacyAccount, service: service)
                        try Keychain.remove(current, service: service)
                        gatePrepareState = CodexAccount.prepareStorage(service: service, home: home)
                        gateReadToken = CodexAccount.readAccessToken(service: service, home: home)
                        currentAfterGatedProbe = try Keychain.read(current, service: service)
                        legacyAfterGatedProbe = try Keychain.read(legacyAccount, service: service)
                    } catch {
                        logoutHookError = error
                    }
                    push(["id": id, "result": [:]])
                default:
                    push(["id": id, "result": [:]])
                }
                return true
            },
            prepareStorage: { CodexAccount.prepareStorage(service: service, home: home) }
        )
        defer { voice.stop() }

        try await voice.prepare(onEvent: { _, _ in }, onTool: { _, _ in ("", false, nil) })
        try await ChatGPTAccount.signOutIncludingVoice(voice: voice, service: service)

        XCTAssertNil(logoutHookError, "Unexpected Keychain error inside account/logout hook: \(String(describing: logoutHookError))")
        XCTAssertEqual(sentMethods, ["account/read", "thread/start", "thread/realtime/stop", "account/logout"])
        XCTAssertEqual(
            logoutObservedCurrentBeforeDelete,
            currentData,
            "Current cli|<current> credential must remain intact when account/logout starts so Rust can revoke tokens remotely"
        )
        XCTAssertEqual(logoutObservedLegacyBeforeDelete, legacyData)
        XCTAssertEqual(gatePrepareState, .empty, "Sign-out gate must suppress migration during account/logout")
        XCTAssertNil(gateReadToken, "Sign-out gate must block readAccessToken during account/logout")
        XCTAssertNil(currentAfterGatedProbe, "Sign-out gate must prevent migrating cli|<old> back into cli|<current>")
        XCTAssertEqual(legacyAfterGatedProbe, legacyData, "Gated probe must not modify or remove cli|<old>")

        XCTAssertNil(try Keychain.read(current, service: service))
        XCTAssertNil(try Keychain.read(legacyAccount, service: service))
        let remainingAfterSignOut = try Keychain.readAll(service: service).filter { $0.account.hasPrefix("cli|") }
        XCTAssertTrue(remainingAfterSignOut.isEmpty)
        XCTAssertEqual(CodexAccount.prepareStorage(service: service, home: home), .empty)
        XCTAssertNil(CodexAccount.readAccessToken(service: service, home: home))
    }

    // MARK: - Helpers

    private func makeTestService() -> String {
        let service = "Codex Auth Test.\(UUID().uuidString)"
        createdServices.append(service)
        return service
    }

    private func assertServiceCleanedUp(_ service: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try deleteAllItems(in: service)
            let remaining = try Keychain.readAll(service: service)
            XCTAssertTrue(remaining.isEmpty, "Expected Keychain service \(service) to be clean", file: file, line: line)
        } catch {
            XCTFail("Failed to clean up Keychain service \(service): \(error)", file: file, line: line)
        }
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
        idToken: String? = nil,
        lastRefresh: String?
    ) throws -> Data {
        let resolvedIDToken = try idToken ?? makeJWT(exp: 4_100_000_000, subject: "id-fixture")
        var json: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": resolvedIDToken
            ]
        ]
        if let lastRefresh {
            json["last_refresh"] = lastRefresh
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeCustomJWT(payload: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URL(header)).\(base64URL(payloadData)).sig"
    }

    private func makeJWT(exp: Int, subject: String) throws -> String {
        try makeCustomJWT(payload: [
            "exp": exp,
            "sub": subject,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-fixture",
                "chatgpt_user_id": "user-fixture"
            ]
        ])
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

    private func deleteAllItems(in service: String) throws {
        let items = try Keychain.readAll(service: service)
        for item in items {
            try Keychain.remove(item.account, service: service)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
