import XCTest
@testable import Poki

@MainActor
final class CustomModelDiscoveryTests: XCTestCase {
    private let address = "https://model-server.test/v1"
    private let defaultsKeys = ["chat.customURL", "chat.customModel", "chat.provider", "chat.model.custom",
                                "models.listed.custom", "models.enabled.custom", "models.revision.custom",
                                "custom.providers", "chat.customProvider"]
    private var savedDefaults: [String: Any] = [:]
    private var savedKey: String?
    private var session: URLSession!

    override func setUp() {
        savedKey = nil
        savedDefaults = [:]
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelServerStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.clear()
        for provider in CustomProviders.all { CustomProviders.removeKey(provider.id) }
        _ = savedKey
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testRequestPreservesBasePathAndOptionalAuthentication() throws {
        for base in [address, address + "/", "  " + address + "/\n"] {
            let request = try ModelCatalog.customRequest(address: base, key: " test-key ")
            XCTAssertEqual(request.url?.absoluteString, address + "/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.httpMethod, "GET")
        }
        let request = try ModelCatalog.customRequest(address: "http://model-server.test/gateway/api", key: nil)
        XCTAssertEqual(request.url?.path, "/gateway/api/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for invalid in ["", "file:///tmp/models", "https:///", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret"] {
            XCTAssertThrowsError(try ModelCatalog.customRequest(address: invalid, key: nil))
        }
    }

    func testDraftFetchParsesAndDeduplicatesWithoutSaving() async throws {
        ModelServerStub.answer = (200, #"{"data":[{"id":"z-model"},{"id":"fast-mini"},{"id":"z-model"},{"id":" "},{"id":"embedding-model"}]}"#)
        let models = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(models, ["fast-mini", "z-model"])
        XCTAssertTrue(ModelKeys.customURL.isEmpty)
        XCTAssertTrue(ModelKeys.customModel.isEmpty)
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(ModelServerStub.requests.count, 1)
        XCTAssertTrue(ModelServerStub.requests[0].body.isEmpty)
    }

    func testCompatibleAndEmptyResponses() async throws {
        ModelServerStub.answer = (200, #"{"models":[{"name":"models/custom-chat"},{"id":"other"}]}"#)
        let compatible = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(compatible, ["custom-chat", "other"])
        ModelServerStub.answer = (200, #"{"data":[]}"#)
        let empty = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(empty, [])
    }

    /// The current custom provider's id, after `ModelKeys.customURL` made it.
    private var currentID: UUID { CustomProviders.current!.id }

    private func listedModels() -> [String] {
        ModelCatalog.listed(.custom).compactMap { CustomProviders.parse($0.id)?.model }
    }

    func testMalformedResponseDoesNotEraseCache() async throws {
        ModelKeys.customURL = address
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom.\(currentID.uuidString)")
        for body in ["not json", "{}", #"{"data":{}}"#, #"{"data":[1]}"#] {
            ModelServerStub.answer = (200, body)
            do {
                _ = try await ModelCatalog.refresh(.custom)
                XCTFail("Malformed response accepted: \(body)")
            } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, .malformed) }
            XCTAssertEqual(listedModels(), ["saved-model"])
        }
    }

    func testHTTPFailuresAndTimeoutAreClassified() async {
        let cases: [(Int, ModelCatalog.DiscoveryError)] = [
            (401, .authentication), (403, .permission), (404, .unsupported),
            (405, .unsupported), (429, .rateLimited), (500, .server)
        ]
        for (status, expected) in cases {
            ModelServerStub.answer = (status, "private upstream response")
            do {
                _ = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
                XCTFail("HTTP \(status) accepted")
            } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, expected) }
        }
        ModelServerStub.answer = nil
        do {
            _ = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
            XCTFail("Timeout accepted")
        } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, .network) }
    }

    func testAddressChangeDoesNotReuseSavedKeyAndSaveSelectsModel() throws {
        ModelKeys.customURL = address
        try ModelKeys.save("old-test-key", for: .custom)
        XCTAssertEqual(ModelKeys.customDraftKey(address: address + "/", typedKey: ""), "old-test-key")
        let changed = "https://model-server.test/other/v1"
        XCTAssertNil(ModelKeys.customDraftKey(address: changed, typedKey: ""))
        XCTAssertEqual(ModelKeys.customDraftKey(address: changed, typedKey: "new-test-key"), "new-test-key")
        UserDefaults.standard.set(["old-model"], forKey: "models.listed.custom.\(currentID.uuidString)")
        try ModelKeys.saveCustom(address: changed, model: "chosen-model", typedKey: "")
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(ModelKeys.selectedProvider, .custom)
        XCTAssertEqual(CustomProviders.parse(ModelKeys.selectedModel)?.model, "chosen-model")
        XCTAssertTrue(ModelCatalog.enabled(.custom).contains(ModelKeys.selectedModel))
    }

    func testSavingUnchangedKeylessServicePreservesItsList() throws {
        ModelKeys.customURL = address
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom.\(currentID.uuidString)")
        try ModelKeys.saveCustom(address: address + "/", model: "saved-model", typedKey: "")
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertEqual(listedModels(), ["saved-model"])
        XCTAssertEqual(CustomProviders.parse(ModelKeys.selectedModel)?.model, "saved-model")
    }

    func testReplacingKeyInvalidatesCacheButUnchangedKeyDoesNot() throws {
        ModelKeys.customURL = address
        try ModelKeys.save("old-test-key", for: .custom)
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom.\(currentID.uuidString)")
        try ModelKeys.saveCustom(address: address, model: "saved-model", typedKey: "")
        XCTAssertEqual(listedModels(), ["saved-model"])
        try ModelKeys.saveCustom(address: address, model: "new-model", typedKey: "new-test-key")
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(CustomProviders.parse(ModelKeys.selectedModel)?.model, "new-model")
    }

    func testChangedConfigurationRejectsInFlightRefresh() async throws {
        ModelKeys.customURL = address
        ModelServerStub.responder = { _, _ in
            // Even an address changed away and back must invalidate the response.
            ModelCatalog.invalidateCustom()
            return (200, "application/json", #"{"data":[{"id":"stale-model"}]}"#)
        }
        do {
            _ = try await ModelCatalog.refresh(.custom)
            XCTFail("Stale response accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
    }

    // MARK: Several providers, several addresses

    func testChoiceIDsKeepProviderAndModelWithColons() {
        let id = UUID()
        let choice = CustomProviders.choiceID(id, "llama3:8b")
        XCTAssertEqual(CustomProviders.parse(choice)?.provider, id)
        XCTAssertEqual(CustomProviders.parse(choice)?.model, "llama3:8b")
        XCTAssertNil(CustomProviders.parse("llama3:8b"))
        XCTAssertNil(CustomProviders.parse("custom:not-a-uuid:model"))
        XCTAssertNil(CustomProviders.parse(CustomProviders.choiceID(id, "")))
    }

    func testTwoProvidersKeepTheirOwnModelsKeysAndAddresses() throws {
        let first = CustomProvider(name: "Gateway", endpoints: [CustomEndpoint(url: address, api: .responses)], model: "shared-model")
        let second = CustomProvider(name: "Local", endpoints: [CustomEndpoint(url: "http://model-server.test/local/v1")], model: "shared-model")
        try ModelKeys.saveCustom(first, typedKey: "first-test-key", keepKey: false)
        try ModelKeys.saveCustom(second, typedKey: "", keepKey: false)
        XCTAssertEqual(CustomProviders.all.count, 2)
        let choices = ModelProvider.custom.models
        XCTAssertEqual(Set(choices.map(\.name)), ["shared-model (Gateway)", "shared-model (Local)"])
        // The last saved is the chat's.
        XCTAssertEqual(CustomProviders.parse(ModelKeys.selectedModel)?.provider, second.id)
        XCTAssertNil(ModelKeys.key(.custom))
        ModelKeys.selectedModel = CustomProviders.choiceID(first.id, "shared-model")
        XCTAssertEqual(ModelKeys.key(.custom), "first-test-key")
        let model = try XCTUnwrap(ModelProvider.custom.piModel(ModelKeys.selectedModel))
        XCTAssertEqual(model.api, .openAIResponses)
        XCTAssertEqual(model.baseUrl, address)
        XCTAssertEqual(CustomProviders.provider(piProvider: model.provider)?.id, first.id)
        CustomProviders.remove(first.id)
        XCTAssertEqual(CustomProviders.all.map(\.id), [second.id])
        XCTAssertNil(CustomProviders.key(first.id))
        XCTAssertEqual(CustomProviders.parse(ModelKeys.selectedModel)?.provider, second.id)
    }

    func testBackupsAreTheLaterAddressesInTheSameAPI() {
        let provider = CustomProvider(endpoints: [
            CustomEndpoint(url: address, api: .responses),
            CustomEndpoint(url: "https://backup.test/v1", api: .responses),
            CustomEndpoint(url: "https://chat-only.test/v1", api: .chatCompletions),
            CustomEndpoint(url: "  "),
        ])
        XCTAssertEqual(provider.primary?.normalized, address)
        XCTAssertEqual(provider.backups.map(\.normalized), ["https://backup.test/v1"])
    }

    func testDeletingAnotherServiceKeepsTheCurrentService() throws {
        let first = CustomProvider(endpoints: [CustomEndpoint(url: address)], model: "first")
        let removed = CustomProvider(endpoints: [CustomEndpoint(url: address)], model: "removed")
        let current = CustomProvider(endpoints: [CustomEndpoint(url: address)], model: "current")
        for provider in [first, removed, current] { try ModelKeys.saveCustom(provider, typedKey: "", keepKey: false) }

        CustomProviders.remove(removed.id)

        XCTAssertEqual(CustomProviders.all.map(\.id), [first.id, current.id])
        XCTAssertEqual(ModelKeys.selectedModel, CustomProviders.choiceID(current.id, "current"))
    }

    func testRequestsMoveToTheNextAddressWithItsOwnAPIPath() {
        let moved = CustomEndpointClient.moved(URL(string: address + "/responses"), from: address, to: "https://backup.test/gateway/v1/")
        XCTAssertEqual(moved?.absoluteString, "https://backup.test/gateway/v1/responses")
        // pi adds /v1 to an address without a path; a backup that ends in /v1 does not get it twice.
        let bare = CustomEndpointClient.moved(URL(string: "https://model-server.test/v1/responses"), from: "https://model-server.test", to: "https://backup.test/v1")
        XCTAssertEqual(bare?.absoluteString, "https://backup.test/v1/responses")
        let toBare = CustomEndpointClient.moved(URL(string: address + "/responses"), from: address, to: "https://backup.test")
        XCTAssertEqual(toBare?.absoluteString, "https://backup.test/v1/responses")
        let toGateway = CustomEndpointClient.moved(URL(string: "https://model-server.test/v1/responses"), from: "https://model-server.test", to: "https://backup.test/gateway")
        XCTAssertEqual(toGateway?.absoluteString, "https://backup.test/gateway/responses")
        let completions = CustomEndpointClient.moved(URL(string: address + "/chat/completions"), from: address, to: "https://backup.test")
        XCTAssertEqual(completions?.absoluteString, "https://backup.test/chat/completions")
        XCTAssertNil(CustomEndpointClient.moved(URL(string: "https://elsewhere.test/v1/responses"), from: address, to: "https://backup.test/v1"))
    }

    func testAutomaticUsesWhatTheTestFoundAndForgetsItWhenTheAddressChanges() {
        var endpoint = CustomEndpoint(url: address)
        XCTAssertEqual(endpoint.sent, .chatCompletions)
        endpoint.found = .responses
        XCTAssertEqual(endpoint.sent, .responses)
        var provider = CustomProviders.upsert(CustomProvider(endpoints: [endpoint], model: "m"))
        XCTAssertEqual(CustomProviders.provider(provider.id)?.primary?.sent, .responses)
        provider.endpoints[0].url = "https://model-server.test/other/v1"
        CustomProviders.upsert(provider)
        XCTAssertNil(CustomProviders.provider(provider.id)?.primary?.found)
        CustomProviders.record(found: .chatCompletions, endpoint: provider.endpoints[0], provider: provider.id)
        XCTAssertEqual(CustomProviders.provider(provider.id)?.primary?.sent, .chatCompletions)
    }

    func testDiscardingAProbedDraftModelLeavesTheSavedModelAbleToChat() async throws {
        let endpoint = CustomEndpoint(url: address, found: .chatCompletions)
        let saved = CustomProvider(endpoints: [endpoint], model: "original-model")
        try ModelKeys.saveCustom(saved, typedKey: "", keepKey: false)
        let reply = #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"original-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Original model replied."},"finish_reason":"stop"}]}"#
        ModelServerStub.responder = { request, body in
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            switch (request.url?.path, json?["model"] as? String) {
            case ("/v1/responses", "draft-model"):
                return (200, "text/event-stream", #"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n\n")
            case ("/v1/chat/completions", "original-model"):
                return (200, "text/event-stream", "data: \(reply)\n\ndata: [DONE]\n\n")
            default:
                return (404, "application/json", #"{"error":{"message":"This model does not support this API."}}"#)
            }
        }

        var draft = saved
        draft.model = "draft-model"
        let probe = await CustomProviders.testConnection(to: endpoint, key: "", draft: draft)
        XCTAssertTrue(probe.result.passed)
        XCTAssertEqual(probe.api, .responses)

        let model = try XCTUnwrap(ModelProvider.custom.piModel(ModelKeys.selectedModel))
        let loop = PiLoop(provider: .custom, model: model, tools: []) { _ in
            .init(text: "", jpeg: nil, isError: false)
        }
        var messages: [String] = []
        let outcome = await loop.run("Say which model answered.", instructions: "Be brief.", maxTurns: 1) { messages.append($0) }
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(messages, ["Original model replied."])
    }

    func testOfficialModelIdsTakeTheCatalogSetupAndTheOwnerChoiceWins() throws {
        let known = ModelProvider.customModel("openai/gpt-6.1-sol", baseUrl: address, api: .openAIResponses, reasoning: nil)
        let official = try XCTUnwrap(ModelProvider.openai.piModel("gpt-6.1-sol"))
        XCTAssertEqual(known.reasoning, official.reasoning)
        XCTAssertEqual(known.contextWindow, official.contextWindow)
        XCTAssertEqual(known.maxTokens, official.maxTokens)
        XCTAssertEqual(known.baseUrl, address)
        let off = ModelProvider.customModel("gpt-6.1-sol", baseUrl: address, api: .openAIResponses, reasoning: false)
        XCTAssertFalse(off.reasoning)
        let unknown = ModelProvider.customModel("house-model", baseUrl: address, api: .openAICompletions, reasoning: nil)
        XCTAssertFalse(unknown.reasoning)
        XCTAssertEqual(unknown.contextWindow, 128_000)
        let thinking = ModelProvider.customModel("house-model", baseUrl: address, api: .openAICompletions, reasoning: true)
        XCTAssertTrue(thinking.reasoning)
        XCTAssertEqual(thinking.maxTokens, 32_768)
    }

    /// Live voice on a custom provider: one account at a time, its Realtime key asked of its own first
    /// address, without a key header when it has none, and the key names that address for the call.
    func testLiveVoiceRequestsACustomServiceClientSecret() async throws {
        let openAIVoice = UserDefaults.standard.object(forKey: "voice.openai.enabled")
        defer { UserDefaults.standard.set(openAIVoice, forKey: "voice.openai.enabled") }
        let provider = CustomProviders.upsert(CustomProvider(endpoints: [CustomEndpoint(url: address)], model: "m"))
        VoiceDirect.set(.custom(provider.id), on: true)
        XCTAssertEqual(VoiceDirect.account, .custom(provider.id))
        XCTAssertFalse(VoiceDirect.isOn(.openai))
        XCTAssertEqual(VoiceDirect.apiKey, "")
        ModelServerStub.responder = { request, _ in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, "application/json", #"{"value":"ek_test"}"#)
        }
        let token = try await VoiceDirect.token(apiKey: "")
        XCTAssertEqual(token.value, "ek_test")
        XCTAssertEqual(token.base, address)
        XCTAssertEqual(ModelServerStub.requests.first?.url?.absoluteString, address + "/realtime/client_secrets")
        VoiceDirect.set(.openai, on: true)
        XCTAssertFalse(VoiceDirect.isOn(.custom(provider.id)))
    }

    func testTheSingleOldEndpointMigratesAfterItsKeyBecomesReadable() throws {
        let legacyAccount = "model-key.custom"
        let backup = try Keychain.read(legacyAccount)
        defer {
            if let backup { try? Keychain.write(backup, account: legacyAccount) }
            else { Keychain.delete(legacyAccount) }
        }
        try Keychain.write(Data([0xFF]), account: legacyAccount)
        UserDefaults.standard.set(address, forKey: "chat.customURL")
        UserDefaults.standard.set("old-model", forKey: "chat.customModel")
        UserDefaults.standard.set(["old-model", "listed-model"], forKey: "models.enabled.custom")
        UserDefaults.standard.set(["listed-model"], forKey: "models.listed.custom")
        UserDefaults.standard.set("listed-model", forKey: "chat.model.custom")
        ModelKeys.selectedProvider = .custom
        XCTAssertFalse(ModelKeys.hasUsableKey, "The old service must wait for its key before becoming usable")

        let credential = "fixture-legacy-key"
        try Keychain.write(Data(credential.utf8), account: legacyAccount)
        XCTAssertTrue(ModelKeys.hasUsableKey)
        XCTAssertTrue(ModelKeys.key(.custom) == credential, "The migrated service must use the legacy key")
        let providers = CustomProviders.all
        XCTAssertEqual(providers.count, 1)
        let provider = try XCTUnwrap(providers.first)
        XCTAssertEqual(provider.primary?.url, address)
        XCTAssertEqual(provider.primary?.api, .automatic)
        XCTAssertEqual(provider.model, "old-model")
        XCTAssertEqual(ModelCatalog.listedCustom(provider.id), ["listed-model"])
        XCTAssertTrue(ModelCatalog.enabled(.custom).contains(CustomProviders.choiceID(provider.id, "listed-model")))
        XCTAssertEqual(ModelKeys.selectedModel, CustomProviders.choiceID(provider.id, "listed-model"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "chat.customURL"))
    }

    func testResetRejectsAnInFlightDraftResponse() async throws {
        let started = expectation(description: "Request reached the server")
        let release = DispatchSemaphore(value: 0)
        ModelServerStub.responder = { _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return (200, "application/json", #"{"data":[{"id":"stale-model"}]}"#)
        }
        let discovery = CustomModelDiscovery()
        discovery.fetch(address: address, key: nil, session: session)
        await fulfillment(of: [started], timeout: 2)
        discovery.reset()
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(discovery.loading)
        XCTAssertFalse(discovery.presenting)
        XCTAssertTrue(discovery.models.isEmpty)
        XCTAssertNil(discovery.problem)
    }

    func testResetCancelsDraftAndRetryCanPresentFreshModels() async throws {
        let discovery = CustomModelDiscovery()
        ModelServerStub.answer = (200, #"{"data":[{"id":"old-model"}]}"#)
        discovery.fetch(address: address, key: nil, session: session)
        discovery.reset()
        XCTAssertFalse(discovery.loading)
        XCTAssertFalse(discovery.presenting)
        ModelServerStub.answer = (200, #"{"data":[{"id":"new-model"}]}"#)
        discovery.fetch(address: address, key: nil, session: session)
        for _ in 0..<100 where discovery.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(discovery.models, ["new-model"])
        XCTAssertTrue(discovery.presenting)
        discovery.reset()
        XCTAssertTrue(discovery.models.isEmpty)
        XCTAssertTrue(ModelKeys.customURL.isEmpty)
    }
}
