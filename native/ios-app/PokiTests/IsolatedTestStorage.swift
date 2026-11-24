import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import Poki

/// Provides an isolated UserDefaults suite, app-group defaults suite, Keychain service, Codex
/// Keychain service, temporary Codex home directory, and temporary pairing file URL for a test case
/// so host credentials, files, and preferences are never read or mutated.
final class IsolatedTestStorage {
    let suiteName: String
    let defaults: UserDefaults
    let appGroupSuiteName: String
    let appGroupDefaults: UserDefaults
    let keychainService: String
    let codexService: String
    let codexHome: URL
    let pairingDirectory: URL
    let pairingFileURL: URL

    init(prefix: String = "poki-test") throws {
        let id = UUID().uuidString
        suiteName = "\(prefix).defaults.\(id)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "IsolatedTestStorage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create UserDefaults suite \(suiteName)",
            ])
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults

        appGroupSuiteName = "\(prefix).appgroup.\(id)"
        guard let appGroupDefaults = UserDefaults(suiteName: appGroupSuiteName) else {
            defaults.removePersistentDomain(forName: suiteName)
            throw NSError(domain: "IsolatedTestStorage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create app-group UserDefaults suite \(appGroupSuiteName)",
            ])
        }
        appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
        self.appGroupDefaults = appGroupDefaults

        keychainService = "\(prefix).keychain.\(id)"
        codexService = "\(prefix).codex.\(id)"
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-codex-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        pairingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-pairing-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: pairingDirectory, withIntermediateDirectories: true)
        pairingFileURL = pairingDirectory.appendingPathComponent("pairing.plist")
    }

    var storage: PokiStorage {
        PokiStorage(
            defaults: defaults,
            appGroupDefaults: appGroupDefaults,
            keychainService: keychainService,
            codexService: codexService,
            codexHome: codexHome,
            pairingFileURL: pairingFileURL
        )
    }

    func reset() throws {
        defaults.removePersistentDomain(forName: suiteName)
        appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
        try Self.deleteAllKeychainItems(in: keychainService)
        try Self.deleteAllKeychainItems(in: codexService)
        for url in [pairingFileURL, storage.phonePairingFileURL] {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func tearDown() throws {
        var firstError: Error?
        defaults.removePersistentDomain(forName: suiteName)
        appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
        for service in [keychainService, codexService] {
            do {
                try Self.deleteAllKeychainItems(in: service)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        for directory in [codexHome, pairingDirectory] {
            if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    /// Writes a valid Codex ChatGPT `AuthDotJson` credential into this storage's isolated `codexService`.
    /// When `account` is nil, computes the canonical current-container `cli|<hash>` key for `codexHome`.
    @discardableResult
    func seedCodexCredential(
        accessToken: String = "fixture-codex-access",
        refreshToken: String = "fixture-codex-refresh",
        lastRefresh: String = "2026-11-24T08:00:00Z",
        account: String? = nil,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws -> String {
        let resolvedAccount = try account ?? Self.codexAccountKey(for: codexHome)
        let idClaims = Data(#"{"sub":"fixture-user","https://api.openai.com/auth":{"chatgpt_account_id":"fixture-account"}}"#.utf8)
        let idPayload = idClaims.base64URL
        let payload: [String: Any] = [
            "auth_mode": "chatgpt",
            "last_refresh": lastRefresh,
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": "e30.\(idPayload).fixture",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: codexService,
            kSecAttrAccount as String: resolvedAccount,
        ]
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]) { _, value in value }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return resolvedAccount
    }

    static func codexAccountKey(for home: URL) throws -> String {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let original = home.path(percentEncoded: false)
        let resolvedPath = original.withCString { name -> String in
            guard let resolved = realpath(name, nil) else { return original }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let digest = SHA256.hash(data: Data(resolvedPath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "cli|\(digest)"
    }

    private static func deleteAllKeychainItems(in service: String) throws {
        let items = try Keychain.readAll(service: service)
        for item in items {
            try Keychain.remove(item.account, service: service)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// Snapshots the host's persisted UI language keys (preserving both existing values and missing-key
/// absence) so tests that verify `AppLocalization.shared` UI rendering never leave residual keys behind.
struct HostLocalizationSnapshot {
    let preference: String
    let hadStandardKey: Bool
    let standardValue: Any?
    let hadEffectiveKey: Bool
    let effectiveValue: Any?

    static func capture() -> Self {
        let standardValue = UserDefaults.standard.object(forKey: AppLocalization.key)
        let effectiveValue = SharedContainer.defaults.object(forKey: AppLocalization.effectiveKey)
        return Self(
            preference: AppLocalization.shared.preference,
            hadStandardKey: standardValue != nil,
            standardValue: standardValue,
            hadEffectiveKey: effectiveValue != nil,
            effectiveValue: effectiveValue
        )
    }

    func restore() {
        AppLocalization.shared.preference = preference
        if hadStandardKey {
            UserDefaults.standard.set(standardValue, forKey: AppLocalization.key)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLocalization.key)
        }
        if hadEffectiveKey {
            SharedContainer.defaults.set(effectiveValue, forKey: AppLocalization.effectiveKey)
        } else {
            SharedContainer.defaults.removeObject(forKey: AppLocalization.effectiveKey)
        }
    }

    func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        let currentStandard = UserDefaults.standard.object(forKey: AppLocalization.key)
        let currentEffective = SharedContainer.defaults.object(forKey: AppLocalization.effectiveKey)
        XCTAssertEqual(currentStandard != nil, hadStandardKey, "Host uiLanguage presence changed", file: file, line: line)
        XCTAssertEqual(currentStandard as? String, standardValue as? String, "Host uiLanguage value changed", file: file, line: line)
        XCTAssertEqual(currentEffective != nil, hadEffectiveKey, "Host effectiveUILanguage presence changed", file: file, line: line)
        XCTAssertEqual(currentEffective as? String, effectiveValue as? String, "Host effectiveUILanguage value changed", file: file, line: line)
    }
}
