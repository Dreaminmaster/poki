import PokiCore
import XCTest
@testable import Poki

/// The voice bridge's token answer, served to URLSession.shared without a Mac.
final class BridgeStub: URLProtocol {
    static let address = "http://voice-bridge.test/voice/0123456789abcdef"
    static let liveAddress = "http://voice-live-bridge.test/voice/0123456789abcdef"
    static let secureLiveAddress = "https://voice-live-bridge.test/voice/0123456789abcdef"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var screenshots: [String] = []
    static var screenshotSchemes: [String] { lock.withLock { screenshots } }
    static func resetScreenshots() { lock.withLock { screenshots.removeAll() } }
    override class func canInit(with request: URLRequest) -> Bool {
        ["voice-bridge.test", "voice-live-bridge.test"].contains(request.url?.host())
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if request.url?.host() == "voice-live-bridge.test" {
            switch request.url?.lastPathComponent {
            case "session": body = #"{"sdp":"sdp-answer"}"#
            case "screen":
                Self.lock.withLock { Self.screenshots.append(request.url?.scheme ?? "") }
                let data = requestBody(request)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let image = json?["image"] as? String
                let first = "data:image/jpeg;base64," + Data("first synthetic screenshot".utf8).base64EncodedString()
                let second = "data:image/jpeg;base64," + Data("second synthetic screenshot".utf8).base64EncodedString()
                body = image == first ? #"{"text":"First screen description"}"# : image == second
                    ? #"{"text":"Second screen description"}"# : #"{"text":"Unrecognized screenshot"}"#
            default: body = #"{"live":true,"model":"gpt-live-1.1","local_tools":["get_ios_version","look","open_app","do"]}"#
            }
        } else {
            body = #"{"value":"ek_test","model":"gpt-realtime","local_tools":["get_ios_version","look","do"]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody, !body.isEmpty { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

/// A voice bridge in trouble: one host no longer knows the address, the other never answers in time.
final class BridgeTroubleStub: URLProtocol {
    static let gone = "http://voice-bridge-gone.test/voice/0123456789abcdef"
    static let slow = "http://voice-bridge-slow.test/voice/0123456789abcdef"
    override class func canInit(with request: URLRequest) -> Bool { ["voice-bridge-gone.test", "voice-bridge-slow.test"].contains(request.url?.host()) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host() == "voice-bridge-gone.test" else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"unknown token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The Realtime connection: the test plays the server's events in and sees what was sent and whether it was closed.
final class FakeConnection: VoiceConnection, @unchecked Sendable {
    var onEvent: (@MainActor ([String: Any]) -> Void)?
    /// The connection dropping, with the reason.
    var onClosed: (@MainActor (String) -> Void)?
    private(set) var closed = false
    private(set) var sent: [[String: Any]] = []
    private(set) var liveAnswer: String?
    private(set) var remoteVolume = 1.0
    @MainActor var remoteSpeech = false
    func connect(secret: String, microphone: Bool, direct: Bool) async throws {}
    func connectLive(microphone: Bool, direct: Bool, exchange: (String) async throws -> String) async throws {
        liveAnswer = try await exchange("sdp-offer")
    }
    func send(_ event: [String: Any]) -> Bool { sent.append(event); return true }
    func setRemoteVolume(_ value: Double) { remoteVolume = value }
    func hasRemoteSpeech() async -> Bool { await MainActor.run { remoteSpeech } }
    func diagnose(_ write: @escaping @MainActor (String) -> Void) {}
    func close() { closed = true }
    @MainActor func play(_ events: [String: Any]...) { for event in events { onEvent?(event) } }
    @MainActor func backend(_ type: String, _ fields: [String: Any] = [:], delegation: String? = "d1") {
        play(["type": "response.event", "delegation_id": delegation as Any? ?? NSNull(), "event": fields.merging(["type": type]) { _, type in type }])
    }
    @MainActor func call(_ id: String, _ name: String, arguments: String = "{}", delegation: String? = "d1") {
        backend("response.output_item.done", ["item": ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]], delegation: delegation)
    }
    /// The text of every system note sent on this connection.
    var notes: [String] {
        sent.compactMap { event in
            guard let item = event["item"] as? [String: Any], item["role"] as? String == "system" else { return nil }
            return ((item["content"] as? [[String: Any]])?.first?["text"] as? String)
        }
    }
}

/// Time the test moves by hand: a wait finishes once the test has advanced past its end.
@MainActor
final class FakeTime {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var waiting: [(until: Date, done: CheckedContinuation<Void, Never>)] = []

    var clock: VoiceClock {
        VoiceClock(now: { self.now }, sleep: { duration in
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let until = self.now.addingTimeInterval(seconds)
            await withCheckedContinuation { self.waiting.append((until, $0)) }
        })
    }

    func advance(_ seconds: TimeInterval) async {
        await settle()
        now += seconds
        let due = waiting.filter { $0.until <= now }
        waiting.removeAll { $0.until <= now }
        due.forEach { $0.done.resume() }
        await settle()
    }

    /// Lets the model's own tasks (a step, a wait) run up to their next suspension.
    func settle() async { for _ in 0..<50 { await Task.yield() } }
}

private actor VoiceRunnerTransport: HTTPTransport {
    let firstStarted: XCTestExpectation
    let firstMayFinish: AsyncStream<Void>
    private(set) var operations: [String] = []

    init(firstStarted: XCTestExpectation, firstMayFinish: AsyncStream<Void>) {
        self.firstStarted = firstStarted
        self.firstMayFinish = firstMayFinish
    }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        operations.append(url.path)
        if url.path == "/first" {
            firstStarted.fulfill()
            for await _ in firstMayFinish { break }
        }
        return (200, Data(#"{"value":{}}"#.utf8))
    }
}

@MainActor
final class VoiceModelTests: XCTestCase {
    func testAConnectionWhoseSessionNeverStartsEndsAfterSixtySeconds() async {
        let h = Harness()
        await h.connect()
        XCTAssertEqual(h.voice.phase, .connecting)
        await h.time.advance(59)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn, "a silent session must release the microphone")
        XCTAssertTrue(h.link.closed)
        XCTAssertEqual(h.microphone, [true, false])
    }

    func testLiveCancelToolStopsRunningDelegationAndAllowsTheNextTask() async {
        let time = FakeTime()
        var executed: [String] = []
        let h = Harness(time: time, phoneTool: { name, _ in
            executed.append(name)
            if name == "look" { await time.clock.sleep(.seconds(1)) }
            return ("mock result", false, nil)
        })
        await h.liveTalk()
        XCTAssertEqual(h.link.liveAnswer, "sdp-answer")
        h.link.play(["type": "session.input_transcript.delta", "delta": "打开微信", "start_ms": 0, "end_ms": 400],
                    ["type": "session.delegation.created", "delegation": ["id": "d1"]])
        h.link.call("read", "look")
        await time.settle()
        XCTAssertEqual(executed, ["look"])
        h.link.play(["type": "session.input_transcript.delta", "delta": "请先别把这条消息发出去", "start_ms": 500, "end_ms": 800],
                    ["type": "session.delegation.created", "delegation": ["id": "cancel"]])
        h.link.call("queued", "do")
        h.link.call("stop", "cancel_current_task", delegation: "cancel")
        h.link.call("later", "do")
        h.link.call("unscoped", "do", delegation: nil)
        await time.advance(1)
        XCTAssertEqual(h.voice.lines.filter { $0.role == .you }.map(\.text).joined(), "打开微信请先别把这条消息发出去")
        XCTAssertEqual(executed, ["look"], "Only the phone step already executing may finish.")
        let results = h.link.sent.filter { $0["type"] as? String == "response.item.create" }
            .compactMap { ($0["item"] as? [String: String])?["call_id"] }
        XCTAssertEqual(Set(results), ["read", "stop", "queued", "later", "unscoped"])
        XCTAssertFalse(h.link.sent.contains { $0["type"] as? String == "response.create" })

        h.link.play(["type": "session.input_transcript.delta", "delta": "打开设置", "start_ms": 1500, "end_ms": 1900],
                    ["type": "session.delegation.created", "delegation": ["id": "d2"]])
        h.link.call("stop", "cancel_current_task", delegation: "cancel")
        h.link.call("old-task", "do")
        h.link.call("new-task", "open_app", delegation: "d2")
        await time.settle()
        XCTAssertEqual(executed, ["look", "open_app"])
        h.voice.stop()
    }

    func testLiveShortStopQuietsPlaybackWithoutCancellingPhoneWork() async {
        for stop in [["停"], ["停止"], ["别动"], [" stop. "], [" 停", ",别", "做了"], ["停，别做了"]] {
            var executed: [String] = []
            let h = Harness(phoneTool: { name, _ in
                executed.append(name)
                return ("mock result", false, nil)
            })
            await h.liveTalk()
            h.link.play(["type": "session.input_transcript.delta", "delta": "给文件传输助手发个hello", "start_ms": 0, "end_ms": 400],
                        ["type": "session.delegation.created", "offset_ms": 400, "delegation": ["id": "d1"]])
            h.link.call("started", "open_app")
            await h.time.settle()
            h.link.remoteSpeech = true
            await h.time.advance(0.2)
            XCTAssertEqual(h.link.remoteVolume, 1)
            for (index, text) in stop.enumerated() {
                let start = 500 + index * 200
                h.link.play(["type": "session.input_transcript.delta", "delta": text, "start_ms": start, "end_ms": start + 200])
            }
            XCTAssertEqual(h.link.remoteVolume, 0, "\(stop.joined()) must immediately mute the current reply.")
            h.link.play(["type": "session.input_transcript.delta", "delta": "好的。", "start_ms": 1200, "end_ms": 1400])
            XCTAssertEqual(h.link.remoteVolume, 0, "An acknowledgment must not bring the stopped reply back.")
            h.link.call("next-step", "do")
            await h.time.settle()
            XCTAssertEqual(executed, ["open_app", "do"], "Playback control alone must leave the delegated work intact.")
            h.voice.stop()
        }
    }

    func testLiveBackchannelsKeepPlaybackAndDoNotStartOrCancelPhoneWork() async {
        for acknowledgment in ["嗯。", "好的。"] {
            var executed: [String] = []
            let h = Harness(phoneTool: { name, _ in
                executed.append(name)
                return ("mock result", false, nil)
            })
            await h.liveTalk()
            h.link.play(["type": "session.delegation.created", "delegation": ["id": "d1"]])
            h.link.call("already-started", "look")
            await h.time.settle()
            h.link.remoteSpeech = true
            await h.time.advance(0.2)
            h.link.play(["type": "session.input_transcript.delta", "delta": acknowledgment, "start_ms": 500, "end_ms": 750],
                        ["type": "session.delegation.created", "delegation": ["id": "ack"]])
            h.link.call("unrequested", "open_app", delegation: "ack")
            h.link.call("unrequested-cancel", "cancel_current_task", delegation: "ack")
            h.link.call("continue", "do")
            await h.time.settle()
            XCTAssertEqual(h.link.remoteVolume, 1)
            XCTAssertEqual(executed, ["look", "do"], "An acknowledgment must leave the existing task intact.")
            h.voice.stop()
        }
    }

    func testLiveOnlySuppressesIdenticalWholeTurnsWithinTwoSeconds() async {
        var operations: [String] = []
        let h = Harness(phoneTool: { _, arguments in
            operations.append(arguments)
            return ("verified result", false, nil)
        })
        await h.liveTalk()
        let turns: [(id: String, segments: [String], end: Int)] = [
            ("original", ["打开", "微信"], 500),
            ("repeated", [" 打开微信！ "], 2_500),
            ("similar", ["打开微信", "设置"], 3_000),
            ("later", ["打开微信"], 4_650),
        ]
        for turn in turns {
            for (index, delta) in turn.segments.enumerated() {
                let end = turn.end - (turn.segments.count - index - 1) * 200
                h.link.play(["type": "session.input_transcript.delta", "delta": delta, "start_ms": end - 200, "end_ms": end])
            }
            h.link.play(["type": "session.delegation.created", "offset_ms": turn.end, "delegation": ["id": turn.id]])
            h.link.call(turn.id, "do", arguments: turn.id, delegation: turn.id)
            await h.time.settle()
        }
        XCTAssertEqual(operations, ["original", "similar", "later"])
        h.voice.stop()
    }

    func testRealtimeOnlyRequestsOneResponsePerCommittedUserItem() async {
        let h = Harness()
        await h.connect()
        h.link.play(["type": "session.created", "session": ["audio": ["input": ["turn_detection": ["create_response": false]]]]])
        func commit(_ item: String) {
            h.link.play(["type": "input_audio_buffer.speech_started", "item_id": item],
                        ["type": "input_audio_buffer.speech_stopped", "item_id": item],
                        ["type": "input_audio_buffer.committed", "item_id": item])
        }
        func responseCount() -> Int { h.link.sent.filter { $0["type"] as? String == "response.create" }.count }

        commit("item-1")
        XCTAssertEqual(responseCount(), 1)
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.done", "response": ["id": "r1"]])
        h.link.play(["type": "input_audio_buffer.committed", "item_id": "item-1"])
        XCTAssertEqual(responseCount(), 1)

        commit("item-2")
        XCTAssertEqual(responseCount(), 2)
        h.voice.stop()
    }

    func testLiveStopPreventsTheNextRunnerRequestInAnActiveBatch() async {
        let firstStarted = expectation(description: "the first phone request entered the runner")
        let batchFinished = expectation(description: "the batch reported its result")
        let (firstMayFinish, releaseFirst) = AsyncStream<Void>.makeStream()
        let transport = VoiceRunnerTransport(firstStarted: firstStarted, firstMayFinish: firstMayFinish)
        let runner = Runner(url: URL(string: "http://voice-runner.test")!, transport: transport)
        let h = Harness(phoneTool: { _, _ in
            defer { batchFinished.fulfill() }
            do {
                _ = try await runner.raw("POST", "/first")
                _ = try await runner.raw("POST", "/second")
                return ("both requests sent", false, nil)
            } catch {
                return ("the batch stopped before the second request", true, nil)
            }
        })
        await h.liveTalk()
        h.link.play(["type": "session.delegation.created", "delegation": ["id": "d1"]])
        h.link.call("batch", "do")
        await fulfillment(of: [firstStarted], timeout: 2)
        h.link.play(["type": "session.input_transcript.delta", "delta": "请先别把这条消息发出去", "start_ms": 100, "end_ms": 300],
                    ["type": "session.delegation.created", "delegation": ["id": "cancel"]])
        h.link.call("cancel-batch", "cancel_current_task", delegation: "cancel")
        releaseFirst.finish()
        await fulfillment(of: [batchFinished], timeout: 2)
        let operations = await transport.operations
        XCTAssertEqual(operations, ["/first"])
        h.voice.stop()
    }

    func testLiveCancellationWithRecordedServerEvents() async throws {
        guard let replay = ProcessInfo.processInfo.environment["POKI_VOICE_STOP_REPLAY"] else {
            throw XCTSkip("This check replays events from the Live service captured by the desktop speech check.")
        }
        let scenarios = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(replay.utf8)) as? [String: [[String: Any]]])
        for scenario in ["stop", "stop_explicit", "literal"] {
            let events = try XCTUnwrap(scenarios[scenario])
            var executed: [(name: String, arguments: String)] = []
            let h = Harness(phoneTool: { name, arguments in
                executed.append((name, arguments))
                return ("mock result", false, nil)
            })
            await h.liveTalk()
            var muteAfterStopCaption: Double?
            for event in events {
                h.link.play(event)
                if event["type"] as? String == "session.input_transcript.delta",
                   (event["delta"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "停" {
                    muteAfterStopCaption = h.link.remoteVolume
                }
                await h.time.settle()
            }
            if scenario == "literal" {
                XCTAssertTrue(executed.contains { $0.name == "do" && $0.arguments.contains("停") })
                XCTAssertEqual(muteAfterStopCaption, 1)
            } else {
                XCTAssertEqual(muteAfterStopCaption, 0, "Playback must stop on the recorded \(scenario).")
                XCTAssertTrue(executed.contains { $0.name == "do" }, "Phone work can continue until the semantic cancellation is received.")
            }
            h.voice.stop()
        }
    }

    func testLiveDictatesTheWordStopWhenItCompletesTheSameUtterance() async {
        for (prefix, suffix) in [("在备忘录输入", ""), ("把", "字发过去")] {
            var written: [String] = []
            let h = Harness(phoneTool: { _, arguments in
                written.append(arguments)
                return ("Text entered in Notes", false, nil)
            })
            await h.liveTalk()
            h.link.play(["type": "session.input_transcript.delta", "delta": prefix, "start_ms": 0, "end_ms": 700],
                        ["type": "session.input_transcript.delta", "delta": "停", "start_ms": 950, "end_ms": 1200],
                        ["type": "session.input_transcript.delta", "delta": suffix, "start_ms": 1200, "end_ms": 1500],
                        ["type": "session.delegation.created", "delegation": ["id": "d1"]])
            let arguments = #"{"actions":[{"type":"停"}]}"#
            h.link.call("write-stop", "do", arguments: arguments)
            await h.time.settle()
            XCTAssertEqual(written, [arguments], "The tool must receive the requested text for \(prefix)停\(suffix).")
            h.voice.stop()
        }
    }

    func testLiveCarryOverKeepsTheLatestCorrectionWithinTheNoteLimit() async throws {
        let h = Harness()
        await h.liveTalk()
        let messages: [(String, String)] = [
            ("input", String(repeating: "计划第一站到车站，买一张回程的车票。", count: 7)),
            ("output", String(repeating: "好的，我已记下车站和回程车票的安排。", count: 7)),
            ("input", "第二站去书店，最后一站去邮局。"),
            ("output", "最后一站记为邮局。"),
            ("input", "把最后一站改成花店。"),
            ("output", "好的，最后一站改成花店。" + String(repeating: "前面的安排保持原样。", count: 26)),
        ]
        for (i, message) in messages.enumerated() {
            h.link.play(["type": "session.\(message.0)_transcript.delta", "delta": message.1,
                         "start_ms": i * 1000, "end_ms": i * 1000 + 300])
        }
        h.voice.stop()
        await h.time.advance(4 * 60)
        await h.liveTalk()
        let event = try XCTUnwrap(h.link.sent.first { $0["type"] as? String == "session.instructions.append" })
        let context = try XCTUnwrap(event["content"] as? String)
        XCTAssertLessThanOrEqual(context.utf8.count, 480)
        let user = try XCTUnwrap(context.range(of: "User: 把最后一站改成花店。"))
        let poki = try XCTUnwrap(context.range(of: "Poki: 好的，最后一站改成花店。"))
        XCTAssertLessThan(user.lowerBound, poki.lowerBound)
        XCTAssertFalse(context.contains("计划第一站到车站"))
        h.voice.stop()
    }

    func testLiveCarryOverKeepsTheWholeRequestWhenItFitsWithTheReply() async throws {
        let h = Harness()
        await h.liveTalk()
        let request = "请更新明天的行程，上午的车次、取件时间和中午见面的地点都保持原样。把最后一站改成花店，回程仍然坐之前订好的那班车，回家以后提醒我把当天的收据整理好。"
        h.link.play(["type": "session.input_transcript.delta", "delta": request, "start_ms": 0, "end_ms": 6000],
                    ["type": "session.output_transcript.delta", "delta": "好的。", "start_ms": 6100, "end_ms": 6300])
        h.voice.stop()
        await h.time.advance(4 * 60)
        await h.liveTalk()
        let event = try XCTUnwrap(h.link.sent.first { $0["type"] as? String == "session.instructions.append" })
        let context = try XCTUnwrap(event["content"] as? String)
        XCTAssertLessThanOrEqual(context.utf8.count, 480)
        XCTAssertTrue(context.contains("User: \(request)\nPoki: 好的。"), "The latest request and reply fit with the correction intact.")
        h.voice.stop()
    }

    func testLiveReconnectReportsTheCompletedResultUntilAcknowledged() async throws {
        var executed = 0
        let result = "操作已完成。草稿已保存。"
        let h = Harness(phoneTool: { _, _ in
            executed += 1
            return (result, false, nil)
        })
        await h.liveTalk()
        let payload = String(repeating: "甲", count: 1400)
        h.link.call("saved-draft", "do", arguments: #"{"actions":[{"type":"\#(payload)"}]}"#)
        h.link.onClosed?("connection dropped while the action ran")
        await h.time.settle()
        await h.liveTalk()
        func report() -> [String: Any]? { h.link.sent.first { $0["type"] as? String == "session.commentary.append" } }
        let content = try XCTUnwrap(report()?["content"] as? String)
        XCTAssertTrue(content.contains(result))
        XCTAssertLessThanOrEqual(content.utf8.count, 500)
        h.link.play(["type": "session.commentary.appended", "client_event_id": "unrelated"])
        h.link.onClosed?("connection dropped before acknowledgment")
        await h.liveTalk()
        XCTAssertTrue((report()?["content"] as? String)?.contains(result) == true)
        if let eventID = report()?["event_id"] as? String {
            h.link.play(["type": "session.commentary.appended", "client_event_id": eventID])
            h.link.onClosed?("connection dropped after acknowledgment")
            await h.liveTalk()
            XCTAssertNil(report())
        } else {
            XCTFail("Reconnect result has no ID to match an acknowledgment.")
        }
        XCTAssertEqual(executed, 1)
        h.voice.stop()
    }

    func testLiveConsecutiveScreensUseIndependentVisionRequests() async {
        let h = Harness(phoneTool: { _, arguments in
            let screenshot = arguments.contains("first") ? "first synthetic screenshot" : "second synthetic screenshot"
            return ("Screen elements", false, Data(screenshot.utf8))
        })
        await h.liveTalk(address: BridgeStub.secureLiveAddress)
        for name in ["First", "Second"] {
            let id = name.lowercased()
            h.link.call(id, "look", arguments: #"{"page":"\#(id)"}"#)
            if h.link.sent.contains(where: { (($0["item"] as? [String: String])?["call_id"]) == id }) == false {
                let sent = expectation(for: NSPredicate { _, _ in
                    h.link.sent.contains { (($0["item"] as? [String: String])?["call_id"]) == id }
                }, evaluatedWith: nil)
                await fulfillment(of: [sent], timeout: 2)
            }
            let output = h.link.sent.compactMap { $0["item"] as? [String: String] }.first { $0["call_id"] == id }?["output"] ?? ""
            XCTAssertTrue(output.contains("\(name) screen description"))
            let other = name == "First" ? "Second" : "First"
            XCTAssertFalse(output.contains("\(other) screen description"))
        }
        XCTAssertFalse(h.link.sent.contains { event in
            let item = event["item"] as? [String: Any]
            return (item?["content"] as? [[String: String]])?.contains { $0["type"] == "input_image" } == true
        }, "No screenshot may stay in the Live backend conversation.")
        XCTAssertEqual(BridgeStub.screenshotSchemes, ["https", "https"])
        h.voice.stop()
    }

    func testLiveHTTPBridgeReturnsScreenElementsWithoutUploadingTheScreenshot() async {
        let h = Harness(phoneTool: { _, _ in
            ("Screen elements: 1. Notes title", false, Data("first synthetic screenshot".utf8))
        })
        await h.liveTalk()
        h.link.call("plain-http-screen", "look")
        let sent = expectation(for: NSPredicate { _, _ in
            h.link.sent.contains { ($0["item"] as? [String: String])?["call_id"] == "plain-http-screen" }
        }, evaluatedWith: nil)
        await fulfillment(of: [sent], timeout: 2)
        let output = h.link.sent.compactMap { $0["item"] as? [String: String] }
            .first { $0["call_id"] == "plain-http-screen" }?["output"] ?? ""
        XCTAssertTrue(output.contains("Screen elements: 1. Notes title"))
        XCTAssertTrue(output.contains("Use the screen elements"))
        XCTAssertTrue(BridgeStub.screenshotSchemes.isEmpty, "The phone must never make a screenshot request to an HTTP bridge.")
        h.voice.stop()
    }

    private var savedBridge: String?
    private var savedDirect: Any?

    override func setUp() {
        savedBridge = UserDefaults.standard.string(forKey: "voiceBridge")
        savedDirect = UserDefaults.standard.object(forKey: "voice.openai.enabled")
        // The token comes from the stubbed bridge, never from an OpenAI key this simulator may hold.
        VoiceDirect.enabled = false
        BridgeStub.resetScreenshots()
        URLProtocol.registerClass(BridgeStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(BridgeStub.self)
        UserDefaults.standard.set(savedBridge, forKey: "voiceBridge")
        UserDefaults.standard.set(savedDirect, forKey: "voice.openai.enabled")
    }

    /// One VoiceModel with its connections (one per conversation), its time, and what Poki was told about
    /// the microphone (true: the voice session holds it).
    private final class Harness {
        let voice: VoiceModel
        let time: FakeTime
        private(set) var links: [FakeConnection] = []
        private(set) var microphone: [Bool] = []
        var link: FakeConnection { links.last! }

        @MainActor init(time: FakeTime? = nil, phoneTool: @escaping @MainActor (String, String) async -> PhoneAnswer = { _, _ in ("", false, nil) }) {
            let time = time ?? FakeTime()
            self.time = time
            var made: (() -> FakeConnection)!
            var held: ((Bool) -> Void)!
            voice = VoiceModel(clearTap: { _, _, _ in .clear }, phoneTool: { name, arguments, cancellation in
                await PhoneOperationCancellation.$current.withValue(cancellation) { await phoneTool(name, arguments) }
            }, holdMicrophone: { held($0) },
                               connection: { onEvent, onClosed in let link = made(); link.onEvent = onEvent; link.onClosed = onClosed; return link }, time: time.clock)
            made = { [unowned self] in let link = FakeConnection(); self.links.append(link); return link }
            held = { [unowned self] in self.microphone.append($0) }
            _ = voice.setBridge(BridgeStub.address)
            // As in the app: an ended conversation goes into the chat, and its lines leave the voice model.
            voice.onConversationEnded = { _, _ in }
        }

        /// Connected, before the server's session.created.
        @MainActor func connect() async { await voice.start() }

        @MainActor func liveTalk(address: String = BridgeStub.liveAddress) async {
            _ = voice.setBridge(address)
            await connect()
            link.play(["type": "session.started"])
        }

        /// Connected and listening.
        @MainActor func talk() async {
            await voice.start()
            link.play(["type": "session.created"])
        }

        /// The person says `said` and Poki answers `answer` out loud.
        @MainActor func turn(_ said: String, _ answer: String, id: String) {
            link.play(["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"],
                      ["type": "conversation.item.input_audio_transcription.completed", "transcript": said],
                      ["type": "response.created", "response": ["id": id]], ["type": "output_audio_buffer.started"],
                      ["type": "response.output_audio_transcript.done", "transcript": answer],
                      ["type": "response.done", "response": ["id": id]], ["type": "output_audio_buffer.stopped"])
        }
    }

    /// Said once, answered once: the conversation waits 8 s for the person to go on, then ends and lets
    /// go of the microphone, so iOS's microphone dot goes off instead of Poki listening on.
    func testTheConversationEndsWhenNobodySpeaksForEightSecondsAfterTheAnswer() async {
        let h = Harness()
        await h.talk()
        h.turn("What iOS version is this?", "iOS 26.1.", id: "r1")
        await h.time.advance(7)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn)
        XCTAssertTrue(h.link.closed)
        XCTAssertEqual(h.voice.phase, .off)
        XCTAssertEqual(h.microphone, [true, false])
    }

    /// Talk to Poki and then nothing said: the same 8 s end it.
    func testTheConversationEndsWhenNobodySpeaksForEightSecondsAfterItOpens() async {
        let h = Harness()
        await h.talk()
        await h.time.advance(7)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn)
        XCTAssertEqual(h.microphone, [true, false])
    }

    /// Speech the server answers only with an error: no answer is coming, so the 8 s still end it.
    func testSpeechAnsweredOnlyWithAnErrorStillEndsAfterEightSeconds() async {
        let h = Harness()
        await h.talk()
        h.link.play(["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"],
                    ["type": "error", "error": ["message": "Conversation already has an active response"]])
        await h.time.advance(8)
        XCTAssertFalse(h.voice.isOn)
    }

    /// Speaking again within the 8 s goes on in the same conversation: the model keeps what was said.
    func testSpeakingAgainWithinEightSecondsGoesOnInTheSameConversation() async {
        let h = Harness()
        await h.talk()
        h.turn("Open Settings.", "Settings is open.", id: "r1")
        await h.time.settle()
        h.link.play(["type": "input_audio_buffer.speech_started"])
        await h.time.advance(8)
        XCTAssertTrue(h.voice.isOn)
        XCTAssertEqual(h.links.count, 1)
        XCTAssertFalse(h.link.closed)
    }

    /// Talking again within 5 minutes of the end: the new conversation is told what was said last time,
    /// so Poki does not start from nothing. Later than that, it starts fresh.
    func testANewConversationWithinFiveMinutesIsToldTheLastTurns() async {
        let h = Harness()
        await h.talk()
        h.turn("Open Settings.", "Settings is open.", id: "r1")
        await h.time.advance(8)
        XCTAssertFalse(h.voice.isOn)

        await h.time.advance(4 * 60)
        await h.talk()
        let carried = h.link.notes.joined(separator: "\n")
        XCTAssertTrue(carried.contains("Open Settings."), carried)
        XCTAssertTrue(carried.contains("Settings is open."), carried)
        h.turn("Turn on Wi-Fi.", "Wi-Fi is on.", id: "r2")
        h.voice.stop()

        // Only the last conversation's lines, not the ones before it.
        await h.time.advance(60)
        await h.talk()
        let again = h.link.notes.joined(separator: "\n")
        XCTAssertTrue(again.contains("Turn on Wi-Fi."), again)
        XCTAssertFalse(again.contains("Open Settings."), again)
        h.voice.stop()

        await h.time.advance(5 * 60 + 1)
        await h.talk()
        XCTAssertFalse(h.link.notes.joined().contains("Wi-Fi"))
    }

    /// A step that finishes while its request's answer is still out: the conversation stays until the
    /// answer that carries the result has played.
    func testAStepsResultIsSaidBeforeTheConversationEnds() async {
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false, nil) })
        await h.talk()
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": #"{"goal":"open Settings"}"#]])
        await h.time.settle()
        XCTAssertEqual(h.voice.calls.first?.delivered, true)
        h.link.play(["type": "response.done", "response": ["id": "r1"]])
        await h.time.advance(8)
        XCTAssertTrue(h.voice.isOn)
        h.link.play(["type": "response.created", "response": ["id": "r2"]], ["type": "output_audio_buffer.started"],
                    ["type": "response.done", "response": ["id": "r2"]], ["type": "output_audio_buffer.stopped"])
        await h.time.advance(8)
        XCTAssertFalse(h.voice.isOn)
    }

    /// You switch to another app during a talk and it goes on (the owner, 2026-11-13): Poki still listens,
    /// the microphone stays with it and the Live Activity says so, also when it was still connecting. It
    /// ends there as it does in front: 8 s after an answer if nobody speaks.
    func testATalkGoesOnWhenPokiGoesToTheBackground() async {
        let h = Harness()
        await h.talk()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(h.voice.isOn)
        XCTAssertFalse(h.link.closed)
        XCTAssertEqual(h.microphone, [true])
        XCTAssertEqual(h.voice.talkState, .listening)
        XCTAssertEqual(TalkActivity.state(of: h.voice), .listening)
        h.turn("Open Settings.", "Settings is open.", id: "r1")
        XCTAssertTrue(h.voice.isOn, "an answer said in the background does not end the talk")
        await h.time.advance(7)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn)
        XCTAssertEqual(h.microphone, [true, false])
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        let connecting = Harness()
        let opening = Task { await connecting.connect() }
        for _ in 0..<1000 where connecting.voice.phase != .connecting { await Task.yield() }
        XCTAssertEqual(connecting.voice.phase, .connecting)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await opening.value
        XCTAssertTrue(connecting.voice.isOn)
        XCTAssertEqual(connecting.links.count, 1)
        XCTAssertEqual(connecting.microphone, [true])
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// An error that is not about the request for the step's answer (a stale cancel, say) leaves that
    /// answer expected: the talk waits for it. The error that is about it means no answer is coming, and
    /// the talk ends after the 8 s it gives the person to go on.
    func testOnlyAnErrorForTheAnswerRequestGivesUpOnTheAnswer() async {
        for ownError in [false, true] {
            let (step, stepDone) = AsyncStream<Void>.makeStream()
            let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false, nil) })
            await h.talk()
            h.link.play(["type": "response.created", "response": ["id": "r1"]],
                        ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": "{}"]],
                        ["type": "response.done", "response": ["id": "r1"]])
            stepDone.finish()
            await h.time.settle()
            let request = h.link.sent.last { $0["type"] as? String == "response.create" }
            XCTAssertNotNil(request)
            let id = request?["event_id"] as? String
            XCTAssertNotNil(id, "the request for the answer carries an id its error can name")

            h.link.play(["type": "error", "error": ["message": "x", "event_id": ownError ? id ?? "" : "event_other"]])
            await h.time.advance(8)
            XCTAssertEqual(h.voice.isOn, !ownError, ownError ? "the answer request failed, nothing is coming" : "an unrelated error ended it before the answer")
        }
    }

    /// A conversation in which nobody said anything does not wipe what the one before it said: a third
    /// opened within 5 minutes of that one still hears it.
    func testASilentConversationInBetweenKeepsTheLastTurnsToCarryOver() async {
        let h = Harness()
        await h.talk()
        h.turn("Open Settings.", "Settings is open.", id: "r1")
        h.voice.stop()

        await h.time.advance(30)
        await h.talk()
        await h.time.advance(8)
        XCTAssertFalse(h.voice.isOn)

        await h.time.advance(30)
        await h.talk()
        let carried = h.link.notes.joined(separator: "\n")
        XCTAssertTrue(carried.contains("Open Settings."), carried)
        XCTAssertTrue(carried.contains("Settings is open."), carried)
    }

    /// A step's result is handed over and the server's answer to the request never comes (its error names
    /// no request, so Poki cannot tell it is about this one): the conversation does not wait for ever.
    /// 60 s without a word from the server in the foreground ends it.
    func testAnAnswerThatNeverComesEndsTheConversationAfterSixtySecondsInTheForeground() async {
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false, nil) })
        await h.talk()
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": "{}"]],
                    ["type": "response.done", "response": ["id": "r1"]])
        await h.time.settle()
        h.link.play(["type": "error", "error": ["message": "x"]])
        await h.time.advance(59)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn)
        XCTAssertEqual(h.microphone, [true, false])
    }

    /// The same in the background, and the person's microphone is off 30 s after Poki went there, counted
    /// from going there and not from the start of the conversation. Speech whose end never arrives is the
    /// same wait.
    func testAnAnswerThatNeverComesEndsTheConversationThirtySecondsAfterTheBackground() async {
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false, nil) })
        await h.talk()
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": "{}"]],
                    ["type": "response.done", "response": ["id": "r1"]])
        await h.time.settle()
        h.link.play(["type": "error", "error": ["message": "x"]])
        await h.time.advance(20)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await h.time.advance(29)
        XCTAssertTrue(h.voice.isOn)
        await h.time.advance(1)
        XCTAssertFalse(h.voice.isOn)
        XCTAssertEqual(h.microphone, [true, false])

        let hearing = Harness()
        await hearing.talk()
        hearing.link.play(["type": "input_audio_buffer.speech_started"])
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await hearing.time.advance(29)
        XCTAssertTrue(hearing.voice.isOn)
        await hearing.time.advance(1)
        XCTAssertFalse(hearing.voice.isOn)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// The cap is for waiting on the server. A step that runs for minutes in the background is not cut
    /// off, and its result is still said.
    func testAStepRunningLongerThanTheCapInTheBackgroundIsNotCutOff() async {
        let (step, stepDone) = AsyncStream<Void>.makeStream()
        let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false, nil) })
        await h.talk()
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": "{}"]],
                    ["type": "response.done", "response": ["id": "r1"]])
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await h.time.advance(100)
        XCTAssertTrue(h.voice.isOn)
        stepDone.finish()
        await h.time.settle()
        XCTAssertEqual(h.voice.calls.first?.delivered, true)
        await h.time.advance(29)
        XCTAssertTrue(h.voice.isOn, "the wait for the answer starts when the result is handed over")
        h.link.play(["type": "response.created", "response": ["id": "r2"]], ["type": "output_audio_buffer.started"],
                    ["type": "response.done", "response": ["id": "r2"]], ["type": "output_audio_buffer.stopped"])
        XCTAssertTrue(h.voice.isOn, "the result said, the talk waits for the person to go on")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }
}

