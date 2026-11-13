import XCTest
@testable import Poki

/// A custom model endpoint served without the network, through URLSession.shared as pi sends it: each
/// test sets what it answers, or makes it time out.
final class ModelServerStub: URLProtocol {
    nonisolated(unsafe) static var answer: (status: Int, body: String)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "model-server.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let answer = Self.answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let type = answer.status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["content-type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Test Connection on the key page: one real request through pi to a custom endpoint, and the line the
/// owner reads for success, a rejected key, a missing model and a timeout. The key never shows.
@MainActor
final class ConnectionCheckTests: XCTestCase {
    private let key = "placeholder-test-key"

    override func setUp() { URLProtocol.registerClass(ModelServerStub.self) }

    override func tearDown() {
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.answer = nil
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

        for result in [works, rejected, noModel, late] {
            XCTAssertFalse(result.words.contains(key))
            XCTAssertFalse(result.detail?.contains(key) ?? false)
        }
    }
}
