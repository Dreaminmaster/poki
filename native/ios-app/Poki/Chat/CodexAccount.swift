import CryptoKit
import Darwin
import Foundation

enum CodexAccount {
    static var home: URL {
        URL.applicationSupportDirectory.appending(path: "CodexVoice", directoryHint: .isDirectory)
    }

    /// The pinned App Server's direct Keychain store. Read the same item for text requests so the
    /// bearer never crosses the App Server message bridge or has a second persisted copy.
    static var accessToken: String? {
        let original = home.path(percentEncoded: false)
        let path = original.withCString { name in
            guard let resolved = realpath(name, nil) else { return original }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let key = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let bytes = try? Keychain.read("cli|\(key)", service: "Codex Auth"),
              let signIn = try? JSONDecoder().decode(SignIn.self, from: bytes), signIn.authMode == "chatgpt" else { return nil }
        return signIn.tokens.accessToken.isEmpty ? nil : signIn.tokens.accessToken
    }

    static func expiresSoon(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
              let body = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let expiry = body["exp"] as? TimeInterval else { return false }
        return expiry < Date().timeIntervalSince1970 + 60
    }

    private struct SignIn: Decodable {
        let authMode: String
        let tokens: Tokens

        enum CodingKeys: String, CodingKey { case authMode = "auth_mode", tokens }
    }

    private struct Tokens: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
}
