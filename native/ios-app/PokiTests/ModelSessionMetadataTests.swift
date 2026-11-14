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

    /// A local HTTP server receives the actual request built by pinned PiSwift, not an
    /// isolated header-helper result. It never connects to the real OpenCode service.
    func testActualOutgoingSessionHeadersAcrossRepeatedAndChangedModels() async throws {
        let server = try FakeCompletions(replies: Array(repeating: FakeCompletions.text("OK"), count: 5))
        let url = "http://127.0.0.1:\(server.port)/v1"
        let chatID = "persisted-chat-\(UUID().uuidString)"

        func model(_ id: String) -> Model {
            Model(id: id, name: id, api: .openAICompletions, provider: "opencode-go",
                  baseUrl: url, reasoning: false, input: [.text],
                  cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                  contextWindow: 1_000, maxTokens: 100)
        }
        func loop(_ modelID: String, _ sessionID: String) -> PiLoop {
            PiLoop(provider: .custom, model: model(modelID), sessionID: sessionID, tools: []) { _ in
                .init(text: "No tools", jpeg: nil, isError: true)
            }
        }

        let original = loop("first-model", chatID)
        let first = await original.run("First", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(first, .done)
        // A follow-up uses the same agent; a new PiLoop represents a model switch or a restored chat.
        let again = await original.run("Retry or follow-up", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(again, .done)
        let switched = await loop("second-model", chatID).run("After model switch", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(switched, .done)
        let reopened = await loop("second-model", chatID).run("Reopened", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(reopened, .done)
        let replacementID = "new-chat-\(UUID().uuidString)"
        let newChat = await loop("second-model", replacementID).run("New chat", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(newChat, .done)

        let captured = server.requestHeaders
        XCTAssertEqual(captured.count, 5)
        XCTAssertEqual(Array(captured.prefix(4)).compactMap { $0["x-opencode-session"] },
                       Array(repeating: chatID, count: 4))
        XCTAssertEqual(captured.last?["x-opencode-session"], replacementID)
        XCTAssertTrue(captured.allSatisfy { ($0["user-agent"] ?? "").hasPrefix("poki/") })
        XCTAssertTrue(captured.allSatisfy { $0["x-opencode-client"] == "poki" })
    }

    /// A rejected model request followed by a user retry must keep the same routing identity.
    /// 400 is deliberately non-retryable by the SDK; the next call is an explicit retry.
    func testOutgoingRetryAfterRejectionKeepsTheSessionHeader() async throws {
        let server = try FakeCompletions(replies: [
            FakeCompletions.text("Ignored"), FakeCompletions.text("Recovered")
        ], responseStatuses: [400, 200])
        let sessionID = "manual-retry-\(UUID().uuidString)"
        func attempt() -> PiLoop {
            let model = Model(id: "test", name: "Test", api: .openAICompletions,
                              provider: "opencode-go", baseUrl: "http://127.0.0.1:\(server.port)/v1",
                              reasoning: false, input: [.text],
                              cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                              contextWindow: 1_000, maxTokens: 100)
            return PiLoop(provider: .custom, model: model, sessionID: sessionID, tools: []) { _ in
                .init(text: "No tools", jpeg: nil, isError: true)
            }
        }
        let failed = await attempt().run("First try", instructions: "Answer.", maxTurns: 2) { _ in }
        if case .failed = failed {} else { XCTFail("Expected a rejected request, got \(failed)") }
        let successful = await attempt().run("Try again", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(successful, .done)
        XCTAssertEqual(server.requestHeaders.compactMap { $0["x-opencode-session"] },
                       [sessionID, sessionID])
    }

    func testOtherProviderNeverReceivesOpenCodeSessionHeader() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("OK")])
        let model = syntheticModel(baseURL: "http://127.0.0.1:\(server.port)/v1")
        let loop = PiLoop(provider: .custom, model: model, sessionID: "other-provider-123", tools: []) { _ in
            .init(text: "No tools", jpeg: nil, isError: true)
        }
        let outcome = await loop.run("Hello", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(server.requestHeaders.count, 1)
        XCTAssertNil(server.requestHeaders.first?["x-opencode-session"])
        XCTAssertEqual(server.requestHeaders.first?["x-opencode-client"], nil)
    }

    func testAuxiliaryChatNamingSendsTheSameSessionToModel() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Sydney trip")])
        let chatID = "naming-\(UUID().uuidString)"
        let model = Model(id: "short-title", name: "Short title", api: .openAICompletions,
                          provider: "opencode-go", baseUrl: "http://127.0.0.1:\(server.port)/v1",
                          reasoning: false, input: [.text],
                          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1_000, maxTokens: 100)
        let title = await SessionNamer.name(for: "Plan a Sydney trip", provider: .custom,
                                           model: model, sessionID: chatID)
        XCTAssertEqual(title, "Sydney trip")
        XCTAssertEqual(server.requestHeaders.first?["x-opencode-session"], chatID)
        XCTAssertEqual(server.requestHeaders.count, 1)
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
