import XCTest
@testable import Poki

/// Stubs model endpoints without the network, through URLSession.shared as pi sends requests.
final class ModelServerStub: URLProtocol {
    struct Sent {
        let url: URL?
        let body: Data
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var answer: (status: Int, body: String)?
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest, Data) -> (status: Int, type: String, body: String))?
    nonisolated(unsafe) private static var recorded: [Sent] = []

    static var requests: [Sent] { lock.withLock { recorded } }
    static func clear() {
        lock.withLock {
            answer = nil
            responder = nil
            recorded.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return host == "model-server.test" || host == "openrouter.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let customResponder = Self.lock.withLock { () -> (@Sendable (URLRequest, Data) -> (status: Int, type: String, body: String))? in
            Self.recorded.append(Sent(url: request.url, body: body))
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
    private let defaultsKeys = [
        "chat.provider",
        "chat.model.openrouter",
        "models.listed.openrouter",
        "models.enabled.openrouter",
    ]

    /// The result's words follow Poki's language; these tests read the English ones.
    override func setUp() {
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        savedOpenRouterKey = ModelKeys.key(.openrouter)
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
    }

    private func check(_ answer: (status: Int, body: String)?) async -> ConnectionCheck.Result {
        ModelServerStub.answer = answer
        return await ConnectionCheck.run(.custom, key: key, customURL: "https://model-server.test/v1", modelID: "house-model")
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
        let loop = PiLoop(provider: .openrouter, model: model, tools: []) { _ in
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
}