/// OpenAI's client_secrets endpoint, served without the network: it keeps the session Poki asked for.
final class OpenAIStub: URLProtocol {
    nonisolated(unsafe) static var session: [String: Any]?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "api.openai.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = requestBody(request)
        Self.session = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["session"] as? [String: Any]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let reply = request.url?.path() == "/v1/live/sessions" ? #"{"transport":{"sdp":"sdp-answer"}}"# : #"{"value":"ek_test"}"#
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VoiceLanguageTests: XCTestCase {
    func testDirectLiveVoiceInstructionsAskForTheResultOnly() async throws {
        URLProtocol.registerClass(OpenAIStub.self)
        defer { URLProtocol.unregisterClass(OpenAIStub.self) }
        let answer = try await VoiceDirect.exchangeLiveOffer("offer", model: "gpt-live-1.1", apiKey: "sk-test")
        XCTAssertEqual(answer, "sdp-answer")
        let prompt = try XCTUnwrap(OpenAIStub.session?["instructions"] as? String)
        for rule in ["Act first, then talk.", "Say nothing before or between tool calls.", "Give the verified result in one short sentence."] {
            XCTAssertTrue(prompt.contains(rule), rule)
        }
    }

    func testDirectLiveOfferExposesCancellationOnlyInLive() async throws {
        URLProtocol.registerClass(OpenAIStub.self)
        defer { URLProtocol.unregisterClass(OpenAIStub.self) }
        _ = try await VoiceDirect.exchangeLiveOffer("offer", model: "gpt-live-1.1", apiKey: "sk-test")
        let session = try XCTUnwrap(OpenAIStub.session)
        let delegation = try XCTUnwrap(session["delegation"] as? [String: Any])
        let backend = try XCTUnwrap(delegation["responses"] as? [String: Any])
        let tools = try XCTUnwrap(backend["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first { $0["name"] as? String == "cancel_current_task" })
        for owner in [session, backend] {
            let prompt = try XCTUnwrap(owner["instructions"] as? String)
            XCTAssertTrue(prompt.contains("cancel_current_task"))
            XCTAssertTrue(prompt.contains("把停字发过去"))
        }
        let realtime = try XCTUnwrap(VoiceDirect.session["tools"] as? [[String: Any]])
        XCTAssertFalse(realtime.contains { $0["name"] as? String == "cancel_current_task" })
    }

    func testTheLiveSessionHintsChineseTranscriptionWithoutChangingReplyLanguageRules() async throws {
        URLProtocol.registerClass(OpenAIStub.self)
        defer { URLProtocol.unregisterClass(OpenAIStub.self) }
        _ = try await VoiceDirect.token(apiKey: "sk-test")
        let session = try XCTUnwrap(OpenAIStub.session)
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Speak another language only when the user's latest turn is clearly in it."), instructions)
        XCTAssertTrue(instructions.contains("Tool results, screen text, screenshots and notes from Poki never choose your language."), instructions)
        let transcription = ((session["audio"] as? [String: Any])?["input"] as? [String: Any])?["transcription"] as? [String: Any]
        XCTAssertNotNil(transcription)
        XCTAssertEqual(transcription?["language"] as? String, "zh", "input transcription uses the requested Chinese language hint")
    }
}

/// The Live Activity during a talk: it says what the talk is doing in the state's own `voice` field,
/// its End ends the talk, and an approval is never pushed aside by it.
extension VoiceModelTests {
    private func following(_ h: Harness) -> (ActivityController, TalkActivity) {
        let activity = ActivityController()
        return (activity, TalkActivity(voice: h.voice, activity: activity, deviceName: { "Test iPhone" }, keepsActivity: { false }))
    }

    func testLiveActivityWaitsForTheNextResponseAndMeasuresThePlayedAnswer() async {
        let h = Harness(phoneTool: { _, _ in ("Screen is open", false, nil) })
        let (activity, watcher) = following(h)
        activity.finishAfter = .seconds(60)
        await h.liveTalk()
        h.link.play(["type": "session.input_transcript.delta", "delta": "打开微信。", "start_ms": 0, "end_ms": 400],
                    ["type": "session.delegation.created", "delegation": ["id": "d1", "response_id": "r1"]])
        h.link.backend("response.created", ["response": ["id": "r1"]])
        h.link.call("open", "do")
        await h.time.settle()
        activity.update { $0.phase = .working; $0.headline = "Open WeChat" }
        activity.record(step: "Open WeChat", ok: true)
        XCTAssertTrue(h.link.sent.contains { $0["type"] as? String == "response.create" })
        h.link.backend("response.completed", ["response": ["id": "r1"]])
        await h.time.settle()
        XCTAssertEqual(activity.state.phase, .working, "The first response finished, but the continuation is still queued.")

        h.link.backend("response.created", ["response": ["id": "r2"]])
        h.link.backend("response.completed", ["response": ["id": "r2"]])
        h.link.play(["type": "session.output_transcript.delta", "delta": "微信已打开。", "start_ms": 1400, "end_ms": 1600])
        await h.time.settle()
        XCTAssertNil(h.voice.lastTurnMS, "A transcript is not proof that the answer started playing.")
        XCTAssertEqual(activity.state.phase, .working)
        h.link.remoteSpeech = true
        await h.time.advance(1.5)
        XCTAssertGreaterThanOrEqual(h.voice.lastTurnMS ?? 0, 1400)
        h.link.remoteSpeech = false
        for _ in 0..<3 { await h.time.advance(0.2) }
        XCTAssertEqual(activity.state.phase, .done)
        XCTAssertEqual(activity.state.face.content, "微信已打开。")
        h.voice.stop()
        withExtendedLifetime(watcher) {}
        activity.end()
    }

    /// ESP-954: a talk's run of steps finishes when the talk's turn is over, not by the quiet wait while
    /// Poki is still on the request. Between two steps it thinks and speaks, often longer than that
    /// wait, and the island said Done in the middle of a task that went on.
    func testATalksRunFinishesWhenItsTurnIsOverNotWhilePokiStillWorks() async throws {
        let h = Harness(phoneTool: { _, _ in ("WeChat is open", false, nil) })
        let (activity, watcher) = following(h)
        activity.finishAfter = .milliseconds(20)
        await h.talk()
        h.link.play(["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"],
                    ["type": "conversation.item.input_audio_transcription.completed", "transcript": "Tell Mom I'm late"],
                    ["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": "{}"]])
        await h.time.settle()
        // The step on the phone, as AppModel reports it to the Live Activity.
        activity.update { $0.phase = .working; $0.headline = "Open WeChat" }
        activity.record(step: "Open WeChat", ok: true)
        h.link.play(["type": "response.done", "response": ["id": "r1"]], ["type": "response.created", "response": ["id": "r2"]],
                    ["type": "output_audio_buffer.started"])
        try await Task.sleep(for: .milliseconds(150))
        await h.time.settle()
        XCTAssertEqual(activity.state.phase, .working, "Poki is still answering: the run goes on")

        h.link.play(["type": "response.output_audio_transcript.done", "transcript": "I told Mom you're late."],
                    ["type": "response.done", "response": ["id": "r2"]], ["type": "output_audio_buffer.stopped"])
        await h.time.settle()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(activity.state.phase, .done)
        XCTAssertEqual(activity.state.face.content, "I told Mom you're late.")
        withExtendedLifetime(watcher) {}
        activity.end()
    }

    func testTheLiveActivitySaysWhatTheTalkIsDoing() async {
        let h = Harness()
        let (activity, watcher) = following(h)
        await h.talk()
        await h.time.settle()
        XCTAssertEqual(activity.state.voice, .listening)
        XCTAssertEqual(activity.state.face.content, StatusWord.listening.text)
        XCTAssertTrue(activity.state.face.endsTalk)
        XCTAssertTrue(activity.state.face.talkGlow, "the island's brand band shows while a talk is on")
        XCTAssertTrue(activity.state.face.shieldsTaps, "a tap on the expanded island during a talk keeps the owner in their app")

        h.link.play(["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"],
                    ["type": "conversation.item.input_audio_transcription.completed", "transcript": "What iOS version is this?"],
                    ["type": "response.created", "response": ["id": "r1"]], ["type": "output_audio_buffer.started"])
        await h.time.settle()
        XCTAssertEqual(activity.state.voice, .speaking)
        XCTAssertEqual(activity.state.face.content, StatusWord.speaking.text)

        h.voice.stop()
        await h.time.settle()
        XCTAssertNil(activity.state.voice)
        XCTAssertFalse(activity.state.face.endsTalk)
        XCTAssertFalse(activity.state.face.talkGlow)
        withExtendedLifetime(watcher) {}
    }

    func testEndOnTheLiveActivityEndsTheTalk() async throws {
        let h = Harness()
        let (activity, watcher) = following(h)
        await h.talk()
        XCTAssertTrue(h.voice.isOn)
        let ended = expectation(for: NSPredicate { _, _ in !h.voice.isOn }, evaluatedWith: nil)
        _ = try await EndTalkIntent().perform()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertTrue(h.link.closed)
        await h.time.settle()
        XCTAssertNil(activity.state.voice)
        withExtendedLifetime(watcher) {}
    }

    func testAnApprovalDuringATalkKeepsTheLiveActivity() async {
        let h = Harness()
        let (activity, watcher) = following(h)
        await h.talk()
        await h.time.settle()
        let approval = PendingApproval(id: "a1", app: "Messages", summary: "Tap “Send”", reason: "sending", expires: Date().addingTimeInterval(120))
        activity.update { $0.phase = .approval; $0.approval = approval; $0.headline = "Allow this step?" }

        // Poki speaks while the approval waits: the approval keeps the card and the island, with no End.
        h.link.play(["type": "response.created", "response": ["id": "r1"]], ["type": "output_audio_buffer.started"])
        await h.time.settle()
        XCTAssertEqual(activity.state.phase, .approval)
        XCTAssertEqual(activity.state.face.bottom, .approval(id: "a1"))
        XCTAssertFalse(activity.state.face.endsTalk)

        // Answered: the talk is back on the Live Activity, with End.
        activity.update { $0.phase = .idle; $0.approval = nil; $0.headline = "Waiting for agent" }
        XCTAssertEqual(activity.state.face.content, StatusWord.speaking.text)
        XCTAssertTrue(activity.state.face.endsTalk)

        // A talk that ends while an approval waits leaves the approval where it is.
        activity.update { $0.phase = .approval; $0.approval = approval; $0.headline = "Allow this step?" }
        h.voice.stop()
        await h.time.settle()
        XCTAssertEqual(activity.state.phase, .approval)
        XCTAssertEqual(activity.state.approval, approval)
        XCTAssertNil(activity.state.voice)
        withExtendedLifetime(watcher) {}
    }
}

/// What the talk's screens say: one state, read by the message field's bar, the light along the bottom
/// edge and Poki's picture.
extension VoiceModelTests {
    /// Remove Address in Settings takes the Mac voice bridge's address, which carries the bridge's secret,
    /// off this iPhone: the talk running through it ends, nothing stays saved for the next launch, and
    /// with no OpenAI key Talk with Poki needs a key again.
    func testRemovingTheVoiceBridgeAddressEndsItsTalkAndLeavesNothingSaved() async {
        let h = Harness()
        await h.talk()
        XCTAssertTrue(h.voice.isOn)
        h.voice.removeBridge()
        XCTAssertFalse(h.voice.isOn)
        XCTAssertNil(h.voice.talkState)
        XCTAssertNil(h.voice.bridge)
        XCTAssertNil(UserDefaults.standard.string(forKey: "voiceBridge"))
        XCTAssertFalse(h.voice.canTalkLive)
    }

    /// A step that has Poki on the phone is not thinking, speech over an answer is not plain listening,
    /// and a dropped connection is still a state, with its reason, until it is put away.
    func testATalkSaysWhenPokiIsOnThePhoneIsSpokenOverOrIsCutOff() async {
        let (step, stepDone) = AsyncStream<Void>.makeStream()
        let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false, nil) })
        XCTAssertNil(h.voice.talkState)
        await h.talk()
        XCTAssertEqual(h.voice.talkState, .listening)

