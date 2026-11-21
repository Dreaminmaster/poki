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
    private var savedSignIn: String?
    private var savedLanguage = AppLocalization.system

    override func setUp() {
        savedSignIn = ModelKeys.key(.chatgpt)
        savedLanguage = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        ModelServerStub.clear()
        ModelServerStub.additionalHosts = ["api.openai.com", "auth.openai.com"]
        URLProtocol.registerClass(ModelServerStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.clear()
        ModelKeys.remove(.chatgpt)
        if let savedSignIn { try? ModelKeys.save(savedSignIn, for: .chatgpt) }
        AppLocalization.shared.preference = savedLanguage
    }

    func testSharedCodexSignInSelectsTheTextProviderWithoutALegacyCredential() async throws {
        try ChatGPTAccount.signOut()
        try FileManager.default.createDirectory(at: CodexAccount.home, withIntermediateDirectories: true)
        let path = try XCTUnwrap(realpath(CodexAccount.home.path(percentEncoded: false), nil))
        defer { free(path) }
        let fingerprint = SHA256.hash(data: Data(String(cString: path).utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Codex Auth", kSecAttrAccount as String: "cli|\(fingerprint)"]
        let stored = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-shared-access"}}"#.utf8)
        let status = SecItemAdd(query.merging([kSecValueData as String: stored]) { old, _ in old } as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        guard status == errSecSuccess else { return }
        defer { SecItemDelete(query as CFDictionary) }

        XCTAssertTrue(ChatGPTAccount.signedIn)
        let model = try XCTUnwrap(ModelProvider.chatgpt.piModel("gpt-6.1-sol"))
        XCTAssertEqual(model.provider, "openai-codex")
        let token = await ModelCredential.apiKey(for: .chatgpt, piProvider: model.provider)
        XCTAssertEqual(token, "fixture-shared-access")
    }

    func testExpiredSignInSharesRenewalAndStoresTheRotatedCredential() async throws {
        try saveCredential(expiresIn: -60, refresh: "test-refresh-old")
        ModelServerStub.answer = (200, Self.issued)
        async let title = ModelCredential.apiKey(for: .chatgpt)
        async let reply = ModelCredential.apiKey(for: .chatgpt)
        let access = await [title, reply]
        XCTAssertEqual(access, ["test-access-rotated", "test-access-rotated"])
        XCTAssertEqual(ModelServerStub.requests.compactMap(\.url?.path), ["/api/accounts/oauth/token"])
        let persisted = ModelKeys.key(.chatgpt).flatMap(ChatGPTAccount.decode)
        XCTAssertEqual(persisted?.refresh, "test-refresh-rotated")
    }

    func testExpiredSignInWithoutRefreshAsksToSignInWithoutSendingToTheModel() async throws {
        try saveCredential(expiresIn: -60, refresh: "")
        ModelServerStub.answer = (418, "The model should not receive an expired credential.")
        let outcome = try await runTextRequest()
        XCTAssertEqual(outcome, .failed("Sign in to ChatGPT again. Open Settings, then Models."))
        XCTAssertTrue(ModelServerStub.requests.isEmpty)
    }

    func testRejectedSignInAsksToSignInAndKeepsTheServerBodyPrivate() async throws {
        try saveCredential(expiresIn: 600, refresh: "test-refresh-old")
        ModelServerStub.answer = (401, #"{"error":{"message":"test-private-server-body"}}"#)
        let outcome = try await runTextRequest()
        XCTAssertEqual(outcome, .failed("Sign in to ChatGPT again. Open Settings, then Models."))
        XCTAssertEqual(ModelServerStub.requests.last?.url?.path, "/v1/responses")
    }

    private func saveCredential(expiresIn: TimeInterval, refresh: String) throws {
        try ChatGPTAccount.save(OAuthCredentials(refresh: refresh, access: "test-access-old",
                                                  expires: Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
                                                  clientId: "test-registration"))
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
