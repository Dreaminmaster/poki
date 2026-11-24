import CryptoKit
import PiSwiftAI
import Security
import XCTest
@testable import Poki

@MainActor
final class ChatGPTSignInTests: XCTestCase {
    private static let issued = """
    {"access_token":"test-access-rotated","refresh_token":"test-refresh-rotated","id_token":"test-id",
     "scope":"chatgpt.tokens.use.direct","expires_in":3600}
    """
    private var codexService = ""
    private var modelKeysService = ""
    private var codexHome: URL!
    private var savedLanguage = AppLocalization.system

    override func setUpWithError() throws {
        try super.setUpWithError()
        codexService = "Codex Auth Test.\(UUID().uuidString)"
        modelKeysService = "Poki ModelKeys Test.\(UUID().uuidString)"
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-signin-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        savedLanguage = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        ModelServerStub.clear()
        ModelServerStub.additionalHosts = ["api.openai.com", "auth.openai.com", "chatgpt.com"]
        URLProtocol.registerClass(ModelServerStub.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.clear()
        AppLocalization.shared.preference = savedLanguage
        var firstError: Error?
        for service in [codexService, modelKeysService] where !service.isEmpty {
            do {
                try deleteAllItems(in: service)
                let remaining = try Keychain.readAll(service: service)
                XCTAssertTrue(remaining.isEmpty, "Expected Keychain service \(service) to be clean")
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let codexHome, FileManager.default.fileExists(atPath: codexHome.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: codexHome)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        codexService = ""
        modelKeysService = ""
        codexHome = nil
        try super.tearDownWithError()
        if let firstError {
            throw firstError
        }
    }

    func testSharedCodexSignInSelectsTheTextProviderWithoutALegacyCredential() async throws {
        try await withIsolatedServices {
            try await withSharedCodexSignIn("fixture-shared-access") {
                XCTAssertTrue(ChatGPTAccount.signedIn)
                let model = try XCTUnwrap(ModelProvider.chatgpt.piModel("gpt-6.1-sol"))
                XCTAssertEqual(model.provider, "openai-codex")
                let token = await ModelCredential.apiKey(for: .chatgpt, piProvider: model.provider)
                XCTAssertEqual(token, "fixture-shared-access")
            }
        }
    }

    func testRejectedSharedCodexSignInUsesHTTPStatusToAskForSignIn() async throws {
        let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let claims = Data("""
        {"exp":\(expiry),"https://api.openai.com/auth":{"chatgpt_account_id":"fixture-account"}}
        """.utf8)
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try await withIsolatedServices {
            try await withSharedCodexSignIn("e30.\(payload).fixture") {
                for (status, expected) in [
                    (401, "Sign in to ChatGPT again. Open Settings, then Models."),
                    (403, "ChatGPT, the request failed.")
                ] {
                    ModelServerStub.answer = (status, #"{"error":{"message":"Unauthorized"}}"#)
                    ModelServerStub.recordedReset()
                    let outcome = try await runTextRequest()
                    XCTAssertEqual(ModelServerStub.requests.compactMap(\.url?.path), ["/backend-api/codex/responses"])
                    XCTAssertEqual(outcome, .failed(expected), "HTTP \(status)")
                }
            }
        }
    }

    private func withIsolatedServices(_ run: () async throws -> Void) async throws {
        try await ModelKeys.$defaultService.withValue(modelKeysService) {
            try await CodexAccount.$defaultService.withValue(codexService) {
                try await CodexAccount.$defaultHome.withValue(codexHome) {
                    try await run()
                }
            }
        }
    }

    private func withSharedCodexSignIn(_ access: String, run: () async throws -> Void) async throws {
        try ChatGPTAccount.signOut(service: modelKeysService)
        let home = try XCTUnwrap(codexHome)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = try XCTUnwrap(realpath(home.path(percentEncoded: false), nil))
        defer { free(path) }
        let fingerprint = SHA256.hash(data: Data(String(cString: path).utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let account = "cli|\(fingerprint)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: codexService, kSecAttrAccount as String: account]
        let idClaims = Data(#"{"sub":"fixture-user","https://api.openai.com/auth":{"chatgpt_account_id":"fixture-account"}}"#.utf8)
        let idPayload = idClaims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let stored = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": access,
                "refresh_token": "fixture-shared-refresh",
                "id_token": "e30.\(idPayload).fixture"
            ]
        ])
        let status = SecItemAdd(query.merging([kSecValueData as String: stored]) { old, _ in old } as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        guard status == errSecSuccess else { return }

        var runError: Error?
        do {
            try await run()
        } catch {
            runError = error
        }
        try Keychain.remove(account, service: codexService)
        if let runError {
            throw runError
        }
    }

    func testExpiredSignInSharesRenewalAndStoresTheRotatedCredential() async throws {
        try await withIsolatedServices {
            try saveCredential(expiresIn: -60, refresh: "test-refresh-old")
            ModelServerStub.answer = (200, Self.issued)
            async let title = ModelCredential.apiKey(for: .chatgpt)
            async let reply = ModelCredential.apiKey(for: .chatgpt)
            let access = await [title, reply]
            XCTAssertEqual(access, ["test-access-rotated", "test-access-rotated"])
            XCTAssertEqual(ModelServerStub.requests.compactMap(\.url?.path), ["/api/accounts/oauth/token"])
            let persisted = ModelKeys.key(.chatgpt, service: modelKeysService).flatMap(ChatGPTAccount.decode)
            XCTAssertEqual(persisted?.refresh, "test-refresh-rotated")
        }
    }

    func testExpiredSignInWithoutRefreshAsksToSignInWithoutSendingToTheModel() async throws {
        try await withIsolatedServices {
            try saveCredential(expiresIn: -60, refresh: "")
            ModelServerStub.answer = (418, "The model should not receive an expired credential.")
            let outcome = try await runTextRequest()
            XCTAssertEqual(outcome, .failed("Sign in to ChatGPT again. Open Settings, then Models."))
            XCTAssertTrue(ModelServerStub.requests.isEmpty)
        }
    }

    func testRejectedSignInAsksToSignInAndKeepsTheServerBodyPrivate() async throws {
        try await withIsolatedServices {
            try saveCredential(expiresIn: 600, refresh: "test-refresh-old")
            ModelServerStub.answer = (401, #"{"error":{"message":"test-private-server-body"}}"#)
            let outcome = try await runTextRequest()
            XCTAssertEqual(outcome, .failed("Sign in to ChatGPT again. Open Settings, then Models."))
            XCTAssertEqual(ModelServerStub.requests.last?.url?.path, "/v1/responses")
        }
    }

    private func saveCredential(expiresIn: TimeInterval, refresh: String) throws {
        try ChatGPTAccount.save(OAuthCredentials(refresh: refresh, access: "test-access-old",
                                                  expires: Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
                                                  clientId: "test-registration"),
                                service: modelKeysService)
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

    private func runTextRequest() async throws -> PiLoop.Outcome {
        let modelID = try XCTUnwrap(ModelProvider.chatgpt.models.first?.id)
        let model = try XCTUnwrap(ModelProvider.chatgpt.piModel(modelID))
        let loop = PiLoop(provider: .chatgpt, model: model, tools: []) { _ in
            .init(text: "No tools.", jpeg: nil, isError: true)
        }
        return await loop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
    }
}
