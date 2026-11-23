import CryptoKit
import Darwin
import Foundation
import Security

enum CodexAccount {
    private static let defaultService = "Codex Auth"
    private static let cliAccountPrefix = "cli|"
    private static let targetAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private static let storageLock = NSLock()

    static var home: URL {
        URL.applicationSupportDirectory.appending(path: "CodexVoice", directoryHint: .isDirectory)
    }

    /// The pinned App Server's direct Keychain store. Read the same item for text requests so the
    /// bearer never crosses the App Server message bridge or has a second persisted copy.
    static var accessToken: String? {
        readAccessToken()
    }

    static func readAccessToken(service: String = defaultService, home: URL = CodexAccount.home) -> String? {
        storageLock.lock()
        let prepared = prepareStorageLocked(service: service, home: home)
        storageLock.unlock()
        guard prepared else { return nil }

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

    static func prepareStorage(service: String = defaultService, home: URL = CodexAccount.home) {
        storageLock.lock()
        defer { storageLock.unlock() }
        _ = prepareStorageLocked(service: service, home: home)
    }

    static func ensureAfterFirstUnlock(service: String = defaultService, home: URL = CodexAccount.home) {
        storageLock.lock()
        defer { storageLock.unlock() }

        let account = currentAccount(for: home)
        let current: (data: Data, modified: Date?, accessible: String?)?
        do {
            current = try Keychain.readWithAttributes(account, service: service)
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
            return
        }
        guard let current, current.accessible != targetAccessibility else { return }
        do {
            try Keychain.write(current.data, account: account, service: service)
        } catch {
            logVoice("Codex Keychain accessibility upgrade failed: OSStatus \((error as NSError).code)")
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
        var best: (item: (account: String, data: Data, modified: Date?, accessible: String?), rank: (Date, TimeInterval, Date))?
        for item in items {
            guard item.account.hasPrefix(cliAccountPrefix),
                  item.account != currentAccount,
                  let signIn = decodeValidSignIn(item.data) else { continue }
            let rank = (
                parseISO8601(signIn.lastRefresh) ?? .distantPast,
                jwtExpiry(signIn.tokens.accessToken) ?? 0,
                item.modified ?? .distantPast
            )
            if best == nil || best!.rank < rank {
                best = (item, rank)
            }
        }
        return best?.item
    }

    private static func prepareStorageLocked(service: String, home: URL) -> Bool {
        let account = currentAccount(for: home)
        let current: (data: Data, modified: Date?, accessible: String?)?
        do {
            current = try Keychain.readWithAttributes(account, service: service)
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
            return false
        }

        if let current, decodeValidSignIn(current.data) != nil {
            if current.accessible != targetAccessibility {
                do {
                    try Keychain.write(current.data, account: account, service: service)
                } catch {
                    logVoice("Codex Keychain accessibility upgrade failed: OSStatus \((error as NSError).code)")
                }
            }
            return true
        }

        let allItems: [(account: String, data: Data, modified: Date?, accessible: String?)]
        do {
            allItems = try Keychain.readAll(service: service)
        } catch {
            logVoice("Codex Keychain scan failed: OSStatus \((error as NSError).code)")
            return false
        }

        guard let selected = selectNewestCredential(from: allItems, excluding: account) else { return true }
        let legacyAccounts = allItems.compactMap { item -> String? in
            guard item.account.hasPrefix(cliAccountPrefix),
                  item.account != account,
                  decodeValidSignIn(item.data) != nil else { return nil }
            return item.account
        }

        do {
            try Keychain.write(selected.data, account: account, service: service)
        } catch {
            logVoice("Codex Keychain migration write failed: OSStatus \((error as NSError).code)")
            return true
        }

        let verified: Data?
        do {
            verified = try Keychain.read(account, service: service)
        } catch {
            logVoice("Codex Keychain migration verify failed: OSStatus \((error as NSError).code)")
            return true
        }

        guard verified == selected.data else {
            logVoice("Codex Keychain migration verification mismatch; kept legacy items")
            return true
        }

        var removedCount = 0
        for legacy in legacyAccounts {
            do {
                try Keychain.remove(legacy, service: service)
                removedCount += 1
            } catch {
                logVoice("Codex Keychain legacy cleanup failed: OSStatus \((error as NSError).code)")
            }
        }
        logVoice("Codex Keychain migrated credential to current container (removed \(removedCount) legacy item(s))")
        return true
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
              !signIn.tokens.accessToken.isEmpty else { return nil }
        return signIn
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
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = Data(base64URL: String(parts[1])),
              let body = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
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

        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
}
