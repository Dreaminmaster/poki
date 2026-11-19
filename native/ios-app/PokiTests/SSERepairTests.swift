import XCTest
@testable import Poki

/// A custom address that sends `data:data: {…}` (issue #344): the prefix is folded into one, across
/// chunk boundaries, and a standard stream passes through unchanged.
final class SSERepairTests: XCTestCase {
    private func run(_ chunks: [String]) -> (String, SSERepair) {
        var repair = SSERepair()
        var out = Data()
        for chunk in chunks { out.append(repair.feed(Data(chunk.utf8))) }
        out.append(repair.flush())
        return (String(decoding: out, as: UTF8.self), repair)
    }

    func testDoubledPrefixIsFolded() {
        let (text, repair) = run(["data:data: {\"a\":1}\n\ndata:\n\ndata:data: [DONE]\n\n"])
        XCTAssertEqual(text, "data: {\"a\":1}\n\ndata:\n\ndata: [DONE]\n\n")
        XCTAssertEqual(repair.events, 2)
        XCTAssertEqual(repair.repaired, 2)
        XCTAssertTrue(repair.sawDone)
    }

    func testSpacedAndCRLFPrefixesAreFolded() {
        let (text, _) = run(["data: data: {\"a\":1}\r\n\r\n"])
        XCTAssertEqual(text, "data: {\"a\":1}\r\n\r\n")
    }

    func testTwoCRLFEventsInOneChunkAreBothFolded() {
        let (text, repair) = run(["data:data: {\"a\":1}\r\n\r\ndata:data: [DONE]\r\n\r\n"])
        XCTAssertEqual(text, "data: {\"a\":1}\r\n\r\ndata: [DONE]\r\n\r\n")
        XCTAssertEqual(repair.events, 2)
        XCTAssertEqual(repair.repaired, 2)
        XCTAssertTrue(repair.sawDone)
    }

    func testLinesSplitAcrossChunks() {
        let (text, repair) = run(["da", "ta:da", "ta: {\"a\":", "1}\n", "\ndata: [DO", "NE]"])
        XCTAssertEqual(text, "data: {\"a\":1}\n\ndata: [DONE]")
        XCTAssertEqual(repair.repaired, 1)
        XCTAssertTrue(repair.sawDone)
    }

    func testStandardStreamIsUnchanged() {
        let stream = "event: x\ndata: {\"content\":\"data: yes\"}\n\n: comment\ndata: [DONE]\n\n"
        let (text, repair) = run([stream])
        XCTAssertEqual(text, stream)
        XCTAssertEqual(repair.repaired, 0)
    }

    func testSummaryHidesKeyAndQuery() {
        XCTAssertEqual(CustomEndpointClient.shown(URL(string: "https://u:p@gw.test/v1/chat/completions?key=abc")), "https://gw.test/v1/chat/completions")
        var seen = CustomEndpointClient.Seen(url: "https://gw.test/v1/chat/completions")
        seen.status = 401
        seen.errorBody = "{\"error\":\"bad key secret-key-123\"}"
        XCTAssertFalse(seen.summary(key: "secret-key-123").contains("secret-key-123"))
        XCTAssertTrue(seen.summary(key: "secret-key-123").contains("HTTP 401"))
    }
}
