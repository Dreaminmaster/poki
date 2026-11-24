import CryptoKit
import Foundation
import PokiCore
import Security

/// The phone's relay identity (docs/ios-core.md, section 1): an Ed25519 key made once and kept in the
/// keychain, the label derived from it, and the connector secrets, one per MCP client, each revocable.
/// The relay never sees a secret, only its sha256.
struct ConnectorSecret: Codable, Identifiable, Hashable {
    var id: String { secret }
    var name: String
    var secret: String
    var created: Date
    /// The owner named it: an agent connecting later keeps that name.
    var named = false
    /// The first agent that connected through it ("Claude", "Cursor"): its name (unless the owner
    /// named it) and its icon.
    var agent: String?
    var hash: String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }

    init(name: String, secret: String, created: Date, named: Bool = false, agent: String? = nil) {
        self.name = name; self.secret = secret; self.created = created; self.named = named; self.agent = agent
    }

    // Connectors saved before these fields were added: a name other than "Connector N" was the owner's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        secret = try c.decode(String.self, forKey: .secret)
        created = try c.decode(Date.self, forKey: .created)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? !Self.isDefault(name)
    }

    static func isDefault(_ name: String) -> Bool { name.range(of: #"^Connector \d+$"#, options: .regularExpression) != nil }
}

@MainActor
@Observable
final class RelayIdentity {
    private static let keyAccount = "relay.ed25519"
    private static let secretsAccount = "relay.secrets"

    private(set) var label = ""
    private(set) var secrets: [ConnectorSecret] = []
    private(set) var error: String?
    private var key: Curve25519.Signing.PrivateKey?
    private let storage: PokiStorage

    init(storage: PokiStorage = .live) {
        self.storage = storage
        load()
    }

    var publicKey: Data? { key?.publicKey.rawRepresentation }
    var signingKey: Curve25519.Signing.PrivateKey? { key }
    var accessHashes: [String] { secrets.map(\.hash) }

    func url(for secret: ConnectorSecret, relay: RelayAddress) -> URL {
        relay.connectorBase.appendingPathComponent(label).appendingPathComponent(secret.secret).appendingPathComponent("mcp")
    }

    func sign(_ message: Data) throws -> Data {
        guard let key else { throw NSError(domain: "Poki", code: 1, userInfo: [NSLocalizedDescriptionKey: "no relay key"]) }
        return try key.signature(for: message)
    }

    func addSecret(name: String) -> ConnectorSecret {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let taken = Set(secrets.map(\.name))
        var next = 1
        while taken.contains("Connector \(next)") { next += 1 }
        let secret = ConnectorSecret(name: name.isEmpty ? "Connector \(next)" : name, secret: Data(bytes).base64URL, created: Date(), named: !name.isEmpty)
        secrets.append(secret)
        save()
        return secret
    }

    /// The owner's own name for it; an agent connecting later does not change it.
    func rename(_ secret: ConnectorSecret, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = secrets.firstIndex(where: { $0.secret == secret.secret }) else { return }
        secrets[i].name = name
        secrets[i].named = true
        save()
    }

    /// An agent connected through the connector with this hash: the first one gives it its icon, and
    /// its name unless the owner named it.
    func noteAgent(hash: String, client: String) {
        let client = client.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, let i = secrets.firstIndex(where: { $0.hash == hash }), secrets[i].agent == nil else { return }
        secrets[i].agent = client
        if !secrets[i].named {
            let taken = Set(secrets.enumerated().filter { $0.offset != i }.map(\.element.name))
            var name = client, n = 2
            while taken.contains(name) { name = "\(client) \(n)"; n += 1 }
            secrets[i].name = name
        }
        save()
    }

    func revoke(_ secret: ConnectorSecret) {
        secrets.removeAll { $0 == secret }
        save()
    }

    private func load() {
        do {
            if let raw = try Keychain.read(Self.keyAccount, storage: storage) {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            } else {
                let made = Curve25519.Signing.PrivateKey()
                try Keychain.write(made.rawRepresentation, account: Self.keyAccount, storage: storage)
                key = made
            }
            if let data = try Keychain.read(Self.secretsAccount, storage: storage) { secrets = (try? JSONDecoder().decode([ConnectorSecret].self, from: data)) ?? [] }
            label = base32(key!.publicKey.rawRepresentation)
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        do { try Keychain.write(try JSONEncoder().encode(secrets), account: Self.secretsAccount, storage: storage) }
        catch { self.error = "\(error)" }
    }
}

/// Immutable storage boundary binding defaults, app-group defaults, Keychain services,
/// Codex home directory, and pairing file location explicitly per instance.
struct PokiStorage: @unchecked Sendable {
    let defaults: UserDefaults
    let appGroupDefaults: UserDefaults
    let keychainService: String
    let codexService: String
    let codexHome: URL
    let pairingFileURL: URL

    var phonePairingFileURL: URL {
        pairingFileURL.deletingLastPathComponent().appendingPathComponent("pairing-phone.plist")
    }

    static let live = PokiStorage(
        defaults: .standard,
        appGroupDefaults: SharedContainer.defaults,
        keychainService: Keychain.defaultServiceName,
        codexService: CodexAccount.defaultServiceName,
        codexHome: URL.applicationSupportDirectory.appending(path: "CodexVoice", directoryHint: .isDirectory),
        pairingFileURL: AppFiles.pairingFile
    )
}

extension AppLocalization {
    convenience init(storage: PokiStorage) {
        self.init(defaults: storage.defaults, appGroupDefaults: storage.appGroupDefaults)
    }
}

enum Keychain {
    static let defaultServiceName = "nz.zheha.poki"
    static let defaultService = defaultServiceName

    static func read(_ account: String, storage: PokiStorage) throws -> Data? {
        try read(account, service: storage.keychainService)
    }

    static func readWithAttributes(
        _ account: String,
        storage: PokiStorage
    ) throws -> (data: Data, modified: Date?, accessible: String?)? {
        try readWithAttributes(account, service: storage.keychainService)
    }

    static func readAll(
        storage: PokiStorage
    ) throws -> [(account: String, data: Data, modified: Date?, accessible: String?)] {
        try readAll(service: storage.keychainService)
    }

    static func write(_ data: Data, account: String, storage: PokiStorage) throws {
        try write(data, account: account, service: storage.keychainService)
    }

    static func updateAccessibility(
        _ account: String,
        storage: PokiStorage,
        accessible: CFString
    ) throws {
        try updateAccessibility(account, service: storage.keychainService, accessible: accessible)
    }

    static func delete(_ account: String, storage: PokiStorage) {
        delete(account, service: storage.keychainService)
    }

    static func remove(_ account: String, storage: PokiStorage) throws {
        try remove(account, service: storage.keychainService)
    }

    static func read(_ account: String, service name: String = defaultService) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }

    static func readWithAttributes(
        _ account: String,
        service name: String = defaultService
    ) throws -> (data: Data, modified: Date?, accessible: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else { return nil }
        return (
            data: data,
            modified: item[kSecAttrModificationDate as String] as? Date,
            accessible: item[kSecAttrAccessible as String] as? String
        )
    }

    static func readAll(
        service name: String
    ) throws -> [(account: String, data: Data, modified: Date?, accessible: String?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (
                account: account,
                data: data,
                modified: item[kSecAttrModificationDate as String] as? Date,
                accessible: item[kSecAttrAccessible as String] as? String
            )
        }
    }

    static func write(_ data: Data, account: String, service name: String = defaultService) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemAdd(base.merging(attributes) { _, value in value } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func updateAccessibility(
        _ account: String,
        service name: String = defaultService,
        accessible: CFString
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: accessible,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(_ account: String, service name: String = defaultService) {
        try? remove(account, service: name)
    }

    static func remove(_ account: String, service name: String = defaultService) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: account]
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

extension RelayAddress {
    /// The relay the person entered in Connect, kept across launches. Poki has no default relay.
    static var saved: RelayAddress? {
        get { saved(in: .live) }
        set { setSaved(newValue, in: .live) }
    }

    static func saved(in storage: PokiStorage = .live) -> RelayAddress? {
        storage.defaults.string(forKey: "relayAddress").flatMap { RelayAddress($0) }
    }

    static func setSaved(_ address: RelayAddress?, in storage: PokiStorage = .live) {
        storage.defaults.set(address?.origin.absoluteString, forKey: "relayAddress")
    }
}

extension Data {
    /// base64url (RFC 4648 §5) without padding, as `base64URL` makes it.
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
