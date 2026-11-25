import Foundation
import PiSwiftAI
import XCTest
@testable import Poki

/// GPT-6.2 can be picked (issue #754), and model lists stay current without a release.
final class ModelListsTests: XCTestCase {
    private var isolated: IsolatedTestStorage!
    private var storage: PokiStorage { isolated.storage }

    override func setUpWithError() throws {
        isolated = try IsolatedTestStorage(prefix: "poki-model-lists")
    }

    override func tearDownWithError() throws {
        try isolated?.tearDown()
        isolated = nil
    }

    func testGPT62IsBundledForOpenAIChatGPTAndOpenRouter() {
        for provider in [ModelProvider.openai, .chatgpt] {
            let ids = ModelCatalog.all(provider, storage: storage).map(\.id)
            XCTAssertTrue(ids.contains("gpt-6.2-sol"), "\(provider)")
            XCTAssertTrue(ids.contains("gpt-6.2-astra"), "\(provider)")
            XCTAssertTrue(ModelCatalog.available(provider, storage: storage).map(\.id).contains("gpt-6.2-sol"), "\(provider)")
        }
        XCTAssertTrue(ModelCatalog.all(.openrouter, storage: storage).map(\.id).contains("openai/gpt-6.2-sol"))
    }

    func testGPT62RunsWithItsOwnSetup() throws {
        let sol = try XCTUnwrap(ModelProvider.openai.piModel("gpt-6.2-sol", storage: storage))
        XCTAssertEqual(sol.id, "gpt-6.2-sol")
        XCTAssertEqual(sol.name, "GPT-6.2 Sol")
        XCTAssertEqual(sol.api, .openAIResponses)
        XCTAssertTrue(sol.reasoning)
        XCTAssertEqual(sol.input, [.text, .image])

        let astra = try XCTUnwrap(ModelProvider.openai.piModel("gpt-6.2-astra", storage: storage))
        XCTAssertEqual(astra.name, "GPT-6.2 Astra")
        XCTAssertEqual(astra.cost.input, 8)
        XCTAssertEqual(astra.cost.output, 40)
        XCTAssertEqual(astra.cost.tiers?.first?.input, 16)
        // GPT-6.2 rejects reasoning effort none: no level maps to it.
        XCTAssertFalse((astra.thinkingLevelMap ?? [:]).values.contains { $0 == "none" })
        XCTAssertFalse((sol.thinkingLevelMap ?? [:]).values.contains { $0 == "none" })
        // Off is listed as unsupported (mapped to nil), not missing, so pi never sends effort none.
        for model in [sol, astra] {
            let off = try XCTUnwrap(model.thinkingLevelMap?[.off], "\(model.id) lists off")
            XCTAssertNil(off, model.id)
        }
    }

    func testGPT62ThroughACodexSignInKeepsCodexsAPI() throws {
        let codex = try XCTUnwrap(ModelProvider.knownModel(provider: "openai-codex", id: "gpt-6.2-astra"))
        XCTAssertEqual(codex.api, .openAICodexResponses)
        XCTAssertEqual(codex.contextWindow, 272_000)
        XCTAssertEqual(codex.cost.input, 8)
    }

    func testCustomProviderServingGPT62GetsItsSetup() throws {
        let model = ModelProvider.customModel("openai/gpt-6.2-astra", baseUrl: "https://gateway.example/v1", api: .openAIResponses, reasoning: nil)
        XCTAssertTrue(model.reasoning)
        XCTAssertEqual(model.maxTokens, 128_000)
    }

    func testNewDefaultIsSwitchedOnOnceForAnOwnerWhoChoseModels() {
        // Saved by Poki 0.5.0: Terra off, Sol on.
        storage.defaults.set(["gpt-6.1-sol"], forKey: "models.enabled.openai")
        XCTAssertEqual(ModelCatalog.enabled(.openai, storage: storage), ["gpt-6.1-sol", "gpt-6.2-sol"])

        // Terra stays off, and GPT-6.2 Sol stays off once switched off.
        ModelCatalog.set("gpt-6.2-sol", on: false, for: .openai, notify: false, storage: storage)
        XCTAssertEqual(ModelCatalog.enabled(.openai, storage: storage), ["gpt-6.1-sol"])
    }

