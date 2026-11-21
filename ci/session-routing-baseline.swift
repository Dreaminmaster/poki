import XCTest
@testable import Poki

/// Test-only probes applied to the unmodified merge-base product source by the fork CI.
/// They must FAIL because old ChatModel did not forward saved session IDs to PiSwift.
/// No application source changes are made during this baseline run.
@MainActor
final class SessionRoutingBaselineTests: XCTestCase {
    private func fixture(_ body: (AppModel, SessionStore) async throws -> Void) async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "pokiChat",
                    CustomProviders.storeKey, CustomProviders.selectedKey, "chat.model.custom",
                    "models.enabled.custom"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PokiRoutingBaseline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        defer {
            URLProtocol.unregisterClass(ModelServerStub.self)
            ModelServerStub.clear()
            for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temp)
        }
        UserDefaults.standard.removeObject(forKey: "pokiChat")
        let endpoint = CustomProvider(endpoints: [
            CustomEndpoint(url: "https://opencode.ai/v1", api: .chatCompletions)
        ], model: "baseline-fixture")
        let provider = CustomProviders.upsert(endpoint)
        ModelKeys.selectedProvider = .custom
        ModelKeys.selectedModel = CustomProviders.choiceID(provider.id, provider.model)
        ModelServerStub.responder = { _, _ in
            (200, "text/event-stream", FakeCompletions.text("Baseline answer."))
        }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        try await body(app, SessionStore(folder: temp, defaults: defaults))
    }

    private func outgoing(_ marker: String) -> [ModelServerStub.Sent] {
        ModelServerStub.requests.filter { sent in
            let payload = String(decoding: sent.body, as: UTF8.self)
            return payload.contains(marker) && !payload.contains("You name chat conversations")
        }
    }

    private func finish(_ chat: ChatModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.running && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.running)
    }

    func testRestoredChatMustSendSavedRoutingHeader() async throws {
        try await fixture { app, store in
            let chat = ChatModel(app: app, store: store)
            defer { chat.stop() }
            chat.newConversation()
            chat.send("Baseline first message.")
            try await self.finish(chat)
            let id = chat.sessionID
            let saved = try XCTUnwrap(store.session(id))
            let roundtrip = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(saved))
            chat.newConversation()
            chat.restore(roundtrip)
            chat.send("Baseline restored message.")
            try await self.finish(chat)
            let packets = self.outgoing("Baseline restored message.")
            XCTAssertFalse(packets.isEmpty, "restored request never reached the actual HTTP transport")
            XCTAssertEqual(packets.last?.headers["x-opencode-session"], id,
                           "missing x-opencode-session for restored chat on merge base")
        }
    }

    func testAppTryAgainMustSendOriginalRoutingHeader() async throws {
        try await fixture { app, store in
            ModelServerStub.responder = { _, body in
                let payload = String(decoding: body, as: UTF8.self)
                let matching = payload.contains("Baseline retry message.")
                    && !payload.contains("You name chat conversations")
                let count = ModelServerStub.requests.filter { item in
                    let bytes = String(decoding: item.body, as: UTF8.self)
                    return bytes.contains("Baseline retry message.")
                        && !bytes.contains("You name chat conversations")
                }.count
                if matching && count == 1 {
                    return (400, "application/json", #"{"error":{"message":"Synthetic failure"}}"#)
                }
                return (200, "text/event-stream", FakeCompletions.text("Recovered."))
            }
            let chat = ChatModel(app: app, store: store)
            defer { chat.stop() }
            chat.newConversation()
            let id = chat.sessionID
            chat.send("Baseline retry message.")
            try await self.finish(chat)
            XCTAssertTrue(chat.canRetry, "the app's real Try Again action must be enabled")
            chat.retry()
            try await self.finish(chat)
            let packets = self.outgoing("Baseline retry message.")
            XCTAssertEqual(packets.count, 2, "both initial and retried requests must reach HTTP transport")
            XCTAssertEqual(packets.last?.headers["x-opencode-session"], id,
                           "missing x-opencode-session on Try Again on merge base")
        }
    }
}
