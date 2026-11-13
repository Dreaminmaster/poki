import XCTest
import PiSwiftAI
@testable import Poki

/// Provider request metadata follows the saved conversation, including auxiliary model calls.
@MainActor
final class ModelSessionMetadataTests: XCTestCase {
    private func syntheticModel(baseURL: String) -> Model {
        Model(id: "synthetic", name: "Synthetic", api: .openAICompletions,
              provider: "poki-custom", baseUrl: baseURL, reasoning: false,
              input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
              contextWindow: 1_000, maxTokens: 100)
    }

    func testPokiLoopCarriesThePersistedConversationID() {
        let session = "saved-chat-123"
        let loop = PiLoop(provider: .custom, model: syntheticModel(baseURL: "https://opencode.ai/v1"),
                          sessionID: session, tools: []) { _ in
            .init(text: "No tools", jpeg: nil, isError: true)
        }
        XCTAssertEqual(loop.sessionID, session)
    }

    func testPinnedPiSwiftLimitsOpenCodeHeaderToMatchingEndpoint() {
        let session = "saved-chat-123"
        let target = syntheticModel(baseURL: "https://opencode.ai/v1")
        let other = syntheticModel(baseURL: "https://example.test/v1")
        XCTAssertEqual(openCodeSessionHeaders(model: target, sessionId: session, headers: nil)?["x-opencode-session"], session)
        XCTAssertNil(openCodeSessionHeaders(model: other, sessionId: session, headers: nil)?["x-opencode-session"])
        // PiSwift must preserve an explicitly supplied routing header.
        XCTAssertEqual(openCodeSessionHeaders(model: target, sessionId: session,
                                               headers: ["X-OpenCode-Session": "provided"])?["X-OpenCode-Session"], "provided")
    }

    func testRequestIdentityUsesTheRealPokiProductName() {
        let identity = PiLoop.clientIdentity(version: "0.4.0")
        XCTAssertEqual(formatUserAgent(identity: identity), "Poki/0.4.0")
        XCTAssertEqual(identity.attribution,
                       .value(ClientAttribution(name: "Poki", url: "https://github.com/JosssphZhou/poki")))
        XCTAssertEqual(formatUserAgent(identity: PiLoop.clientIdentity(version: " ")), "Poki/dev")
    }

    func testNewConversationGetsNewRequestIdentity() {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app, kind: .handoff, requester: "Unit test", sessionID: "saved-chat-123")
        XCTAssertEqual(chat.sessionID, "saved-chat-123")
        chat.newConversation()
        XCTAssertNotEqual(chat.sessionID, "saved-chat-123")
        XCTAssertNotNil(UUID(uuidString: chat.sessionID))
    }
}