        h.link.play(["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"])
        XCTAssertEqual(h.voice.talkState, .thinking)
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": #"{"goal":"open Settings"}"#]],
                    ["type": "response.done", "response": ["id": "r1"]])
        XCTAssertEqual(h.voice.talkState, .acting)
        stepDone.finish()
        await h.time.settle()
        XCTAssertEqual(h.voice.talkState, .thinking)

        h.link.play(["type": "response.created", "response": ["id": "r2"]], ["type": "output_audio_buffer.started"])
        XCTAssertEqual(h.voice.talkState, .speaking)
        h.link.play(["type": "input_audio_buffer.speech_started"], ["type": "output_audio_buffer.cleared"])
        XCTAssertEqual(h.voice.talkState, .interrupted)
        await h.time.advance(1.4)
        XCTAssertEqual(h.voice.talkState, .hearing)

        h.link.onClosed?("gone")
        XCTAssertEqual(h.voice.talkState, .failed(TalkState.connectionLost))
        h.voice.dismissProblem()
        XCTAssertNil(h.voice.talkState)
    }
    /// A talk speaks Poki's chosen language, whatever the iPhone's: the state on the talk bar, the
    /// reason under it, the step lines and the note when the connection drops. A step line already
    /// listed keeps its words when the language changes.
    func testATalksWordsFollowTheLanguageChosenInPoki() async {
        let saved = AppLocalization.shared.preference
        defer { AppLocalization.shared.preference = saved }
        let expected: [(language: String, connecting: String, step: String, interrupted: String, reason: String, lost: String)] = [
            ("en", "Connecting", "Using the phone", "Interrupted", "Check the network, then try again.",
             "Connection lost. Nothing is sent again. Talk again to hear how running steps ended."),
            ("zh-Hans", "正在连接", "正在操作手机", "已打断", "请检查网络后重试。",
             "连接中断。已发出的内容不会重发，重新对话可以了解步骤的结果。"),
            ("zh-Hant", "正在連線", "正在操作手機", "已打斷", "請檢查網路後再試。",
             "連線中斷。已送出的內容不會重送，重新對話可以了解步驟的結果。"),
        ]
        for words in expected {
            AppLocalization.shared.preference = words.language
            let h = Harness(phoneTool: { _, _ in ("done", false, nil) })
            var said: [VoiceLine] = []
            h.voice.onConversationEnded = { lines, _ in said = lines }
            await h.connect()
            XCTAssertEqual(h.voice.talkState?.word, words.connecting, words.language)

            h.link.play(["type": "session.created"],
                        ["type": "input_audio_buffer.speech_started"], ["type": "input_audio_buffer.speech_stopped"],
                        ["type": "response.created", "response": ["id": "r1"]],
                        ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "do", "arguments": #"{"goal":"open Settings"}"#]],
                        ["type": "response.done", "response": ["id": "r1"]])
            await h.time.settle()
            AppLocalization.shared.preference = words.language == "en" ? "zh-Hans" : "en"
            XCTAssertEqual(h.voice.lines.last { $0.role == .tool }?.text, words.step, words.language)
            AppLocalization.shared.preference = words.language

            h.link.play(["type": "response.created", "response": ["id": "r2"]], ["type": "output_audio_buffer.started"],
                        ["type": "input_audio_buffer.speech_started"], ["type": "output_audio_buffer.cleared"])
            XCTAssertEqual(h.voice.talkState?.word, words.interrupted, words.language)

            h.link.onClosed?("gone")
            XCTAssertEqual(h.voice.talkState?.reason, words.reason, words.language)
            XCTAssertEqual(said.last?.text, words.lost, words.language)
            h.voice.dismissProblem()
        }
    }

    /// When a talk cannot start, the reason under the talk bar is in Poki's chosen language, whatever
    /// the iPhone's: no model and no bridge, a bridge that no longer knows the address, a bridge that
    /// does not answer in time.
    func testWhyATalkCouldNotStartFollowsTheLanguageChosenInPoki() async {
        let saved = AppLocalization.shared.preference
        URLProtocol.registerClass(BridgeTroubleStub.self)
        defer { AppLocalization.shared.preference = saved; URLProtocol.unregisterClass(BridgeTroubleStub.self) }
        let expected: [(language: String, noModel: String, gone: String, slow: String)] = [
            ("en", "Set up Poki's model first (an OpenAI key talks fastest), or enter a voice bridge address from your Mac.",
             "Copy the voice bridge address again from your Mac. This address wasn’t recognized.",
             "The voice connection took too long. Check the network, then try again."),
            ("zh-Hans", "请先设置 Poki 的模型（用 OpenAI 密钥对话最快），或输入 Mac 上的语音桥接地址。",
             "请从 Mac 重新拷贝语音桥接地址。当前地址无法识别。", "语音连接超时。请检查网络后重试。"),
            ("zh-Hant", "請先設定 Poki 的模型（用 OpenAI 金鑰對話最快），或輸入 Mac 上的語音橋接地址。",
             "請從 Mac 重新複製語音橋接位址。目前位址無法識別。", "語音連線逾時。請檢查網路後再試。"),
        ]
        for words in expected {
            AppLocalization.shared.preference = words.language
            let h = Harness()
            h.voice.removeBridge()
            await h.voice.start(microphone: false)
            XCTAssertEqual(h.voice.talkState?.reason, words.noModel, words.language)
            h.voice.dismissProblem()

            for (address, reason) in [(BridgeTroubleStub.gone, words.gone), (BridgeTroubleStub.slow, words.slow)] {
                XCTAssertTrue(h.voice.setBridge(address))
                await h.connect()
                XCTAssertEqual(h.voice.talkState?.reason, reason, "\(words.language) \(address)")
                h.voice.dismissProblem()
            }
        }
    }
}

