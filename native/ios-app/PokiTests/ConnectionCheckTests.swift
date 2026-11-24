import XCTest
@testable import Poki

/// Stubs model endpoints without the network, through URLSession.shared as pi sends requests.
final class ModelServerStub: URLProtocol {
    struct Sent {
        let url: URL?
        let body: Data
        let headers: [String: String]
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var answer: (status: Int, body: String)?
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest, Data) -> (status: Int, type: String, body: String))?
    nonisolated(unsafe) static var additionalHosts: Set<String> = []
    nonisolated(unsafe) private static var recorded: [Sent] = []

    static var requests: [Sent] { lock.withLock { recorded } }
    static func recordedReset() { lock.withLock { recorded.removeAll() } }
    static func clear() {
        lock.withLock {
            answer = nil
            responder = nil
            additionalHosts = []
            recorded.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return ["model-server.test", "openrouter.ai", "api.anthropic.com", "opencode.ai"].contains(host)
            || lock.withLock { additionalHosts.contains(host) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let customResponder = Self.lock.withLock { () -> (@Sendable (URLRequest, Data) -> (status: Int, type: String, body: String))? in
            // Only inspect non-secret routing fields in tests: never retain
            // Authorization, API keys, cookies or other credential headers.
            let visible: Set<String> = ["x-opencode-session", "x-opencode-client", "user-agent"]
            let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, field in
                let name = field.key.lowercased()
                if visible.contains(name) { result[name] = field.value }
            }
            Self.recorded.append(Sent(url: request.url, body: body, headers: headers))
            return Self.responder
        }
        let reply: (status: Int, type: String, body: String)
        if let customResponder {
            reply = customResponder(request, body)
        } else if let answer = Self.lock.withLock({ Self.answer }) {
            reply = (answer.status, answer.status == 200 ? "text/event-stream" : "application/json", answer.body)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["content-type": reply.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves httpBody into httpBodyStream before handing a request to URLProtocol.
    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Test Connection on the key page: one real request through pi to a custom endpoint, and the line the
/// owner reads for success, a rejected key, a missing model and a timeout. The key never shows.
@MainActor
final class ConnectionCheckTests: XCTestCase {
    private let key = "placeholder-test-key"
    private var language = AppLocalization.system
    private var savedDefaults: [String: Any] = [:]
    private var savedOpenRouterKey: String?
    private var savedAnthropicKey: String?
    private let defaultsKeys = [
        "chat.provider",
        "chat.model.openrouter",
        "models.listed.openrouter",
        "models.enabled.openrouter",
        "models.reasoning.openrouter",
    ]

    /// The result's words follow Poki's language; these tests read the English ones.
    override func setUp() {
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        savedOpenRouterKey = ModelKeys.key(.openrouter)
        savedAnthropicKey = ModelKeys.key(.anthropic)
        savedDefaults = [:]
        for k in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: k) { savedDefaults[k] = value }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.clear()
        AppLocalization.shared.preference = language
        for k in defaultsKeys {
            if let value = savedDefaults[k] {
                UserDefaults.standard.set(value, forKey: k)
            } else {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        if let savedOpenRouterKey {
            try? ModelKeys.save(savedOpenRouterKey, for: .openrouter)
        } else {
            ModelKeys.remove(.openrouter)
        }
        if let savedAnthropicKey {
            try? ModelKeys.save(savedAnthropicKey, for: .anthropic)
        } else {
            ModelKeys.remove(.anthropic)
        }
    }

    private func check(_ answer: (status: Int, body: String)?) async -> ConnectionCheck.Result {
        ModelServerStub.answer = answer
        return await ConnectionCheck.run(.custom, key: key, customURL: "https://model-server.test/v1", modelID: "house-model")
    }

    /// Automatic tries the Responses API first; an address without it (404 at /responses) is tested
    /// again in chat completions, and the check says which one answered.
    func testAutomaticFallsBackToChatCompletionsWhereThereIsNoResponsesAPI() async {
        let chunk = #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"house-model","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#
        ModelServerStub.responder = { request, _ in
            if request.url?.path == "/v1/responses" { return (404, "application/json", #"{"error":{"message":"Not Found"}}"#) }
            return (200, "text/event-stream", "data: \(chunk)\n\ndata: [DONE]\n\n")
        }
        let run = await ConnectionCheck.runCustom(url: "https://model-server.test/v1", key: key, modelID: "house-model", api: .automatic, reasoning: nil)
        XCTAssertTrue(run.result.passed)
        XCTAssertEqual(run.api, .chatCompletions)
        XCTAssertEqual(ModelServerStub.requests.map { $0.url?.path }, ["/v1/responses", "/v1/chat/completions"])
    }

    /// The Responses API is spoken where it is chosen, with the model's reasoning when the owner turns
    /// thinking on, as the official OpenAI account sends it.
    func testResponsesIsSentToTheResponsesPathWithReasoning() async throws {
        ModelServerStub.answer = (404, #"{"error":{"message":"Not Found"}}"#)
        let run = await ConnectionCheck.runCustom(url: "https://model-server.test/v1", key: key, modelID: "house-model", api: .responses, reasoning: true)
        XCTAssertFalse(run.result.passed)
        XCTAssertEqual(run.api, .responses)
        let sent = try XCTUnwrap(ModelServerStub.requests.first)
        XCTAssertEqual(sent.url?.path, "/v1/responses")
        XCTAssertEqual(sent.json["model"] as? String, "house-model")
        XCTAssertEqual(sent.json["store"] as? Bool, false)
        XCTAssertEqual((sent.json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(ModelServerStub.requests.count, 1)
    }

    func testOnlyAMissingResponsesAPIFallsBack() {
        XCTAssertTrue(ConnectionCheck.lacksResponses(.noEndpoint))
        XCTAssertTrue(ConnectionCheck.lacksResponses(.failed(status: 405, reason: nil)))
        XCTAssertFalse(ConnectionCheck.lacksResponses(.badKey(reason: nil)))
        XCTAssertFalse(ConnectionCheck.lacksResponses(.unreachable(reason: nil)))
        XCTAssertFalse(ConnectionCheck.lacksResponses(.timedOut))
        XCTAssertFalse(ConnectionCheck.lacksResponses(.works(model: "m")))
    }

    func testOpenCodeConnectionCheckSendsAnIsolatedSessionHeader() async {
        ModelServerStub.responder = { request, _ in
            let session = request.value(forHTTPHeaderField: "x-opencode-session")
            let isOpenCode = request.url?.host() == "opencode.ai"
            if isOpenCode {
                guard let session, UUID(uuidString: session) != nil else {
                    return (400, "application/json", #"{"error":{"message":"MissingSessionID"}}"#)
                }
            } else if session != nil {
                return (400, "application/json", #"{"error":{"message":"Unexpected session header"}}"#)
            }
            return (401, "application/json", #"{"error":{"message":"Invalid credential"}}"#)
        }

        let openCode = await ConnectionCheck.run(.custom, key: key,
            customURL: "https://opencode.ai/inference/go/openai/v1", modelID: "deepseek-v4-pro")
        XCTAssertEqual(openCode, .badKey(reason: "Invalid credential"))
        let other = await ConnectionCheck.run(.custom, key: key,
            customURL: "https://model-server.test/v1", modelID: "house-model")
        XCTAssertEqual(other, .badKey(reason: "Invalid credential"))
    }

    func testEachAnswerIsWordedForTheOwner() async {
        let chunk = #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"house-model-2026-11","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#
        let works = await check((200, "data: \(chunk)\n\ndata: [DONE]\n\n"))
        XCTAssertTrue(works.passed)
        XCTAssertEqual(works.words, "Connection works. Model: house-model-2026-11")

        // The server repeats the key in its reason; the owner sees it redacted.
        let rejected = await check((401, #"{"error":{"message":"Incorrect API key provided: \#(key)","type":"invalid_request_error","code":"invalid_api_key"}}"#))
        XCTAssertFalse(rejected.passed)
        XCTAssertEqual(rejected.words, "The key is not valid. Check that it was copied in full.")
        XCTAssertEqual(rejected.detail, "Incorrect API key provided: [redacted]")

        let noModel = await check((404, #"{"error":{"message":"The model `house-model` does not exist","type":"invalid_request_error","code":"model_not_found"}}"#))
        XCTAssertEqual(noModel.words, "The model house-model doesn’t exist, or this key can’t use it.")

        let late = await check(nil)
        XCTAssertEqual(late.words, "No answer within 10 seconds. Check the address and the network, then try again.")

        // A gateway that doubles the prefix (issue #344) works as the chat now reads it.
        let doubled = await check((200, "data:data: \(chunk)\n\ndata:\n\ndata:data: [DONE]\n\n"))
        XCTAssertTrue(doubled.passed)
        XCTAssertEqual(doubled.words, "Connection works. Model: house-model-2026-11")

        AppLocalization.shared.preference = "zh-Hant"
        XCTAssertEqual(works.words, "連線正常，回應模型：house-model-2026-11")
        XCTAssertEqual(rejected.words, "金鑰無效，請確認金鑰已完整複製。")

        for result in [works, rejected, noModel, late] {
            XCTAssertFalse(result.words.contains(key))
            XCTAssertFalse(result.detail?.contains(key) ?? false)
        }
    }

    func testUncataloguedOpenRouterModelOmitsThinkingParameters() async throws {
        let modelID = "openai/gpt-6.1-terra"
        UserDefaults.standard.set([modelID], forKey: "models.listed.openrouter")
        ModelCatalog.set(modelID, on: true, for: .openrouter)
        ModelKeys.selectedProvider = .openrouter
        ModelKeys.selectedModel = modelID
        XCTAssertEqual(ModelKeys.model(for: .openrouter), modelID)

        let sse = #"data: {"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"openai/gpt-6.1-terra-20261026","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        ModelServerStub.responder = { _, body in
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if json["thinking"] != nil || json["reasoning"] != nil || json["reasoning_effort"] != nil || json["output_config"] != nil {
                return (400, "application/json", #"{"error":{"message":"Thinking.block_binding is not supported on openai/gpt-6.1-terra-20261026","code":400}}"#)
            }
            return (200, "text/event-stream", sse)
        }

        let checkResult = await ConnectionCheck.run(.openrouter, key: key)
        XCTAssertEqual(checkResult, .works(model: "openai/gpt-6.1-terra-20261026"))
        let first = try XCTUnwrap(ModelServerStub.requests.first)
        XCTAssertEqual(first.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(first.json["model"] as? String, modelID)
        XCTAssertNil(first.json["thinking"])
        XCTAssertNil(first.json["reasoning"])
        XCTAssertNil(first.json["reasoning_effort"])
        XCTAssertNil(first.json["output_config"])

        try ModelKeys.save(key, for: .openrouter)
        let model = try XCTUnwrap(ModelProvider.openrouter.piModel(modelID))
        let loop = PiLoop(provider: .openrouter, model: model, sessionID: UUID().uuidString, tools: []) { _ in
            .init(text: "", jpeg: nil, isError: false)
        }
        let turnOutcome = await loop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
        XCTAssertEqual(turnOutcome, .done)
        let second = try XCTUnwrap(ModelServerStub.requests.last)
        XCTAssertEqual(second.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertNil(second.json["thinking"])
        XCTAssertNil(second.json["reasoning"])
        XCTAssertNil(second.json["reasoning_effort"])
        XCTAssertNil(second.json["output_config"])
    }

    func testOpenRouterModelListEnablesReasoningOnlyWhenSupported() async throws {
        try ModelKeys.save(key, for: .openrouter)
        let catalogJSON = #"""
        {"data":[
          {"id":"openai/gpt-6.1-terra","supported_parameters":["max_completion_tokens","reasoning","reasoning_effort","tools"]},
          {"id":"vendor/plain-chat","supported_parameters":["max_tokens","temperature","tools"]}
        ]}
        """#
        let sse = #"data: {"id":"gen-2","object":"chat.completion.chunk","created":1,"model":"served","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        ModelServerStub.responder = { request, _ in
            if request.url?.path == "/api/v1/models" {
                return (200, "application/json", catalogJSON)
            }
            return (200, "text/event-stream", sse)
        }

        let count = try await ModelCatalog.refresh(.openrouter)
        XCTAssertEqual(count, 2)

        ModelServerStub.recordedReset()
        ModelCatalog.set("vendor/plain-chat", on: true, for: .openrouter)
        ModelKeys.selectedProvider = .openrouter
        ModelKeys.selectedModel = "vendor/plain-chat"
        let plainModel = try XCTUnwrap(ModelProvider.openrouter.piModel("vendor/plain-chat"))
        let plainLoop = PiLoop(provider: .openrouter, model: plainModel, sessionID: UUID().uuidString, tools: []) { _ in
            .init(text: "", jpeg: nil, isError: false)
        }
        let plainOutcome = await plainLoop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
        XCTAssertEqual(plainOutcome, .done)
        let plainSent = try XCTUnwrap(ModelServerStub.requests.last)
        XCTAssertNil(plainSent.json["reasoning"])
        XCTAssertNil(plainSent.json["thinking"])

        ModelServerStub.recordedReset()
        ModelCatalog.set("openai/gpt-6.1-terra", on: true, for: .openrouter)
        ModelKeys.selectedModel = "openai/gpt-6.1-terra"
        let checkResult = await ConnectionCheck.run(.openrouter, key: key)
        XCTAssertEqual(checkResult, .works(model: "served"))
        let checkSent = try XCTUnwrap(ModelServerStub.requests.first)
        XCTAssertNil(checkSent.json["reasoning"])
        XCTAssertNil(checkSent.json["thinking"])

        let reasoningModel = try XCTUnwrap(ModelProvider.openrouter.piModel("openai/gpt-6.1-terra"))
        let reasoningLoop = PiLoop(provider: .openrouter, model: reasoningModel, sessionID: UUID().uuidString, tools: []) { _ in
            .init(text: "", jpeg: nil, isError: false)
        }
        let reasoningOutcome = await reasoningLoop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
        XCTAssertEqual(reasoningOutcome, .done)
        let reasoningSent = try XCTUnwrap(ModelServerStub.requests.last)
        XCTAssertEqual((reasoningSent.json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(reasoningSent.json["thinking"])
    }

    func testCataloguedModelsKeepTheirConfiguredBehavior() async throws {
        try ModelKeys.save(key, for: .openrouter)
        let anthropicSSE = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"anthropic/claude-sonnet-5.5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":4,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let openAISSE = #"data: {"id":"gen-3","object":"chat.completion.chunk","created":1,"model":"openai/gpt-6.1-sol","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        ModelServerStub.responder = { request, _ in
            if request.url?.path == "/api/v1/messages" {
                return (200, "text/event-stream", anthropicSSE)
            }
            return (200, "text/event-stream", openAISSE)
        }

        ModelKeys.selectedProvider = .openrouter
        ModelKeys.selectedModel = "anthropic/claude-sonnet-5.5"
        let sonnetCheck = await ConnectionCheck.run(.openrouter, key: key)
        XCTAssertEqual(sonnetCheck, .works(model: "anthropic/claude-sonnet-5.5"))
        let sonnetSent = try XCTUnwrap(ModelServerStub.requests.first)
        XCTAssertEqual(sonnetSent.url?.absoluteString, "https://openrouter.ai/api/v1/messages")
        XCTAssertEqual((sonnetSent.json["thinking"] as? [String: Any])?["type"] as? String, "adaptive")

        ModelServerStub.recordedReset()
        let solModel = try XCTUnwrap(ModelProvider.openrouter.piModel("openai/gpt-6.1-sol"))
        let solLoop = PiLoop(provider: .openrouter, model: solModel, sessionID: UUID().uuidString, tools: []) { _ in
            .init(text: "", jpeg: nil, isError: false)
        }
        let solOutcome = await solLoop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
        XCTAssertEqual(solOutcome, .done)
        let solSent = try XCTUnwrap(ModelServerStub.requests.last)
        XCTAssertEqual(solSent.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual((solSent.json["reasoning"] as? [String: Any])?["effort"] as? String, "low")

        let builtInTerra = try XCTUnwrap(ModelProvider.openai.piModel("gpt-6.1-terra"))
        XCTAssertEqual(builtInTerra.api, .openAIResponses)
        XCTAssertTrue(builtInTerra.reasoning)
    }

    /// The conservative setup is OpenRouter's alone: another provider's unlisted model (a dated Anthropic id
    /// from "Refresh the list") still takes its provider's built-in setup, thinking and output limit.
    func testUncataloguedDirectAnthropicModelKeepsThinkingAndOutputLimit() async throws {
        try ModelKeys.save(key, for: .anthropic)
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"served","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":4,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        ModelServerStub.responder = { _, _ in (200, "text/event-stream", sse) }

        func chatRequest(_ modelID: String) async throws -> ModelServerStub.Sent {
            ModelServerStub.recordedReset()
            let model = try XCTUnwrap(ModelProvider.anthropic.piModel(modelID))
            let loop = PiLoop(provider: .anthropic, model: model, sessionID: UUID().uuidString, tools: []) { _ in
                .init(text: "", jpeg: nil, isError: false)
            }
            let outcome = await loop.run("Reply with OK.", instructions: "Be brief.", maxTurns: 1) { _ in }
            XCTAssertEqual(outcome, .done)
            return try XCTUnwrap(ModelServerStub.requests.last)
        }

        let listed = try XCTUnwrap(ModelProvider.anthropic.models.first?.id)
        let builtIn = try await chatRequest(listed)
        let dated = try await chatRequest(listed + "-20261001")
        XCTAssertEqual(dated.url?.absoluteString, builtIn.url?.absoluteString)
        XCTAssertEqual((dated.json["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual(dated.json["max_tokens"] as? Int, builtIn.json["max_tokens"] as? Int)
        XCTAssertGreaterThan(dated.json["max_tokens"] as? Int ?? 0, 8_192)
    }
}