    func testCodexListIsReadBySlugAndSkipsHiddenModels() {
        let items: [[String: Any]] = [
            ["slug": "gpt-6.2-sol", "visibility": "list"],
            ["slug": "gpt-6.3-nova", "visibility": "list"],
            ["slug": "gpt-6.2-astra-internal", "visibility": "hide"],
            ["slug": "gpt-realtime-2.1", "visibility": "list"],
        ]
        XCTAssertEqual(ModelCatalog.listedIDs(items, .chatgpt), ["gpt-6.2-sol", "gpt-6.3-nova"])
    }

    func testOpenAIListAddsANewModelAndKeepsRealtimeOut() {
        let items: [[String: Any]] = [["id": "gpt-6.3-nova"], ["id": "gpt-realtime-2.1"], ["id": "text-embedding-4"]]
        XCTAssertEqual(ModelCatalog.listedIDs(items, .openai), ["gpt-6.3-nova"])
    }

    func testCodexModelsRequestNamesTheWorkspace() throws {
        let token = Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "workspace-1"], "exp": 4_102_444_800])
        let request = try XCTUnwrap(ModelCatalog.codexModelsRequest(accessToken: token))
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/codex/models")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "client_version")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "workspace-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertNil(ModelCatalog.codexModelsRequest(accessToken: Self.jwt(["exp": 4_102_444_800])))
    }

    func testListIsStaleWhenMissingOrADayOld() {
        let now = Date()
        XCTAssertTrue(ModelCatalog.isStale(.openai, now: now, storage: storage))
        storage.defaults.set(now.timeIntervalSince1970 - 60, forKey: "models.listedAt.openai")
        XCTAssertFalse(ModelCatalog.isStale(.openai, now: now, storage: storage))
        storage.defaults.set(now.timeIntervalSince1970 - ModelCatalog.listLifetime - 1, forKey: "models.listedAt.openai")
        XCTAssertTrue(ModelCatalog.isStale(.openai, now: now, storage: storage))
    }

    func testOpenRouterGPT62TakesTheGatewaysSetupNotThePlainOne() throws {
        let sol = try XCTUnwrap(ModelProvider.openrouter.piModel("openai/gpt-6.2-sol", storage: storage))
        XCTAssertEqual(sol.id, "openai/gpt-6.2-sol")
        XCTAssertTrue(sol.reasoning)
        XCTAssertEqual(sol.contextWindow, 1_050_000)
        XCTAssertEqual(sol.maxTokens, 128_000)
        XCTAssertEqual(sol.cost.input, 2)
        XCTAssertNotNil(sol.compat)
        let astra = try XCTUnwrap(ModelProvider.openrouter.piModel("openai/gpt-6.2-astra", storage: storage))
        XCTAssertEqual(astra.name, "GPT-6.2 Astra")
        XCTAssertEqual(astra.cost.output, 40)
        // GPT-6.1 Terra behind OpenRouter keeps the plain setup (ConnectionCheckTests).
        XCTAssertNil(ModelProvider.knownModel(provider: "openrouter", id: "openai/gpt-6.1-terra"))
    }

    @MainActor
    func testAPageThatIsNotAListKeepsTheLastListAndItsAge() throws {
        XCTAssertEqual(try ModelCatalog.store(Data(#"{"data":[{"id":"gpt-6.2-sol"},{"id":"gpt-realtime-2.1"}]}"#.utf8), for: .openai, storage: storage), 1)
        let listedAt = storage.defaults.double(forKey: "models.listedAt.openai")
        XCTAssertGreaterThan(listedAt, 0)

        for body in ["<html>Sign in to the Wi-Fi</html>", #"{"models":[]}"#, #"{"error":{"message":"nope"}}"#, #"{"data":[{"id":"text-embedding-4"}]}"#] {
            XCTAssertThrowsError(try ModelCatalog.store(Data(body.utf8), for: .openai, storage: storage), body)
            XCTAssertEqual(storage.defaults.stringArray(forKey: "models.listed.openai"), ["gpt-6.2-sol"], body)
            XCTAssertEqual(storage.defaults.stringArray(forKey: "models.listed.voice"), ["gpt-realtime-2.1"], body)
            XCTAssertEqual(storage.defaults.double(forKey: "models.listedAt.openai"), listedAt, body)
        }
    }

    func testFailedBackgroundReadsBackOffUpToADay() throws {
        try ModelKeys.save("sk-test", for: .openai, storage: storage)
        let now = Date()
        XCTAssertEqual(ModelCatalog.dueForBackgroundRefresh(now: now, storage: storage), [.provider(.openai)])

        ModelCatalog.noteFailure(.provider(.openai), now: now, storage: storage)
        XCTAssertEqual(ModelCatalog.dueForBackgroundRefresh(now: now.addingTimeInterval(59 * 60), storage: storage), [])
        XCTAssertEqual(ModelCatalog.dueForBackgroundRefresh(now: now.addingTimeInterval(61 * 60), storage: storage), [.provider(.openai)])

        ModelCatalog.noteFailure(.provider(.openai), now: now, storage: storage)
        XCTAssertTrue(ModelCatalog.isBackingOff(.openai, now: now.addingTimeInterval(119 * 60), storage: storage))
        XCTAssertFalse(ModelCatalog.isBackingOff(.openai, now: now.addingTimeInterval(121 * 60), storage: storage))
        XCTAssertEqual(ModelCatalog.backoff(failures: 40), ModelCatalog.listLifetime)

        ModelCatalog.clearFailures(.openai, storage: storage)
        XCTAssertFalse(ModelCatalog.isBackingOff(.openai, now: now, storage: storage))
    }

    func testEachCustomProviderKeepsItsOwnAgeAndWait() {
        let near = CustomProviders.upsert(CustomProvider(name: "Near", endpoints: [CustomEndpoint(url: "https://near.example/v1")], model: "m"), storage: storage)
        let far = CustomProviders.upsert(CustomProvider(name: "Far", endpoints: [CustomEndpoint(url: "http://10.0.0.9/v1")], model: "m"), storage: storage)
        let now = Date()
        storage.defaults.set(now.timeIntervalSince1970, forKey: "models.listedAt.custom.\(near.id.uuidString)")
        ModelCatalog.noteFailure(.custom(far.id), now: now, storage: storage)

        XCTAssertFalse(ModelCatalog.isStale(.custom(near.id), now: now, storage: storage))
        XCTAssertTrue(ModelCatalog.isStale(.custom(far.id), now: now, storage: storage))
        XCTAssertTrue(ModelCatalog.isBackingOff(.custom(far.id), now: now, storage: storage))
        XCTAssertFalse(ModelCatalog.isBackingOff(.custom(near.id), now: now, storage: storage))
        // One unreachable address does not make the other wait, and neither is due now.
        XCTAssertEqual(ModelCatalog.dueForBackgroundRefresh(now: now, storage: storage), [])
        XCTAssertEqual(ModelCatalog.dueForBackgroundRefresh(now: now.addingTimeInterval(61 * 60), storage: storage), [.custom(far.id)])

        // A changed address forgets the list's age and its wait.
        ModelCatalog.invalidateCustom(near.id, storage: storage)
        XCTAssertEqual(storage.defaults.double(forKey: "models.listedAt.custom.\(near.id.uuidString)"), 0)
        ModelCatalog.invalidateCustom(far.id, storage: storage)
        XCTAssertFalse(ModelCatalog.isBackingOff(.custom(far.id), now: now, storage: storage))
        XCTAssertEqual(Set(ModelCatalog.dueForBackgroundRefresh(now: now, storage: storage)), [.custom(near.id), .custom(far.id)])
    }

    func testACancelledReadIsNotAFailure() {
        XCTAssertTrue(ModelCatalog.isCancellation(CancellationError()))
        XCTAssertTrue(ModelCatalog.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(ModelCatalog.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ModelCatalog.isCancellation(ModelCatalog.DiscoveryError.signIn))
    }

    func testCodexAskedAsTheCodexReleasePokiShips() throws {
        // native/codex-voice/build.sh stamps the Codex release Poki builds; the list asks as that release.
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("codex-voice/build.sh")
        let script = try String(contentsOf: build, encoding: .utf8)
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("version = \"") })
        XCTAssertEqual(line, "version = \"\(ModelCatalog.codexClientVersion)\"")
    }

    func testAWorkspaceTokenWithANullFedrampClaimStillNamesTheWorkspace() {
        let token = Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "workspace-2", "chatgpt_account_is_fedramp": NSNull()], "exp": 4_102_444_800])
        XCTAssertEqual(CodexAccount.chatGPTAccountID(token), "workspace-2")
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none"])).\(part(claims)).c2ln"
    }
}