/// Talk Here, from the Action Button over another app: Poki stays in the background, where iOS lets
/// only the intent start a Live Activity, and the talk needs that Live Activity before the microphone.
extension VoiceModelTests {
    func testTalkHereStartsTheTalkAndItsLiveActivityWithPokiInTheBackground() async {
        let h = Harness()
        let activity = ActivityController()
        // Poki is not in front: every other start of the Live Activity waits for the foreground.
        activity.canStart = { false }
        let talk = TalkActivity(voice: h.voice, activity: activity, deviceName: { "Test iPhone" }, keepsActivity: { false })
        defer { activity.end() }

        let started = await talk.startHere()
        XCTAssertTrue(activity.isRunning, "the Live Activity starts from the background, inside the intent: \(activity.lastError ?? "")")
        guard started else { return XCTFail("Talk Here did not start") }
        h.link.play(["type": "session.created"])
        await h.time.settle()

        XCTAssertEqual(activity.state.voice, .listening)
        XCTAssertTrue(activity.state.face.endsTalk)
        XCTAssertTrue(h.voice.isOn)
        XCTAssertEqual(h.microphone, [true])

        h.voice.stop()
        await h.time.settle()
        XCTAssertFalse(activity.isRunning, "the Live Activity goes with the talk")
    }

    /// The screenshot behind a step reaches the model as an image right after the step's output and before
    /// the answer is asked for (a function_call_output carries text only); the next step's replaces it.
    func testWhatAStepSawReachesTheModelAsAnImage() async {
        let h = Harness(phoneTool: { _, arguments in ("app: Photos", false, Data(arguments.utf8)) })
        await h.talk()
        h.link.play(["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "look", "arguments": "{}"]])
        await h.time.settle()
        h.link.play(["type": "response.done", "response": ["id": "r1"]],
                    ["type": "response.created", "response": ["id": "r2"]],
                    ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c2", "name": "look", "arguments": #"{"full":true}"#]])
        await h.time.settle()
        h.link.play(["type": "response.done", "response": ["id": "r2"]])

        let sent = h.link.sent
        func image(_ event: [String: Any]) -> (id: String, url: String)? {
            guard let item = event["item"] as? [String: Any], item["role"] as? String == "user",
                  let part = (item["content"] as? [[String: Any]])?.first, part["type"] as? String == "input_image" else { return nil }
            return (item["id"] as? String ?? "", part["image_url"] as? String ?? "")
        }
        let output = { (call: String) in sent.firstIndex { ($0["item"] as? [String: Any])?["call_id"] as? String == call }! }
        let images = sent.indices.compactMap { i in image(sent[i]).map { (index: i, id: $0.id, url: $0.url) } }
        let asks = sent.indices.filter { sent[$0]["type"] as? String == "response.create" }
        XCTAssertEqual(images.map(\.url), ["data:image/jpeg;base64,e30=", "data:image/jpeg;base64,eyJmdWxsIjp0cnVlfQ=="])
        guard images.count == 2, asks.count == 2 else { return XCTFail("two screenshots and two answers asked for, got \(images.count) and \(asks.count)") }
        XCTAssertTrue(output("c1") < images[0].index && images[0].index < asks[0])
        XCTAssertTrue(output("c2") < images[1].index && images[1].index < asks[1])
        let deleted = sent.filter { $0["type"] as? String == "conversation.item.delete" }.compactMap { $0["item_id"] as? String }
        XCTAssertEqual(deleted, [images[0].id], "the earlier screenshot leaves the conversation")
    }

    /// Poki speaks the language chosen in Poki from its first sentence, whatever the iPhone's language
    /// (the owner, 2026-11-18: with Poki in Chinese, the first sentence came in English).
    func testTheLiveVoiceSpeaksTheLanguageChosenInPoki() {
        let saved = AppLocalization.shared.preference
        defer { AppLocalization.shared.preference = saved }
        for (language, name) in [("zh-Hans", "Chinese, Simplified"), ("en", "English")] {
            AppLocalization.shared.preference = language
            let instructions = VoiceDirect.session["instructions"] as? String ?? ""
            XCTAssertTrue(instructions.contains("Speak \(name), the language of Poki's interface, from your first sentence on."), language)
        }
    }
}
