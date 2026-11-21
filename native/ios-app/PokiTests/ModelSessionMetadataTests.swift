import XCTest
import PiSwiftAI
import PokiCore
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

    func testBackupRequestRechecksHostAndUsesOnlyItsOwningConversation() throws {
        let primary = try XCTUnwrap(URL(string: "https://opencode.ai/v1/responses"))
        var request = URLRequest(url: primary)
        // Deliberately stale metadata from a different conversation must not reach a backup.
        request.setValue("other-chat-id", forHTTPHeaderField: "x-opencode-session")
        request.setValue("Other Client", forHTTPHeaderField: "x-opencode-client")
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let actualID = "own-chat-MixedCase-123"

        let outside = try XCTUnwrap(URL(string: "https://unrelated-gateway.example/v1/responses"))
        let moved = CustomEndpointClient.routedFallback(request, to: outside, conversationSessionID: actualID)
        XCTAssertEqual(moved.url, outside)
        XCTAssertNil(moved.value(forHTTPHeaderField: "x-opencode-session"))
        XCTAssertNil(moved.value(forHTTPHeaderField: "x-opencode-client"))
        XCTAssertEqual(moved.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")

        let trusted = try XCTUnwrap(URL(string: "https://opencode.ai/inference/go/openai/v1/responses"))
        let again = CustomEndpointClient.routedFallback(request, to: trusted, conversationSessionID: actualID)
        XCTAssertEqual(again.value(forHTTPHeaderField: "x-opencode-session"), actualID)
        XCTAssertEqual(again.value(forHTTPHeaderField: "x-opencode-client"), "Poki")

        let noOwner = CustomEndpointClient.routedFallback(request, to: trusted, conversationSessionID: nil)
        XCTAssertNil(noOwner.value(forHTTPHeaderField: "x-opencode-session"))
        // Never let a plain generic endpoint acquire an OpenCode header on fallback.
        let plain = URLRequest(url: primary)
        let plainBackup = CustomEndpointClient.routedFallback(plain, to: trusted, conversationSessionID: actualID)
        XCTAssertNil(plainBackup.value(forHTTPHeaderField: "x-opencode-session"))
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
        let chatID = "persisted-chat-MixedCase-\(UUID().uuidString)"

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
        let replacementID = "new-chat-MixedCase-\(UUID().uuidString)"
        let newChat = await loop("second-model", replacementID).run("New chat", instructions: "Answer.", maxTurns: 2) { _ in }
        XCTAssertEqual(newChat, .done)

        let captured = server.requestHeaders
        XCTAssertEqual(captured.count, 5)
        XCTAssertEqual(Array(captured.prefix(4)).compactMap { $0["x-opencode-session"] },
                       Array(repeating: chatID, count: 4))
        XCTAssertEqual(captured.last?["x-opencode-session"], replacementID)
        XCTAssertTrue(captured.allSatisfy { ($0["user-agent"] ?? "").hasPrefix("Poki/") })
        XCTAssertTrue(captured.allSatisfy { $0["x-opencode-client"] == "Poki" })
    }

    /// A rejected model request followed by a user retry must keep the same routing identity.
    /// 400 is deliberately non-retryable by the SDK; the next call is an explicit retry.
    func testOutgoingRetryAfterRejectionKeepsTheSessionHeader() async throws {
        let server = try FakeCompletions(replies: [
            FakeCompletions.text("Ignored"), FakeCompletions.text("Recovered")
        ], responseStatuses: [400, 200])
        let sessionID = "manual-retry-MixedCase-\(UUID().uuidString)"
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

    /// A strict OpenAI-compatible Responses gateway rejects unknown JSON fields.
    /// The SDK's sessionId normally injects prompt_cache_key into its payload.
    /// The actual PiLoop request must still succeed, just as Test Connection did.
    func testStrictCustomResponsesEndpointDoesNotReceivePromptCacheKey() async throws {
        let payload = [
            #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_strict","role":"assistant"}}"#,
            #"data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"OK"}"#,
            #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_strict","role":"assistant","content":[{"type":"output_text","text":"OK"}]}}"#,
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#
        ].joined(separator: "\n\n") + "\n\n"
        let server = try FakeCompletions(replies: [payload], rejectUnknownCacheField: true)
        let model = Model(id: "strict-custom", name: "Strict custom", api: .openAIResponses,
                          provider: "poki-custom", baseUrl: "http://127.0.0.1:\(server.port)/v1",
                          reasoning: false, input: [.text],
                          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1_000, maxTokens: 100)
        let loop = PiLoop(provider: .custom, model: model,
                          sessionID: "saved-strict-provider-123", tools: []) { _ in
            .init(text: "No tools", jpeg: nil, isError: true)
        }
        let answer = await loop.run("Hello", instructions: "Be brief.", maxTurns: 2) { _ in }
        XCTAssertEqual(answer, .done, "A valid custom Responses endpoint must not fail on cache fields")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(server.requests.first?["prompt_cache_key"])
        XCTAssertNil(server.requests.first?["prompt_cache_retention"])
        XCTAssertNil(server.requestHeaders.first?["x-opencode-session"])
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
        let chatID = "naming-MixedCase-\(UUID().uuidString)"
        let model = Model(id: "short-title", name: "Short title", api: .openAICompletions,
                          provider: "opencode-go", baseUrl: "http://127.0.0.1:\(server.port)/v1",
                          reasoning: false, input: [.text],
                          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1_000, maxTokens: 100)
        let title = await SessionNamer.name(for: "Plan a Sydney trip", provider: .custom,
                                           model: model, sessionID: chatID)
        // The 0.4.3 fake server replies to naming calls independently of chat scripts.
        XCTAssertEqual(title, "Test conversation")
        XCTAssertEqual(server.requestHeaders.first?["x-opencode-session"], chatID)
        XCTAssertEqual(server.requestHeaders.count, 1)
    }

    /// Only the selected model is injected; ChatModel restoration, send, model loop, SDK
    /// transport and classifier execute their production paths against disposable HTTP fixtures.
    private func fixtureModel(_ server: FakeCompletions, id: String = "routing-fixture") -> Model {
        Model(id: id, name: id, api: .openAICompletions, provider: "opencode-go",
              baseUrl: "http://127.0.0.1:\(server.port)/v1", reasoning: false, input: [.text],
              cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
              contextWindow: 128_000, maxTokens: 100)
    }

    private func withRoutingFixture(_ body: (AppModel, SessionStore) async throws -> Void) async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "pokiChat",
                    CustomProviders.storeKey, CustomProviders.selectedKey, "chat.model.custom", "models.enabled.custom"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ModelSessionMetadataTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        UserDefaults.standard.removeObject(forKey: "pokiChat")
        // Never edit the owner's configured provider or reuse its secret/backups.
        let provider = CustomProviders.upsert(CustomProvider(endpoints: [CustomEndpoint(url: "http://127.0.0.1:1/v1")], model: "routing-fixture"))
        ModelKeys.selectedProvider = .custom
        ModelKeys.selectedModel = CustomProviders.choiceID(provider.id, provider.model)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        try await body(app, SessionStore(folder: folder, defaults: defaults))
    }

    private func waitForTask(_ chat: ChatModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.running && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.running)
    }

    func testRestoredSavedChatSendsItsPersistedIdentityThroughChatModel() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("First answer."), FakeCompletions.text("Reopened answer.")])
        try await withRoutingFixture { app, store in
            let model = self.fixtureModel(server)
            let chat = ChatModel(app: app, store: store, resolveModel: { _, _ in model })
            defer { chat.stop() }
            chat.newConversation()
            chat.send("First synthetic request.")
            try await self.waitForTask(chat)
            let originalID = chat.sessionID
            let saved = try XCTUnwrap(store.session(originalID))
            let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(saved))
            chat.newConversation()
            XCTAssertNotEqual(chat.sessionID, originalID)
            chat.restore(restored)
            XCTAssertEqual(chat.sessionID, originalID)
            let before = server.requestHeaders.count
            chat.send("Second synthetic request.")
            try await self.waitForTask(chat)
            let headers = Array(server.requestHeaders.dropFirst(before))
            XCTAssertFalse(headers.isEmpty)
            XCTAssertTrue(headers.allSatisfy { $0["x-opencode-session"] == originalID }, "\(headers)")
            XCTAssertTrue(chat.entries.contains { if case .poki("Reopened answer.") = $0.kind { return true }; return false })
        }
    }

    func testTryAgainKeepsOriginalOutgoingChatIdentity() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Rejected"), FakeCompletions.text("Recovered answer.")],
                                         responseStatuses: [400, 200])
        try await withRoutingFixture { app, store in
            let model = self.fixtureModel(server)
            let chat = ChatModel(app: app, store: store, resolveModel: { _, _ in model })
            defer { chat.stop() }
            chat.newConversation()
            let id = chat.sessionID
            chat.send("Synthetic retry request.")
            try await self.waitForTask(chat)
            XCTAssertTrue(chat.canRetry, "The failed send must expose the real Try Again action")
            XCTAssertEqual(server.requests.count, 1)
            // Same method wired to ChatTranscript's user-facing Try Again button.
            chat.retry()
            try await self.waitForTask(chat)
            XCTAssertEqual(server.requests.count, 2)
            XCTAssertFalse(chat.canRetry)
            XCTAssertEqual(chat.sessionID, id)
            XCTAssertTrue(chat.entries.contains { if case .poki("Recovered answer.") = $0.kind { return true }; return false })
            XCTAssertGreaterThanOrEqual(server.requestHeaders.count, 2)
            XCTAssertTrue(server.requestHeaders.allSatisfy { $0["x-opencode-session"] == id })
        }
    }

    func testApprovalClassifierUsesLiveChatIDButIdleChatGetsApprovalID() async throws {
        let received = expectation(description: "Live chat request reached its transport")
        let liveServer = try FakeCompletions(replies: [FakeCompletions.text("Held reply.")], holdFirstReply: { received.fulfill() })
        let approvals = try FakeCompletions(replies: [FakeCompletions.text("REFUSE: fixture"), FakeCompletions.text("REFUSE: fixture")])
        try await withRoutingFixture { app, store in
            let model = self.fixtureModel(liveServer)
            let approvalModel = self.fixtureModel(approvals)
            let chat = ChatModel(app: app, store: store, resolveModel: { _, _ in model })
            let originalApp = AskPoki.app
            let originalChat = AskPoki.chat
            AskPoki.install(app: app, chat: chat)
            defer {
                chat.stop()
                if let originalApp, let originalChat { AskPoki.install(app: originalApp, chat: originalChat) }
            }
            chat.newConversation()
            chat.send("Synthetic owner request.")
            await self.fulfillment(of: [received], timeout: 5)
            XCTAssertTrue(chat.running)
            let live = PendingApproval(id: UUID().uuidString, app: "Phone", summary: "Synthetic call", reason: "a call", expires: .now.addingTimeInterval(60))
            _ = await ApprovalClassifier.decide(live, level: .strict, voice: [], resolveModel: { _, _ in approvalModel })
            XCTAssertEqual(approvals.requestHeaders.first?["x-opencode-session"], chat.sessionID)
            chat.stop()
            try await self.waitForTask(chat)
            let idle = PendingApproval(id: UUID().uuidString, app: "Phone", summary: "Synthetic call", reason: "a call", expires: .now.addingTimeInterval(60))
            _ = await ApprovalClassifier.decide(idle, level: .strict, voice: [], resolveModel: { _, _ in approvalModel })
            XCTAssertEqual(approvals.requestHeaders.count, 2)
            XCTAssertEqual(approvals.requestHeaders.last?["x-opencode-session"], "approval-\(idle.id)")
        }
    }

    /// An externally handed-over task is a separate saved conversation. Its network
    /// identity must not come from the on-screen owner chat (or from the MCP caller ID).
    func testOutsideAgentTaskSendsItsOwnConversationID() async throws {
        let ownerServer = try FakeCompletions(replies: [FakeCompletions.text("Owner answer.")])
        let externalServer = try FakeCompletions(replies: [FakeCompletions.text("External answer.")])
        try await withRoutingFixture { app, store in
            let owner = ChatModel(app: app, store: store, resolveModel: { _, _ in self.fixtureModel(ownerServer) })
            defer { owner.stop() }
            owner.newConversation()
            let ownerID = owner.sessionID
            owner.send("Owner request in the on-screen conversation.")
            try await self.waitForTask(owner)
            XCTAssertEqual(ownerServer.requestHeaders.first?["x-opencode-session"], ownerID)

            // The same creation path as AskPoki.run, but isolated from global MCP state.
            let outsideID = store.handoffID(for: "external-fixture-session")
            XCTAssertNotEqual(outsideID, ownerID)
            let handoff = ChatModel(app: app, kind: .handoff, requester: "Synthetic external agent",
                                    sessionID: outsideID, store: store,
                                    resolveModel: { _, _ in self.fixtureModel(externalServer) })
            defer { handoff.stop() }
            _ = await handoff.runDelegated("A synthetic task started from outside the chat.")
            XCTAssertEqual(handoff.sessionID, outsideID)
            XCTAssertEqual(owner.sessionID, ownerID)
            XCTAssertFalse(externalServer.requestHeaders.isEmpty, "The handoff must send a real PiSwift HTTP request")
            XCTAssertTrue(externalServer.requestHeaders.allSatisfy { $0["x-opencode-session"] == outsideID })
            XCTAssertFalse(externalServer.requestHeaders.contains { $0["x-opencode-session"] == ownerID })
        }
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
