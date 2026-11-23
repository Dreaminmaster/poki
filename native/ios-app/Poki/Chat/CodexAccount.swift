import CryptoKit
import Darwin
import Foundation
import Security

enum CodexAccount {
    enum StorageState: Equatable {
        case ready
        case migrated
        case empty
        case locked
        case failed(OSStatus)
    }

    static let defaultService = "Codex Auth"
    private static let cliAccountPrefix = "cli|"
    private static let targetAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private static let storageLock = NSLock()
    private static var signOutDepth = 0

    static var home: URL {
        URL.applicationSupportDirectory.appending(path: "CodexVoice", directoryHint: .isDirectory)
    }

    /// The pinned App Server's direct Keychain store. Read the same item for text requests so the
    /// bearer never crosses the App Server message bridge or has a second persisted copy.
    static var accessToken: String? {
        readAccessToken()
    }

    static func beginSignOut() {
        storageLock.lock()
        signOutDepth += 1
        storageLock.unlock()
    }

    static func endSignOut() {
        storageLock.lock()
        signOutDepth = max(0, signOutDepth - 1)
        storageLock.unlock()
    }

    static func readAccessToken(service: String = defaultService, home: URL = CodexAccount.home) -> String? {
        storageLock.lock()
        defer { storageLock.unlock() }

        guard signOutDepth == 0 else { return nil }
        switch prepareStorageLocked(service: service, home: home) {
        case .ready, .migrated:
            break
        case .empty, .locked, .failed:
            return nil
        }

        let account = currentAccount(for: home)
        do {
            guard let bytes = try Keychain.read(account, service: service),
                  let signIn = decodeValidSignIn(bytes) else { return nil }
            return signIn.tokens.accessToken
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
            return nil
        }
    }

    @discardableResult
    static func prepareStorage(service: String = defaultService, home: URL = CodexAccount.home) -> StorageState {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard signOutDepth == 0 else { return .empty }
        return prepareStorageLocked(service: service, home: home)
    }

    static func ensureAfterFirstUnlock(service: String = defaultService, home: URL = CodexAccount.home) {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard signOutDepth == 0 else { return }

        let account = currentAccount(for: home)
        do {
            guard let current = try Keychain.readWithAttributes(account, service: service) else { return }
            upgradeAccessibilityIfNeeded(account: account, service: service, currentAccessible: current.accessible)
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
        }
    }

    static func clearStoredCredentials(service: String = defaultService) throws {
        storageLock.lock()
        defer { storageLock.unlock() }

        let items = try Keychain.readAll(service: service)
        for item in items where item.account.hasPrefix(cliAccountPrefix) {
            try Keychain.remove(item.account, service: service)
        }
    }

    static func expiresSoon(_ token: String) -> Bool {
        guard let expiry = jwtExpiry(token) else { return false }
        return expiry < Date().timeIntervalSince1970 + 60
    }

    static func selectNewestCredential(
        from items: [(account: String, data: Data, modified: Date?, accessible: String?)],
        excluding currentAccount: String
    ) -> (account: String, data: Data, modified: Date?, accessible: String?)? {
        var best: (item: (account: String, data: Data, modified: Date?, accessible: String?), rank: CredentialRank)?
        for item in items {
            guard item.account.hasPrefix(cliAccountPrefix),
                  item.account != currentAccount,
                  let signIn = decodeValidSignIn(item.data) else { continue }
            let rank = CredentialRank(
                notExpiringSoon: !expiresSoon(signIn.tokens.accessToken),
                lastRefresh: parseISO8601(signIn.lastRefresh) ?? .distantPast,
                jwtExpiry: jwtExpiry(signIn.tokens.accessToken) ?? 0,
                modified: item.modified ?? .distantPast
            )
            if best == nil || best!.rank < rank {
                best = (item, rank)
            }
        }
        return best?.item
    }

