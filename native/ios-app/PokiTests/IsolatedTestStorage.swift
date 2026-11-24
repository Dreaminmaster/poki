import Foundation
import Security
import XCTest
@testable import Poki

/// Provides an isolated UserDefaults suite, Keychain service, Codex Keychain service, and temporary
/// Codex home directory for a test case so host credentials and preferences are never read or mutated.
final class IsolatedTestStorage {
    let suiteName: String
    let defaults: UserDefaults
    let keychainService: String
    let codexService: String
    let codexHome: URL
    private var scopeToken: PokiStorage.Token?

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
        keychainService = "\(prefix).keychain.\(id)"
        codexService = "\(prefix).codex.\(id)"
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-codex-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    var scope: PokiStorage.Scope {
        PokiStorage.Scope(
            defaults: defaults,
            keychainService: keychainService,
            codexService: codexService,
            codexHome: codexHome
        )
    }

    func activate() {
        precondition(scopeToken == nil, "IsolatedTestStorage activated twice")
        scopeToken = PokiStorage.pushScope(scope)
    }

    func reset() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try Self.deleteAllKeychainItems(in: keychainService)
        try Self.deleteAllKeychainItems(in: codexService)
    }

    func tearDown() throws {
        if let token = scopeToken {
            PokiStorage.popScope(token)
            scopeToken = nil
        }
        var firstError: Error?
        defaults.removePersistentDomain(forName: suiteName)
        for service in [keychainService, codexService] {
            do {
                try Self.deleteAllKeychainItems(in: service)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if FileManager.default.fileExists(atPath: codexHome.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: codexHome)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
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
