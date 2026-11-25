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

    static let defaultServiceName = "Codex Auth"
    @TaskLocal static var defaultService = "Codex Auth"
    @TaskLocal static var defaultHome: URL?
    private static let cliAccountPrefix = "cli|"
    private static let targetAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private static let storageLock = NSLock()
    private static var signOutDepth = 0

    static var home: URL {
        defaultHome ?? PokiStorage.live.codexHome
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

    static func hasStoredCredential(service: String = defaultService, home: URL = CodexAccount.home) -> Bool {
        storageLock.lock()
        defer { storageLock.unlock() }

        guard signOutDepth == 0 else { return false }
        let account = currentAccount(for: home)
        if let current = try? Keychain.read(account, service: service),
           decodeValidSignIn(current) != nil {
            return true
        }
        guard let allItems = try? Keychain.readAll(service: service) else { return false }
        return selectNewestCredential(from: allItems, excluding: account) != nil
    }

    static func readAccessToken(storage: PokiStorage) -> String? {
        readAccessToken(service: storage.codexService, home: storage.codexHome)
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
            return signIn.accessToken
        } catch {
            logVoice("Codex Keychain read failed: OSStatus \((error as NSError).code)")
            return nil
        }
    }

    @discardableResult
    static func prepareStorage(storage: PokiStorage) -> StorageState {
        prepareStorage(service: storage.codexService, home: storage.codexHome)
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

    static func clearLegacyCredentials(service: String = defaultService, home: URL = CodexAccount.home) throws {
        storageLock.lock()
        defer { storageLock.unlock() }

        let current = currentAccount(for: home)
        let items: [(account: String, data: Data, modified: Date?, accessible: String?)]
        do {
            items = try Keychain.readAll(service: service)
        } catch {
            logVoice("Codex Keychain scan failed: OSStatus \((error as NSError).code)")
            throw error
        }
        for item in items where item.account.hasPrefix(cliAccountPrefix) && item.account != current {
            do {
                try Keychain.remove(item.account, service: service)
            } catch {
                logVoice("Codex Keychain legacy cleanup failed: OSStatus \((error as NSError).code)")
                throw error
            }
        }
    }

    static func clearStoredCredentials(service: String = defaultService) throws {
        storageLock.lock()
        defer { storageLock.unlock() }

        let items: [(account: String, data: Data, modified: Date?, accessible: String?)]
        do {
            items = try Keychain.readAll(service: service)
        } catch {
            logVoice("Codex Keychain scan failed: OSStatus \((error as NSError).code)")
            throw error
        }
        for item in items where item.account.hasPrefix(cliAccountPrefix) {
            do {
                try Keychain.remove(item.account, service: service)
            } catch {
                logVoice("Codex Keychain cleanup failed: OSStatus \((error as NSError).code)")
                throw error
            }
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
                notExpiringSoon: !expiresSoon(signIn.accessToken),
                lastRefresh: signIn.lastRefresh ?? .distantPast,
                jwtExpiry: jwtExpiry(signIn.accessToken) ?? 0,
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

    private static func decodeValidSignIn(_ data: Data) -> ValidSignIn? {
        guard let signIn = try? JSONDecoder().decode(SignIn.self, from: data),
              signIn.authMode == "chatgpt",
              !signIn.tokens.accessToken.isEmpty,
              !signIn.tokens.refreshToken.isEmpty,
              decodeIdClaims(from: signIn.tokens.idToken) != nil else { return nil }

        let parsedLastRefresh: Date?
        if let rawLastRefresh = signIn.lastRefresh {
            guard let date = parseRFC3339(rawLastRefresh) else { return nil }
            parsedLastRefresh = date
        } else {
            parsedLastRefresh = nil
        }

        return ValidSignIn(accessToken: signIn.tokens.accessToken, lastRefresh: parsedLastRefresh)
    }

    /// The ChatGPT workspace an access token is for (its `chatgpt_account_id` claim), which Codex's
    /// requests name in their `chatgpt-account-id` header.
    /// Reads only that claim, so a token the strict sign-in check turns down (for example a `null`
    /// FedRAMP claim) still names its workspace for the model list.
    static func chatGPTAccountID(_ accessToken: String) -> String? {
        guard let payload = decodeJWTPayloadData(accessToken),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = claims[IdClaims.CodingKeys.auth.rawValue] as? [String: Any],
              let id = auth[AuthClaims.CodingKeys.chatgptAccountId.rawValue] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    private static func decodeIdClaims(from token: String) -> IdClaims? {
        guard let payload = decodeJWTPayloadData(token) else { return nil }
        return try? JSONDecoder().decode(IdClaims.self, from: payload)
    }

    private static func decodeJWTPayloadData(_ token: String) -> Data? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        let payloadPart = String(parts[1])
        guard !payloadPart.contains("+"),
              !payloadPart.contains("/"),
              !payloadPart.contains("="),
              let payload = Data(base64URL: payloadPart),
              payload.base64URL == payloadPart else { return nil }
        return payload
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20 else { return nil }

        func digits(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 48 && byte <= 57 else { return nil }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }

        guard bytes[4] == 45, bytes[7] == 45,
              bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58,
              let year = digits(0..<4),
              let month = digits(5..<7),
              let day = digits(8..<10),
              let hour = digits(11..<13),
              let minute = digits(14..<16),
              let second = digits(17..<19),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else { return nil }

        var index = 19
        var fractionalSeconds = 0.0
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            let start = index
            while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 {
                index += 1
            }
            let count = index - start
            guard (1...9).contains(count) else { return nil }
            var scale = 0.1
            for position in start..<index {
                fractionalSeconds += Double(bytes[position] - 48) * scale
                scale *= 0.1
            }
        }

        guard index < bytes.count else { return nil }
        let offsetSeconds: Int
        if bytes[index] == 90 || bytes[index] == 122 {
            guard index + 1 == bytes.count else { return nil }
            offsetSeconds = 0
        } else if bytes[index] == 43 || bytes[index] == 45 {
            let sign = bytes[index] == 43 ? 1 : -1
            guard index + 6 == bytes.count,
                  bytes[index + 3] == 58,
                  let offsetHour = digits((index + 1)..<(index + 3)),
                  let offsetMinute = digits((index + 4)..<(index + 6)),
                  (0...23).contains(offsetHour),
                  (0...59).contains(offsetMinute) else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        } else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard components.isValidDate(in: calendar),
              let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fractionalSeconds - Double(offsetSeconds))
    }

    private static func jwtExpiry(_ token: String) -> TimeInterval? {
        guard let payload = decodeJWTPayloadData(token),
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

    private struct ValidSignIn {
        let accessToken: String
        let lastRefresh: Date?
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
        let openAIApiKey: String?
        let tokens: Tokens
        let lastRefresh: String?
        let personalAccessToken: String?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIApiKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
            case personalAccessToken = "personal_access_token"
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let oauthProvenance: AccountOAuthProvenance?
        let loginOwnerId: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case oauthProvenance = "oauth_provenance"
            case loginOwnerId = "login_owner_id"
            case accountId = "account_id"
        }
    }

    private struct AccountOAuthProvenance: Decodable {
        let issuer: String
        let clientId: String

        enum CodingKeys: String, CodingKey {
            case issuer
            case clientId = "client_id"
        }
    }

    private struct IdClaims: Decodable {
        let email: String?
        let profile: ProfileClaims?
        let auth: AuthClaims?

        enum CodingKeys: String, CodingKey {
            case email
            case profile = "https://api.openai.com/profile"
            case auth = "https://api.openai.com/auth"
        }
    }

    private struct ProfileClaims: Decodable {
        let email: String?
    }

    private struct AuthClaims: Decodable {
        let chatgptPlanType: String?
        let chatgptUserId: String?
        let userId: String?
        let chatgptAccountId: String?
        let chatgptAccountIsFedramp: Bool

        enum CodingKeys: String, CodingKey {
            case chatgptPlanType = "chatgpt_plan_type"
            case chatgptUserId = "chatgpt_user_id"
            case userId = "user_id"
            case chatgptAccountId = "chatgpt_account_id"
            case chatgptAccountIsFedramp = "chatgpt_account_is_fedramp"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chatgptPlanType = try container.decodeIfPresent(String.self, forKey: .chatgptPlanType)
            chatgptUserId = try container.decodeIfPresent(String.self, forKey: .chatgptUserId)
            userId = try container.decodeIfPresent(String.self, forKey: .userId)
            chatgptAccountId = try container.decodeIfPresent(String.self, forKey: .chatgptAccountId)
            if container.contains(.chatgptAccountIsFedramp) {
                chatgptAccountIsFedramp = try container.decode(Bool.self, forKey: .chatgptAccountIsFedramp)
            } else {
                chatgptAccountIsFedramp = false
            }
        }
    }
}
