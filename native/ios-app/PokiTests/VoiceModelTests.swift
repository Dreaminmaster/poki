import PokiCore
import XCTest
@testable import Poki

/// The voice bridge's token answer, served to URLSession.shared without a Mac.
final class BridgeStub: URLProtocol {
    static let address = "http://voice-bridge.test/voice/0123456789abcdef"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "voice-bridge.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"value":"ek_test","model":"gpt-realtime","local_tools":["get_ios_version","look","do"]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
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
    func connect(secret: String, microphone: Bool, direct: Bool) async throws {}
    func send(_ event: [String: Any]) -> Bool { sent.append(event); return true }
    func setRemoteVolume(_ value: Double) {}
    func diagnose(_ write: @escaping @MainActor (String) -> Void) {}
    func close() { closed = true }
    @MainActor func play(_ events: [String: Any]...) { for event in events { onEvent?(event) } }
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

@MainActor
final class VoiceModelTests: XCTestCase {
    private var savedBridge: String?
    private var savedDirect: Any?

    override func setUp() {
        savedBridge = UserDefaults.standard.string(forKey: "voiceBridge")
        savedDirect = UserDefaults.standard.object(forKey: "voice.openai.enabled")
        // The token comes from the stubbed bridge, never from an OpenAI key this simulator may hold.
        VoiceDirect.enabled = false
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

        @MainActor init(phoneTool: @escaping @MainActor (String, String) async -> (String, Bool) = { _, _ in ("", false) }) {
            let time = FakeTime()
            self.time = time
            var made: (() -> FakeConnection)!
            var held: ((Bool) -> Void)!
            voice = VoiceModel(clearTap: { _, _, _ in .clear }, phoneTool: phoneTool, holdMicrophone: { held($0) },
                               connection: { onEvent, onClosed in let link = made(); link.onEvent = onEvent; link.onClosed = onClosed; return link }, time: time.clock)
            made = { [unowned self] in let link = FakeConnection(); self.links.append(link); return link }
            held = { [unowned self] in self.microphone.append($0) }
            _ = voice.setBridge(BridgeStub.address)
            // As in the app: an ended conversation goes into the chat, and its lines leave the voice model.
            voice.onConversationEnded = { _, _ in }
        }

        /// Connected, before the server's session.created.
        @MainActor func connect() async { await voice.start() }

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
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false) })
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
            let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false) })
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
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false) })
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
        let h = Harness(phoneTool: { _, _ in ("Settings is open", false) })
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
        let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false) })
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
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        Self.session = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["session"] as? [String: Any]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"value":"ek_test"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// ESP-221: in a Chinese conversation the live voice answered in English right after the phone's
/// English tool results. The session tells the model the user's latest turn decides the language,
/// not tool results or notes, and names this iPhone's language only for before the user has spoken.
/// The transcription has no fixed language, so a user who switches is heard in their own.
final class VoiceLanguageTests: XCTestCase {
    func testTheLiveSessionSpeaksTheUsersLanguageAfterEnglishToolResults() async throws {
        URLProtocol.registerClass(OpenAIStub.self)
        defer { URLProtocol.unregisterClass(OpenAIStub.self) }
        _ = try await VoiceDirect.token(apiKey: "sk-test")
        let session = try XCTUnwrap(OpenAIStub.session)
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Always speak the language the user spoke in their latest turn"), instructions)
        XCTAssertTrue(instructions.contains("they never decide the language you speak, so after a tool result keep to the user's language"), instructions)
        let language = Locale(identifier: "en").localizedString(forIdentifier: Locale.preferredLanguages[0]) ?? ""
        XCTAssertTrue(instructions.contains("Before the user has said anything, or when you cannot tell their language, speak \(language), this iPhone's language."), instructions)
        let transcription = ((session["audio"] as? [String: Any])?["input"] as? [String: Any])?["transcription"] as? [String: Any]
        XCTAssertNotNil(transcription)
        XCTAssertNil(transcription?["language"], "a fixed transcription language would mishear a user who switches")
    }
}

/// The Live Activity during a talk: it says what the talk is doing in the state's own `voice` field,
/// its End ends the talk, and an approval is never pushed aside by it.
extension VoiceModelTests {
    private func following(_ h: Harness) -> (ActivityController, TalkActivity) {
        let activity = ActivityController()
        return (activity, TalkActivity(voice: h.voice, activity: activity, deviceName: { "Test iPhone" }, keepsActivity: { false }))
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
        let h = Harness(phoneTool: { _, _ in for await _ in step { break }; return ("done", false) })
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
}
