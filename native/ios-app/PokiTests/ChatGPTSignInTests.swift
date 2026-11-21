import PiSwiftAI
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

    func testBrowserCallbackCanSaveAndRemoveTheSignIn() async throws {
        let login = ChatGPTBrowserLogin()
        ModelServerStub.answer = (200, Self.issued)
        let opened = expectation(description: "ChatGPT authorization page opened")
        login.onPage = { url in
            guard let url else { return }
            XCTAssertEqual(url.host(), "auth.openai.com")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let state = items?.first(where: { $0.name == "state" })?.value,
                  let redirect = items?.first(where: { $0.name == "redirect_uri" })?.value,
                  var callback = URLComponents(string: redirect) else {
                XCTFail("Authorization page omitted the loopback callback")
                login.stop()
                return
            }
            XCTAssertEqual(callback.host, "127.0.0.1")
            XCTAssertEqual(callback.path, "/auth/callback")
            callback.queryItems = [URLQueryItem(name: "code", value: "test-authorization-code"),
                                   URLQueryItem(name: "state", value: state),
                                   URLQueryItem(name: "client_id", value: "test-registration")]
            guard let callbackURL = callback.url else { login.stop(); XCTFail("Invalid callback URL"); return }
            Task {
                defer { opened.fulfill() }
                do {
                    let (_, response) = try await URLSession.shared.data(from: callbackURL)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                } catch {
                    login.stop()
                    XCTFail("The authorization callback did not reach the listener")
                }
            }
        }

        try await ChatGPTAccount.save(login.signIn(inApp: true))
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertTrue(ChatGPTAccount.signedIn)
        let access = await ModelCredential.apiKey(for: .chatgpt)
        XCTAssertEqual(access, "test-access-rotated")
        try ChatGPTAccount.signOut()
        XCTAssertNil(ModelKeys.key(.chatgpt))
        XCTAssertFalse(ChatGPTAccount.signedIn)
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