    private static func prepareStorageLocked(service: String, home: URL) -> StorageState {
        let account = currentAccount(for: home)
        let current: (data: Data, modified: Date?, accessible: String?)?
        do {
            current = try Keychain.readWithAttributes(account, service: service)
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
            return storageState(for: error)
        }

        if let current, decodeValidSignIn(current.data) != nil {
            upgradeAccessibilityIfNeeded(account: account, service: service, currentAccessible: current.accessible)
            return .ready
        }

        let allItems: [(account: String, data: Data, modified: Date?, accessible: String?)]
        do {
            allItems = try Keychain.readAll(service: service)
        } catch {
            logVoice("Codex Keychain scan failed: OSStatus \((error as NSError).code)")
            return storageState(for: error)
        }

        guard let selected = selectNewestCredential(from: allItems, excluding: account) else { return .empty }

        do {
            try Keychain.write(selected.data, account: account, service: service)
        } catch {
            logVoice("Codex Keychain migration write failed: OSStatus \((error as NSError).code)")
            return storageState(for: error)
        }

        let verified: Data?
        do {
            verified = try Keychain.read(account, service: service)
        } catch {
            logVoice("Codex Keychain migration verify failed: OSStatus \((error as NSError).code)")
            return storageState(for: error)
        }

        guard verified == selected.data else {
            logVoice("Codex Keychain migration verification mismatch; kept legacy item")
            return .failed(errSecDecode)
        }

        do {
            try Keychain.remove(selected.account, service: service)
            logVoice("Codex Keychain migrated credential to current container (removed 1 legacy item)")
        } catch {
            logVoice("Codex Keychain legacy cleanup failed: OSStatus \((error as NSError).code)")
        }
        return .migrated
    }

    private static func upgradeAccessibilityIfNeeded(
        account: String,
        service: String,
        currentAccessible: String?
    ) {
        guard currentAccessible != targetAccessibility else { return }
        do {
            try Keychain.updateAccessibility(
                account,
                service: service,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        } catch {
            logVoice("Codex Keychain accessibility upgrade failed: OSStatus \((error as NSError).code)")
        }
    }

    private static func storageState(for error: Error) -> StorageState {
        let status = OSStatus((error as NSError).code)
        return status == errSecInteractionNotAllowed ? .locked : .failed(status)
    }

    private static func currentAccount(for home: URL) -> String {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let original = home.path(percentEncoded: false)
        let path = original.withCString { name in
            guard let resolved = realpath(name, nil) else { return original }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let key = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(cliAccountPrefix)\(key)"
    }

    private static func decodeValidSignIn(_ data: Data) -> SignIn? {
        guard let signIn = try? JSONDecoder().decode(SignIn.self, from: data),
              signIn.authMode == "chatgpt",
              !signIn.tokens.accessToken.isEmpty,
              !signIn.tokens.refreshToken.isEmpty,
              isValidJWT(signIn.tokens.idToken) else { return nil }
        return signIn
    }

    private static func isValidJWT(_ token: String) -> Bool {
        decodeJWTPayload(token) != nil
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        let payloadPart = String(parts[1])
        guard !payloadPart.contains("+"),
              !payloadPart.contains("/"),
              !payloadPart.contains("="),
              let payload = Data(base64URL: payloadPart),
              let body = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        return body
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func jwtExpiry(_ token: String) -> TimeInterval? {
        guard let body = decodeJWTPayload(token) else { return nil }
        if let expiry = body["exp"] as? TimeInterval { return expiry }
        if let expiry = body["exp"] as? NSNumber { return expiry.doubleValue }
        return nil
    }

    private static func logVoice(_ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppLog.shared.add("voice", message) }
        } else {
            Task { @MainActor in AppLog.shared.add("voice", message) }
        }
    }

    private struct CredentialRank: Comparable {
        let notExpiringSoon: Bool
        let lastRefresh: Date
        let jwtExpiry: TimeInterval
        let modified: Date

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.notExpiringSoon != rhs.notExpiringSoon {
                return !lhs.notExpiringSoon && rhs.notExpiringSoon
            }
            if lhs.lastRefresh != rhs.lastRefresh {
                return lhs.lastRefresh < rhs.lastRefresh
            }
            if lhs.jwtExpiry != rhs.jwtExpiry {
                return lhs.jwtExpiry < rhs.jwtExpiry
            }
            return lhs.modified < rhs.modified
        }
    }

    private struct SignIn: Decodable {
        let authMode: String
        let tokens: Tokens
        let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }
}
