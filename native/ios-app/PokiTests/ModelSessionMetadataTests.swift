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

    /// Exercise the production fallback HTTP transport, not just the header helper:
    /// a 503 response moves the same request to a second, unrelated gateway.
    func testActualHTTPFallbackDoesNotLeakOpenCodeSessionToBackup() async throws {
        let primary = try FakeCompletions(replies: [FakeCompletions.text("Primary unavailable")],
                                          responseStatuses: [503])
        let backup = try FakeCompletions(replies: [FakeCompletions.text("Backup answer")])
        let originalBase = "http://127.0.0.1:\(primary.port)/v1"
        let backupBase = "http://127.0.0.1:\(backup.port)/v1"
        let client = CustomEndpointClient(primary: originalBase, backups: [backupBase],
                                          conversationSessionID: "own-saved-chat")
        var request = URLRequest(url: try XCTUnwrap(URL(string: originalBase + "/chat/completions")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("stale-other-chat", forHTTPHeaderField: "x-opencode-session")
        request.setValue("Poki", forHTTPHeaderField: "x-opencode-client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "fixture", "messages": [["role": "user", "content": "Hello"]], "stream": true
        ])

        let response = try await client.send(request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(primary.requests.count, 1)
        XCTAssertEqual(backup.requests.count, 1, "A real HTTP 503 must reach the fallback endpoint")
        XCTAssertEqual(primary.requestHeaders.first?["x-opencode-session"], "stale-other-chat")
        XCTAssertNil(backup.requestHeaders.first?["x-opencode-session"])
        XCTAssertNil(backup.requestHeaders.first?["x-opencode-client"])
        XCTAssertEqual(backup.requests.first?["model"] as? String, "fixture")
    }

    func testRequestIdentityUsesTheRealPokiProductName() {
        let identity = PiLoop.clientIdentity(version: "0.4.0")
        XCTAssertEqual(formatUserAgent(identity: identity), "Poki/0.4.0")
        XCTAssertEqual(identity.attribution,
                       .value(ClientAttribution(name: "Poki", url: "https://github.com/JosssphZhou/poki")))
        XCTAssertEqual(formatUserAgent(identity: PiLoop.clientIdentity(version: " ")), "Poki/dev")
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

    /// Paired loopback measurements isolate the cost of routing metadata from the
    /// same request and model. This is diagnostic evidence, not a latency threshold.
    func testOpenCodeRoutingMetadataPairedStepTiming() async throws {
        let samples = 12
        let server = try FakeCompletions(replies: Array(repeating: FakeCompletions.text("OK"), count: samples * 2))
        let model = Model(id: "timing-fixture", name: "Timing fixture", api: .openAICompletions,
                          provider: "opencode-go", baseUrl: "http://127.0.0.1:\(server.port)/v1",
                          reasoning: false, input: [.text],
                          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1_000, maxTokens: 100)
        func step(_ id: String) async -> Double {
            let loop = PiLoop(provider: .custom, model: model, sessionID: id, tools: []) { _ in
                .init(text: "No tools", jpeg: nil, isError: true)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let outcome = await loop.run("Reply OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
            XCTAssertEqual(outcome, .done)
            return (ProcessInfo.processInfo.systemUptime - started) * 1_000
        }
        var without: [Double] = []
        var withHeader: [Double] = []
        let session = "01234567-89ab-cdef-0123-456789abcdef"
        for _ in 0..<samples {
            without.append(await step(""))
            withHeader.append(await step(session))
        }
        func median(_ values: [Double]) -> Double {
            let ordered = values.sorted()
            return (ordered[(ordered.count - 1) / 2] + ordered[ordered.count / 2]) / 2
        }
        let headers = server.requestHeaders
        XCTAssertEqual(headers.count, samples * 2)
        for i in 0..<samples {
            XCTAssertNil(headers[i * 2]["x-opencode-session"])
            XCTAssertEqual(headers[i * 2 + 1]["x-opencode-session"], session)
        }
        print(String(format: "Poki routing metadata step benchmark: n=%d paired, baseline median %.2f ms, with OpenCode header median %.2f ms, delta %.2f ms (loopback, no physical iPhone)",
                     samples, median(without), median(withHeader), median(withHeader) - median(without)))
    }

    /// Production-configured model, real ChatModel/ApprovalClassifier, and URLProtocol
    /// interception. No fabricated Model resolver or model-only test initializer.
    private func withRoutingFixture(_ body: (AppModel, SessionStore) async throws -> Void) async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "pokiChat",
                    CustomProviders.storeKey, CustomProviders.selectedKey, "chat.model.custom", "models.enabled.custom",
                    ApprovalClassifier.modeKey, ApprovalClassifier.levelKey]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ModelSessionMetadataTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        defer {
            URLProtocol.unregisterClass(ModelServerStub.self)
            ModelServerStub.clear()
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        UserDefaults.standard.removeObject(forKey: "pokiChat")
        UserDefaults.standard.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
        UserDefaults.standard.set(ApprovalClassifier.Level.balanced.rawValue, forKey: ApprovalClassifier.levelKey)
        let provider = CustomProviders.upsert(CustomProvider(
            endpoints: [CustomEndpoint(url: "https://opencode.ai/v1", api: .chatCompletions)],
            model: "routing-fixture"
        ))
        ModelKeys.selectedProvider = .custom
        ModelKeys.selectedModel = CustomProviders.choiceID(provider.id, provider.model)
        // Exactly the configured custom model is sent through URLSession. This host is
        // intercepted in-process; no external OpenCode request or real credential is used.
        ModelServerStub.responder = { _, _ in
            (200, "text/event-stream", FakeCompletions.text("Fixture answer."))
        }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        try await body(app, SessionStore(folder: folder, defaults: defaults))
    }

    private func actualChatRequests(containing marker: String) -> [ModelServerStub.Sent] {
        ModelServerStub.requests.filter {
            let body = String(decoding: $0.body, as: UTF8.self)
            return body.contains(marker) && !body.contains("You name chat conversations")
        }
    }

    private func waitForTask(_ chat: ChatModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.running && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.running)
    }

    func testRestoredChatAndFreshChatUseOutgoingIDsFromRealModelConfiguration() async throws {
        try await withRoutingFixture { app, store in
            let chat = ChatModel(app: app, store: store)
            defer { chat.stop() }
            chat.newConversation()
            let firstID = chat.sessionID
            chat.send("First synthetic request.")
            try await self.waitForTask(chat)
            XCTAssertEqual(self.actualChatRequests(containing: "First synthetic request.").last?.headers["x-opencode-session"], firstID)

            let persisted = try XCTUnwrap(store.session(firstID))
            let roundTrip = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(persisted))
            chat.newConversation()
            XCTAssertNotEqual(chat.sessionID, firstID)
            chat.restore(roundTrip)
            XCTAssertEqual(chat.sessionID, firstID)
            chat.send("Second synthetic request.")
            try await self.waitForTask(chat)
            XCTAssertEqual(self.actualChatRequests(containing: "Second synthetic request.").last?.headers["x-opencode-session"], firstID)

            chat.newConversation()
            let nextID = chat.sessionID
            XCTAssertNotEqual(nextID, firstID)
            chat.send("Third synthetic request.")
            try await self.waitForTask(chat)
            XCTAssertEqual(self.actualChatRequests(containing: "Third synthetic request.").last?.headers["x-opencode-session"], nextID)
        }
    }

    func testAppTryAgainUsesOriginalOutgoingSessionIDWithRealModelConfiguration() async throws {
        try await withRoutingFixture { app, store in
            ModelServerStub.responder = { _, body in
                let text = String(decoding: body, as: UTF8.self)
                let target = text.contains("Synthetic retry request.") && !text.contains("You name chat conversations")
                let seen = ModelServerStub.requests.filter { sent in
                    let content = String(decoding: sent.body, as: UTF8.self)
                    return content.contains("Synthetic retry request.") && !content.contains("You name chat conversations")
                }.count
                if target && seen == 1 {
                    return (400, "application/json", #"{"error":{"message":"Synthetic first-send rejection"}}"#)
                }
                return (200, "text/event-stream", FakeCompletions.text("Recovered answer."))
            }
            let chat = ChatModel(app: app, store: store)
            defer { chat.stop() }
            chat.newConversation()
            let id = chat.sessionID
            chat.send("Synthetic retry request.")
            try await self.waitForTask(chat)
            XCTAssertTrue(chat.canRetry, "The app must show the real Try Again action")
            let first = self.actualChatRequests(containing: "Synthetic retry request.")
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.first?.headers["x-opencode-session"], id)
            chat.retry()
            try await self.waitForTask(chat)
            let actual = self.actualChatRequests(containing: "Synthetic retry request.")
            XCTAssertEqual(actual.count, 2)
            XCTAssertFalse(chat.canRetry)
            XCTAssertEqual(chat.sessionID, id)
            XCTAssertTrue(actual.allSatisfy { $0.headers["x-opencode-session"] == id })
        }
    }

    func testOutsideAgentApprovalDoesNotBorrowAnActiveOwnerChat() async throws {
        try await withRoutingFixture { app, store in
            let owner = ChatModel(app: app, store: store)
            defer { owner.stop() }
            owner.newConversation()
            let originalApp = AskPoki.app
            let originalChat = AskPoki.chat
            AskPoki.install(app: app, chat: owner)
            defer { if let originalApp, let originalChat { AskPoki.install(app: originalApp, chat: originalChat) } }

            let owned = PendingApproval(id: UUID().uuidString, app: "Phone",
                                        summary: "Synthetic owned action", reason: "a call",
                                        expires: .now.addingTimeInterval(60))
            let ownerOrigin = ApprovalClassifier.Origin.chat(owner.sessionID)
            XCTAssertEqual(ApprovalClassifier.route(owned, voiceOn: false, origin: ownerOrigin), .model(reply: false))
            _ = await ApprovalClassifier.decide(owned, level: .strict, voice: [], origin: ownerOrigin)
            XCTAssertEqual(ModelServerStub.requests.last?.headers["x-opencode-session"], owner.sessionID)
            let before = ModelServerStub.requests.count

            let outside = PendingApproval(id: UUID().uuidString, app: "Phone",
                                          summary: "Synthetic external action", reason: "a call",
                                          expires: .now.addingTimeInterval(60))
            let external = ApprovalClassifier.Origin.outsideAgent("mcp-external-session")
            XCTAssertEqual(ApprovalClassifier.route(outside, voiceOn: false, origin: external), .owner)
            let verdict = await ApprovalClassifier.decide(outside, level: .strict, voice: [], origin: external)
            XCTAssertFalse(verdict.allowed)
            XCTAssertEqual(ModelServerStub.requests.count, before, "An outside request must not invoke the owner's model context")
            XCTAssertEqual(ApprovalClassifier.origin(voiceOn: false, outsideSession: "mcp-external-session"), external)
        }
    }

    func testExternallyDelegatedTaskUsesItsOwnConfiguredModelConversation() async throws {
        try await withRoutingFixture { app, store in
            let owner = ChatModel(app: app, store: store)
            defer { owner.stop() }
            owner.newConversation()
            let ownerID = owner.sessionID
            owner.send("Owner request in the on-screen conversation.")
            try await self.waitForTask(owner)
            XCTAssertEqual(self.actualChatRequests(containing: "Owner request in the on-screen conversation.").last?.headers["x-opencode-session"], ownerID)

            let outsideID = store.handoffID(for: "external-fixture-session")
            XCTAssertNotEqual(outsideID, ownerID)
            let handoff = ChatModel(app: app, kind: .handoff, requester: "Synthetic external agent",
                                    sessionID: outsideID, store: store)
            defer { handoff.stop() }
            _ = await handoff.runDelegated("A synthetic task started from outside the chat.")
            let requests = self.actualChatRequests(containing: "A synthetic task started from outside the chat.")
            XCTAssertFalse(requests.isEmpty, "A real PiSwift request must leave the delegated ChatModel")
            XCTAssertTrue(requests.allSatisfy { $0.headers["x-opencode-session"] == outsideID })
            XCTAssertFalse(requests.contains { $0.headers["x-opencode-session"] == ownerID })
            XCTAssertEqual(owner.sessionID, ownerID)
            XCTAssertEqual(handoff.sessionID, outsideID)
        }
    }
}
