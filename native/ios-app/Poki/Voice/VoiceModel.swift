import AVFAudio
import Foundation
import Observation
import PokiCore
import UIKit

/// The voice bridge on the person's Mac (`bin/voice-bridge.mjs`) exchanges voice offers with OpenAI
/// without giving the phone the Mac's API key, and runs the voice tools that move the
/// phone through the Mac's Poki MCP. Entered once, like the relay address.
struct VoiceBridge: Equatable {
    /// http://<Mac>:47830/voice/<secret>
    let base: URL

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        let parts = url.path().split(separator: "/")
        guard parts.count == 2, parts[0] == "voice", parts[1].count >= 16 else { return nil }
        base = url
    }

    var display: String { "\(base.host() ?? "")\(base.port.map { ":\($0)" } ?? "")" }

    static var saved: VoiceBridge? {
        get { UserDefaults.standard.string(forKey: "voiceBridge").flatMap(VoiceBridge.init) }
        set { UserDefaults.standard.set(newValue?.base.absoluteString, forKey: "voiceBridge") }
    }

    struct Token: Decodable {
        let value: String?
        let model: String
        let local_tools: [String]
        var live: Bool? = nil
        var base: String? = nil
    }
    private struct SDPAnswer: Decodable { let sdp: String }
    private struct ScreenDescription: Decodable { let text: String }
    struct ToolResult: Decodable {
        let state: String
        var output = ""
        var replayed = false
        /// state "check" (tap_text before the phone cleared it): the app in front and the element it would tap.
        var app: App?
        var target: Target?
        struct App: Decodable { let bundle_id: String?; let name: String? }
        struct Target: Decodable { let text: String; let says: String }

        enum CodingKeys: CodingKey { case state, output, replayed, app, target }
        init(state: String, output: String) { self.state = state; self.output = output }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(String.self, forKey: .state)
            output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
            replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
            app = try c.decodeIfPresent(App.self, forKey: .app)
            target = try c.decodeIfPresent(Target.self, forKey: .target)
        }
    }

    /// Poki's interface language goes along: the one the session speaks from its first sentence.
    func token(preferLive: Bool = true) async throws -> Token {
        let url = base.appending(path: "token").appending(queryItems: [
            URLQueryItem(name: "language", value: AppLocalization.language),
            URLQueryItem(name: "transport", value: preferLive ? "live" : "realtime"),
            URLQueryItem(name: "turns", value: "committed"),
        ])
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.check(response, data)
        return try JSONDecoder().decode(Token.self, from: data)
    }

    func exchangeLiveOffer(_ sdp: String) async throws -> String {
        let url = base.appending(path: "session").appending(queryItems: [URLQueryItem(name: "language", value: AppLocalization.language)])
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["sdp": sdp])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(SDPAnswer.self, from: data).sdp
    }

    var liveScreenReader: ((String) async throws -> String)? {
        guard base.scheme == "https" else { return nil }
        return describeLiveScreen
    }

    private func describeLiveScreen(_ image: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "screen"), timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["image": image])
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoScreenRedirect())
        try Self.check(response, data)
        return try JSONDecoder().decode(ScreenDescription.self, from: data).text
    }

    private final class NoScreenRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// `checked`: for tap_text, the app and element text the phone cleared; without it tap_text only answers "check".
    func run(callID: String, name: String, arguments: String, checked: [String: String]? = nil) async throws -> ToolResult {
        var request = URLRequest(url: base.appending(path: "tool"), timeoutInterval: 75)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
        var body: [String: Any] = ["call_id": callID, "name": name, "arguments": args]
        if let checked { body["checked"] = checked }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(ToolResult.self, from: data)
    }

    #if DEBUG
    /// Test runs only: recorded utterance n (24 kHz mono PCM16), served by a bridge started with --test-dir.
    func utterance(_ n: Int) async throws -> Data {
        var parts = URLComponents(url: base.appending(path: "utterance"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "n", value: String(format: "%02d", n))]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        try Self.check(response, data)
        return data
    }

    func report(_ turn: [String: Any]) async throws {
        var request = URLRequest(url: base.appending(path: "report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: turn)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
    }
    #endif

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reason = json?["error"] as? String
        if json?["source"] as? String == "upstream" {
            let code = json?["upstream_status"] as? Int ?? http.statusCode
            throw VoiceError.realtime(code, reason ?? "upstream error (\(code))")
        }
        throw VoiceError.bridge(http.statusCode, reason)
    }
}

enum VoiceError: LocalizedError {
    /// The bridge's status and the reason it gave, if any.
    case bridge(Int, String?)
    case realtime(Int, String)
    case noBridge
    case appAudioNeedsKeyOrBridge
    case timeout(String)
    /// The connection was set up but no network path to OpenAI opened (the ICE state at the end).
    case noPath(String)
    /// WebRTC on this iPhone could not make a connection, or could not offer one.
    case noWebRTC, noOffer

    /// In English, for the log and for the model when a step's outcome is unknown.
    var errorDescription: String? {
        switch self {
        case .bridge(404, _): "The voice bridge doesn't know this address. Copy it again from the Mac."
        case .bridge(let code, let reason): "The voice bridge answered \(code): \(reason ?? "no reason given")"
        case .realtime(let code, let reason): "OpenAI answered \(code): \(reason)"
        case .noBridge: "Set up Poki's model first (an OpenAI key talks fastest), or enter a voice bridge address from your Mac."
        case .appAudioNeedsKeyOrBridge: "Ask about App Audio isn't available with ChatGPT sign-in alone. Add an API key or voice bridge, or stop listening to app audio to keep using ChatGPT voice."
        case .timeout(let what): "\(what) took too long."
        case .noPath: "The voice connection could not reach OpenAI over this network. Check Wi-Fi or cellular, or a VPN or proxy app that blocks calls, then try again."
        case .noWebRTC: "WebRTC could not start"
        case .noOffer: "WebRTC made no connection offer."
        }
    }

    /// For the talk bar, in Poki's language. A reason the bridge or OpenAI sent stays in their words.
    var words: String {
        switch self {
        case .bridge(404, _): AppLocalization.text(LocalizedStringResource("The voice bridge doesn't know this address. Copy it again from the Mac."))
        case .bridge(let code, let reason):
            AppLocalization.text(LocalizedStringResource("The voice bridge answered \(code): \(reason ?? AppLocalization.text(LocalizedStringResource("no reason given")))"))
        case .realtime(let code, let reason): AppLocalization.text(LocalizedStringResource("OpenAI answered \(code): \(reason)"))
        case .noBridge: AppLocalization.text(LocalizedStringResource("Set up Poki's model first (an OpenAI key talks fastest), or enter a voice bridge address from your Mac."))
        case .appAudioNeedsKeyOrBridge: AppLocalization.text(LocalizedStringResource("Ask about App Audio isn't available with ChatGPT sign-in alone. Add an API key or voice bridge, or stop listening to app audio to keep using ChatGPT voice."))
        case .timeout(let what): AppLocalization.text(LocalizedStringResource("\(what) took too long."))
        case .noPath: AppLocalization.text(LocalizedStringResource("The voice connection could not reach OpenAI over this network. Check Wi-Fi or cellular, or a VPN or proxy app that blocks calls, then try again."))
        case .noWebRTC: AppLocalization.text(LocalizedStringResource("WebRTC could not start"))
        case .noOffer: AppLocalization.text(LocalizedStringResource("WebRTC made no connection offer."))
        }
    }

    /// Why a talk could not start or listen, for the talk bar: Poki's own reasons and the network
    /// failures it can name in Poki's language, anything else as iOS words it.
    static func reason(for error: Error) -> String {
        if let error = error as? VoiceError { return error.words }
        switch (error as? URLError)?.code {
        case .timedOut?:
            return AppLocalization.text(LocalizedStringResource("The voice connection took too long. Check the network, then try again."))
        case .notConnectedToInternet?, .networkConnectionLost?, .cannotConnectToHost?, .cannotFindHost?, .dnsLookupFailed?,
             .internationalRoamingOff?, .dataNotAllowed?:
            return AppLocalization.text(LocalizedStringResource("Poki could not reach the voice service. Check the network, then try again."))
        default:
            return error.localizedDescription
        }
    }
}

/// What look, do or open_app answered on this phone: the text the model reads, whether it failed, and
/// the screenshot behind it.
typealias PhoneAnswer = (text: String, failed: Bool, screen: Data?)

/// One function call the model asked for. Keyed by the model's call_id, it runs at most once, whatever
/// happens to the connection: a call outlives the session that asked for it, and a new session is told
/// how it ended instead of asking for it again.
struct VoiceCall: Identifiable, Equatable {
    enum State: Equatable { case running, done, failed }
    let id: String
    let name: String
    let arguments: String
    /// The connection that asked for it. Only that connection can take a function_call_output for it.
    let session: Int
    var delegation: String? = nil
    var state = State.running
    var output = ""
    /// The encoded screen when the call finished (look, do, open_app): Realtime sends it next to the output.
    var screenDataURL: String?
    /// The model has the result (as a function_call_output, or in a reconnect note).
    var delivered = false
    var silentResult = false
    let started = Date()
    var finished: Date?
}

/// When each step of one turn happened. `said` is the end of the person's speech (or when recorded
/// speech was sent); the rest are measured from it.
struct TurnClock {
    var said: Date?
    var heard: Date?
    var call: Date?
    var toolDone: Date?
    var delivered: Date?
    var spoken: Date?
    var callNames: [String] = []
    var reply = ""
    /// Tokens the turn's responses used, from `response.done` (text_in, audio_in, text_cached, audio_cached, text_out, audio_out).
    var tokens: [String: Int] = [:]

    mutating func add(usage: [String: Any]) {
        let input = usage["input_token_details"] as? [String: Any] ?? [:]
        let cached = input["cached_tokens_details"] as? [String: Any] ?? [:]
        let output = usage["output_token_details"] as? [String: Any] ?? [:]
        for (key, source, field) in [("text_in", input, "text_tokens"), ("audio_in", input, "audio_tokens"), ("text_cached", cached, "text_tokens"),
                                     ("audio_cached", cached, "audio_tokens"), ("text_out", output, "text_tokens"), ("audio_out", output, "audio_tokens")] {
            tokens[key, default: 0] += source[field] as? Int ?? 0
        }
    }

    func ms(_ step: KeyPath<TurnClock, Date?>) -> Int? {
        guard let said, let at = self[keyPath: step] else { return nil }
        return Int(at.timeIntervalSince(said) * 1000)
    }
}

struct VoiceLine: Identifiable, Equatable {
    enum Role: Hashable { case you, poki, tool, note }
    let id = UUID()
    let role: Role
    var text: String
    var at = Date()
}

enum VoicePhase: Equatable {
    case off, connecting, listening, hearing, thinking, speaking
    case lost(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .hearing: "Hearing you"
        case .thinking: "Working"
        case .speaking: "Speaking"
        case .lost(let why): why
        }
    }
}

/// The time VoiceModel reads and waits on.
struct VoiceClock {
    var now: @MainActor () -> Date = { Date() }
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
}

/// Talking to Poki: one Realtime session at a time over WebRTC, the calls it asked for, and what was
/// said. The model hears the microphone and speaks through the speaker; `get_ios_version` is answered
/// here, the other tools by the voice bridge.
@MainActor
@Observable
final class VoiceModel {
    private(set) var bridge = VoiceBridge.saved
    private(set) var phase = VoicePhase.off
    private(set) var needsChatGPTSignIn = false
    private(set) var lines: [VoiceLine] = [] { didSet { saveTranscript() } }
    /// The live conversation's row in the session list, and the lines that belong to it.
    private var transcript: (id: String, started: Date, from: Int)?
    private(set) var calls: [VoiceCall] = []
    /// The person spoke over Poki's answer, or stopped it: the talk's screens say so for `interruptedShows`.
    private(set) var interrupted = false
    private var interruptedLapse: Task<Void, Never>?
    static let interruptedShows: Duration = .milliseconds(1400)
    #if DEBUG && targetEnvironment(simulator)
    /// A screenshot's state, held whatever the session does next (`-pokiTalkHold`).
    var staged: TalkState?
    #endif
    /// Model audio off: for silent test runs. Speech is still transcribed into `lines`.
    var muted = false { didSet { link?.setRemoteVolume(muted || liveSpeechStopped || liveCloseTimeout != nil ? 0 : 1) } }
    /// The last measured turn: from the end of speech to the first audio of the answer that carries a tool result.
    private(set) var lastTurnMS: Int?
    /// Timestamps of the current turn, from the end of the person's speech.
    private(set) var clock = TurnClock()

    private var link: VoiceConnection?
    private var connectionOpen = false
    private var openingCapture: OpeningVoiceCapture?
    private var openingSpeechAuthorized = false
    private var openingTiming: (started: Date, firstTimeAuth: Bool, authMS: Int, connectedMS: Int?, logged: Bool)?
    private var startedCallIDs: Set<String> = []
    private var abortedOpeningCallIDs: Set<String> = []
    private(set) var waitsForOpeningDictation = false
    private var openingDictation: Task<Void, Never>?
    var isCapturingOpening: Bool { openingCapture != nil }

    func ensureBackgroundAudioActive() -> Bool {
        openingCapture?.audio.ensureRunning() ?? true
    }
    private var usesLive = false
    private var appAudio: AppAudioContext?
    private var usesCodexLive = false
    private var codexBackendBusy = false
    private var activeCodexTools = 0
    private var liveCloseTimeout: Task<Void, Never>?
    private var liveUsageSeconds: Double?
    private var liveSpeechStopped = false
    private enum LiveDelegationState: Equatable {
        case active, cancelled, acknowledgment, duplicate
        case awaitingFirstTool(audio: Range<Int>, fallback: LiveCallerSpeech.TextReceipt?)

        var canRunTools: Bool {
            switch self {
            case .active, .awaitingFirstTool: true
            case .cancelled, .acknowledgment, .duplicate: false
            }
        }

        var refusal: String? {
            switch self {
            case .acknowledgment: "The user was acknowledging the conversation. Wait for a request before starting work."
            case .duplicate: "This request repeats a turn already handled. This step did not run. Do not announce a new result."
            case .active, .cancelled, .awaitingFirstTool: nil
            }
        }
    }
    private var liveDelegations: [String: LiveDelegationState] = [:]
    private var liveHasCancellation = false
    private struct LiveCallerSpeech {
        struct Transcript: Equatable {
            let audio: Range<Int>?
            let received: Date
            let inputRevision: Int
        }

        struct TextReceipt: Equatable {
            let text: String
            let transcript: Transcript
        }

        var text = ""
        var end = 0
        var itemID: String?
        var lastStartEvent: String?
        var hasSpeechStartEvents = false
        var handledItems: Set<String> = []
        var inputRevision = 0
        var recordedInputs: Set<String> = []
        var pending: Transcript?
        var replayWithoutPendingSpeech = false
        var executedAudio: Set<Range<Int>> = []
        var lastTranscriptsByText: [String: Transcript] = [:]

        mutating func begin(itemID: String?) {
            self.itemID = itemID
            text = ""
            pending = nil
            replayWithoutPendingSpeech = false
        }

        mutating func recordInput(id: String?) {
            if let id, !recordedInputs.insert(id).inserted { return }
            inputRevision += 1
            replayWithoutPendingSpeech = false
        }

        var normalizedText: String {
            var normalized = text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while let last = normalized.last, last.isWhitespace || ".!?。！？".contains(last) { normalized.removeLast() }
            return normalized
        }

        func isReplay(itemID: String?, audio: Range<Int>?) -> Bool {
            if let itemID { return handledItems.contains(itemID) }
            if let audio { return executedAudio.contains(where: audio.overlaps) }
            return false
        }

        var alreadyHandled: Bool {
            if replayWithoutPendingSpeech { return true }
            if itemID != nil || pending?.audio != nil { return isReplay(itemID: itemID, audio: pending?.audio) }
            guard let pending, let previous = lastTranscriptsByText[normalizedText] else { return false }
            return pending.inputRevision == previous.inputRevision
                && (0...3).contains(pending.received.timeIntervalSince(previous.received))
        }

        var pendingTextReceipt: TextReceipt? {
            guard itemID == nil, let pending else { return nil }
            return TextReceipt(text: normalizedText, transcript: pending)
        }

        mutating func discardReplay() {
            if pending == nil { replayWithoutPendingSpeech = true }
        }

        mutating func append(_ delta: String, audio: Range<Int>?, received: Date) {
            replayWithoutPendingSpeech = false
            text += delta
            var combined = pending?.audio
            if let audio {
                end = max(end, audio.upperBound)
                let first = min(audio.lowerBound, combined?.lowerBound ?? audio.lowerBound)
                let last = max(audio.upperBound, combined?.upperBound ?? audio.upperBound)
                combined = first..<last
            }
            pending = Transcript(audio: combined, received: received, inputRevision: inputRevision)
        }

        mutating func markHandled() {
            if let itemID {
                handledItems.insert(itemID)
            } else if let receipt = pendingTextReceipt, receipt.transcript.audio == nil {
                remember(receipt)
            }
            clearPendingSpeech()
        }

        mutating func remember(_ receipt: TextReceipt) {
            if !receipt.text.isEmpty { lastTranscriptsByText[receipt.text] = receipt.transcript }
        }

        mutating func clearPendingSpeech() {
            begin(itemID: hasSpeechStartEvents ? itemID : nil)
        }
    }
    private var liveCallerSpeech = LiveCallerSpeech()
    private var livePhoneOperations: [String: PhoneOperationCancellation] = [:]
    private var liveScreenDescription: ((String) async throws -> String)?
    private var liveResultReceipts: [String: String] = [:]
    private var liveContinuationAfter: String?
    private var liveAwaitingPlayback = false
    private var loggedLiveInputDuringPlayback = false
    private var livePlayback: Task<Void, Never>?
    private var liveCaptions: [VoiceLine.Role: (index: Int, end: Int)] = [:]
    /// The server opened this session: it takes events now.
    private var ready = false
    private var session = 0
    private var activeResponse: String?
    private var wantsResponse = false
    private var manualRealtimeTurns = false
    private var committedRealtimeItems: Set<String> = []
    private var pendingRealtimeTurns = 0
    /// An answer is expected (the person stopped speaking, or response.create went out) and the server
    /// has not started it yet.
    private var awaitingAnswer = false
    /// The event_id of the response.create Poki sent and the server has not started yet: an error naming
    /// it means that answer is not coming.
    private var requestedAnswer: String?
    /// Running while the conversation waits for the person to go on after an answer.
    private var endWindow: Task<Void, Never>?
    /// Running while a conversation is open: ends it when the server owes something and says nothing.
    private var stallWatch: Task<Void, Never>?
    /// The last time the server said anything, a request went out to it, a step's result was handed over, or
    /// Poki went to the background: the wait for the server counts from here.
    private var lastActivity = Date()
    /// When the last live conversation with something said in it ended, and what the person and Poki
    /// said. One opened soon after is told those lines (kept in memory only). A conversation nobody spoke
    /// in leaves both as they were.
    private var lastEnd: Date?
    private var lastLines: [VoiceLine] = []
    private var inBackground = UIApplication.shared.applicationState == .background

    /// How long a background conversation waits while completely idle before ending and releasing the microphone.
    static let backgroundFollowUp: Duration = .seconds(60)
    /// A conversation opened this soon after the last one ended is told the last turns.
    static let carryOver: TimeInterval = 5 * 60
    static let carriedLines = 6
    private static let liveNoteByteLimit = 480
    /// How long the conversation waits for something it is owed (the end of the person's speech, an answer,
    /// the end of the audio) while the server says nothing, before it ends. Shorter in the background, where
    /// the microphone should not stay on for an event that never comes.
    static let stall: Duration = .seconds(60)
    static let backgroundStall: Duration = .seconds(30)
    private var localTools: Set<String> = []
    /// The conversation item holding the screenshot the model sees now.
    private var screenItem: String?
    private let log = AppLog.shared
    /// Poki's approval for a tap (PokiCore's rules and approval card): text, app bundle id, app name.
    private let clearTap: @MainActor (String, String?, String?) async -> TapClearance

    /// How long a tap waits for the owner's OK on the phone: about as long as the card says it lasts.
    static let approvalWait: Double = 115

    /// look, do and open_app, run by PokiCore on this phone (the relay's tools): name, JSON arguments.
    private let phoneTool: @MainActor (String, String, PhoneOperationCancellation?) async -> PhoneAnswer

    /// true while a conversation with the microphone is on: Poki's silent keep-alive audio steps aside
    /// (its .playback session cannot record), and the voice-chat session keeps Poki running instead.
    private let holdMicrophone: @MainActor (Bool) -> Void

    /// Opens the connection for one session: events, then why it closed.
    private let connection: @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection
    private var connectionAttempt: Int?
    private let time: VoiceClock
    private let openingSpeech: OpeningSpeech
    private let recentAppAudio: @MainActor () async -> AppAudioContext?
    private let codex: any SubscriptionVoice

    init(clearTap: @escaping @MainActor (String, String?, String?) async -> TapClearance,
         phoneTool: @escaping @MainActor (String, String, PhoneOperationCancellation?) async -> PhoneAnswer,
         holdMicrophone: @escaping @MainActor (Bool) -> Void = { _ in },
         connection: @escaping @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection = { VoiceLink(onEvent: $0, onClosed: $1) },
         time: VoiceClock = VoiceClock(),
         openingSpeech: OpeningSpeech = .system,
         recentAppAudio: @escaping @MainActor () async -> AppAudioContext? = { await AppAudioContext.recent() },
         codex: (any SubscriptionVoice)? = nil) {
        self.clearTap = clearTap
        self.phoneTool = phoneTool
        self.holdMicrophone = holdMicrophone
        self.connection = connection
        self.time = time
        self.openingSpeech = openingSpeech
        self.recentAppAudio = recentAppAudio
        self.codex = codex ?? CodexVoice.shared
        // Poki in the background goes on with the talk (the owner, 2026-11-13): you speak to it from the
        // app you went to, and the Live Activity says what it is doing and carries End. In the foreground
        // silence stays open until the owner ends it; in the background it ends after `backgroundFollowUp`
        // of complete idle, and the wait for a server that says nothing is shorter there.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = true
                guard self.isOn else { return }
                if self.idle {
                    self.endIfDone()
                    return
                }
                guard self.answerDue || self.usesCodexLive && self.link != nil && !self.ready else { return }
                // What is still due is waited for, but not for ever: the wait for the server now has 30 s.
                self.lastActivity = self.time.now()
                if self.ready || self.usesCodexLive { self.watchForStall(session: self.session) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = false
                self.keepOpen()
            }
        }
    }
    private var holdingMicrophone = false {
        didSet { if holdingMicrophone != oldValue { holdMicrophone(holdingMicrophone) } }
    }

    /// On from the tap: while the key is exchanged and the connection opens (a second or two, longer
    /// while AirPods switch to their microphone) the button and the bar already show it, and a second
    /// tap ends it instead of starting another one.
    var isOn: Bool { liveCloseTimeout == nil && (link != nil || dictation != nil || openingDictation != nil || isConnecting) }
    private var isConnecting: Bool { if case .connecting = phase { return true }; return false }

    /// Voice can start: the OpenAI key on this iPhone (Realtime, no bridge), the Mac's voice bridge, or
    /// dictation into the chat with whichever model Poki uses.
    var canTalk: Bool { usesChatGPTSubscription || VoiceDirect.apiKey != nil || bridge != nil || VoiceDirect.canDictate }

    /// A live (Realtime) conversation can start: the OpenAI key on this iPhone or the voice bridge.
    /// Without one, voice is dictation into the message field, turn by turn.
    var canTalkLive: Bool { usesChatGPTSubscription || VoiceDirect.apiKey != nil || bridge != nil || rehearsing }

    var usesChatGPTSubscription: Bool { ModelKeys.selectedProvider == .chatgpt && ChatGPTAccount.signedIn }

    /// Talk with Poki was asked for with no live voice (no OpenAI key, no voice bridge), from the message
    /// field's button, Poki's profile or `poki://voice`: the message field says what is missing, with
    /// the way to the key, and sets this back.
    var keyAsked = false

    /// A simulator's development build that asked for TalkRehearsal: talks connect to it, with no key.
    var rehearsing: Bool {
        #if DEBUG && targetEnvironment(simulator)
        TalkRehearsal.asked
        #else
        false
        #endif
    }

    /// What the talk is doing, for its screens: nil while no talk is on and none has just failed.
    var talkState: TalkState? {
        #if DEBUG && targetEnvironment(simulator)
        if let staged { return staged }
        #endif
        switch phase {
        case .off: return nil
        case .lost(let why): return .failed(why)
        case .connecting: return isCapturingOpening ? .listening : .connecting
        case .listening: return interrupted ? .interrupted : .listening
        case .hearing: return interrupted ? .interrupted : .hearing
        case .thinking: return (calls.contains { $0.state == .running } || activeCodexTools > 0) ? .acting : .thinking
        case .speaking: return .speaking
        }
    }

    /// Puts away why the last talk ended, once it has been read.
    func dismissProblem() {
        needsChatGPTSignIn = false
        if case .lost = phase { phase = .off }
    }

    private func markInterrupted() {
        interrupted = true
        interruptedLapse?.cancel()
        interruptedLapse = Task { [weak self] in
            await self?.time.sleep(Self.interruptedShows)
            guard !Task.isCancelled else { return }
            self?.interrupted = false
        }
    }

    /// A live Realtime conversation is on (not the hold-to-dictate fallback).
    var isLive: Bool { link != nil }

    /// How voice runs now, for the settings screen.
    var route: String {
        if case .custom = VoiceDirect.account { return AppLocalization.text(LocalizedStringResource("\(VoiceDirect.settingsAccount.name), straight from this iPhone")) }
        if VoiceDirect.apiKey != nil { return AppLocalization.text(LocalizedStringResource("Your OpenAI key, straight from this iPhone")) }
        if let bridge { return AppLocalization.text(LocalizedStringResource("Voice bridge at \(bridge.display)")) }
        if VoiceDirect.canDictate { return AppLocalization.text(LocalizedStringResource("Dictation to \(ModelKeys.selectedModelName); Poki reads the answer aloud")) }
        return AppLocalization.text(LocalizedStringResource("Not set up"))
    }

    private var dictation: Dictation?

    func setBridge(_ text: String) -> Bool {
        guard let bridge = VoiceBridge(text) else { return false }
        self.bridge = bridge
        VoiceBridge.saved = bridge
        return true
    }

    /// Takes the Mac voice bridge's address off this iPhone. A talk that runs through it ends first: its
    /// next step would go to the bridge.
    func removeBridge() {
        if isLive || isConnecting, VoiceDirect.apiKey == nil { stop() }
        bridge = nil
        VoiceBridge.saved = nil
    }

    /// `poki://voice` can come from any web page, message or app, so it only shows the Voice tab. A link
    /// never changes the voice bridge and never turns on the microphone: the person enters the address
    /// and taps Talk to Poki in the app.
    func open(_ url: URL) {
        let asked = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        if !asked.isEmpty { log.add("voice", "a link asked for \(asked.joined(separator: ", ")); links only bring the chat to the front") }
    }

    #if DEBUG
    /// Development builds only: the `-pokiVoiceLink "poki://voice?bridge=<address>&test=1-20&muted=1"`
    /// launch argument, which only the Mac that installs and launches the build can pass. It may set the
    /// bridge and run silent test turns, which use no microphone.
    func openAtLaunch(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let address = value("bridge") { log.add("voice", setBridge(address) ? "bridge set at launch" : "the launch argument's bridge address was not valid") }
        if value("muted") == "1" { muted = true }
        if let test = value("test"), let range = Self.range(test) { Task { await runTest(range) } }
    }
    #endif

    /// The app's connection: OpenAI's Realtime API, or TalkRehearsal when a simulator build asked for it.
    static let connection: @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection = { onEvent, onClosed in
        #if DEBUG && targetEnvironment(simulator)
        if TalkRehearsal.asked { return TalkRehearsal(onEvent: onEvent, onClosed: onClosed) }
        #endif
        return VoiceLink(onEvent: onEvent, onClosed: onClosed)
    }

    /// Only reached when `rehearsing`.
    private static var rehearsalToken: VoiceBridge.Token {
        #if DEBUG && targetEnvironment(simulator)
        TalkRehearsal.token
        #else
        preconditionFailure("a talk with no key and no bridge outside a rehearsal")
        #endif
    }

    func start(microphone: Bool = true, captureOpening: Bool = false,
               presentSpeechPermission: SpeechPermissionPresenter = { request in await request() }) async {
        if let liveCloseTimeout { await liveCloseTimeout.value }
        guard !isOn else { return }
        phase = .connecting
        needsChatGPTSignIn = false
        session += 1
        let number = session
        openingSpeechAuthorized = false
        let context = microphone ? await recentAppAudio() : nil
        guard number == session else { return }
        appAudio = context
        let account = VoiceDirect.account
        let key = VoiceDirect.apiKey(for: account)
        let wantsSubscription = usesChatGPTSubscription && microphone && !rehearsing
        let subscription = wantsSubscription && appAudio == nil
        if !subscription, key == nil, bridge == nil, !rehearsing {
            if VoiceDirect.canDictate, microphone, appAudio == nil {
                await startDictation()
            } else {
                appAudio = nil
                phase = .lost(wantsSubscription ? VoiceError.appAudioNeedsKeyOrBridge.words : VoiceError.noBridge.words)
            }
            return
        }
        let bridge = self.bridge
        func configuration() async throws -> VoiceBridge.Token {
            if rehearsing { return Self.rehearsalToken }
            if subscription {
                usesCodexLive = true
                try await codex.prepare(onEvent: { [weak self] method, params in
                    self?.handleCodex(method, params: params, session: number)
                }, onTool: { [weak self] name, arguments in
                    guard let self, number == session, VoiceDirect.localTools.contains(name) else {
                        return ("This voice session has ended or cannot run that tool.", true, nil)
                    }
                    guard appAudio == nil else {
                        log.add("voice", "tool refused during media questions")
                        return (Self.mediaToolRefusal, true, nil)
                    }
                    guard Self.phoneTools.contains(name) else {
                        return (Self.localTool(name), false, nil)
                    }
                    openingCapture?.audio.markPhoneActionStarted(session: number)
                    activeCodexTools += 1
                    lastActivity = time.now()
                    keepOpen()
                    if phase != .speaking && phase != .hearing { phase = .thinking }
                    defer {
                        if number == session {
                            activeCodexTools = max(0, activeCodexTools - 1)
                            lastActivity = time.now()
                            if phase == .thinking, !answerDue { phase = .listening }
                            endIfDone()
                        }
                    }
                    return await runPhoneTool(name, arguments: arguments, cancellation: nil)
                })
                return VoiceBridge.Token(value: nil, model: CodexVoice.model, local_tools: [], live: true)
            }
            if let key, let account {
                let model = ModelCatalog.voiceModelID(for: account)
                if microphone, account == .openai, model.hasPrefix("gpt-live-") {
                    return VoiceBridge.Token(value: nil, model: model, local_tools: VoiceDirect.localTools, live: true)
                }
                return try await VoiceDirect.token(apiKey: key, account: account)
            }
            guard let bridge else { throw VoiceError.noBridge }
            return try await bridge.token(preferLive: microphone)
        }
        func makeLink(attempt: Int, direct: Bool) -> VoiceConnection {
            connectionAttempt = attempt
            let link = connection({ [weak self] event in
                guard !subscription, let self, self.session == number, self.connectionAttempt == attempt else { return }
                self.handle(event, session: number)
            }, { [weak self] reason in
                guard let self, self.session == number, self.connectionAttempt == attempt else { return }
                self.closed(reason, session: number)
            })
            self.link = link
            trace("connection opening, excludes VPN interfaces: \(direct)")
            if microphone {
                link.diagnose { [log] line in log.add("voice", "session \(number) connection \(attempt): \(line)") }
            }
            return link
        }
        func connect(_ link: VoiceConnection, _ token: VoiceBridge.Token, direct: Bool) async throws {
            usesLive = token.live == true
            localTools = Set(token.local_tools)
            if subscription {
                try await link.connectLive(microphone: microphone, direct: direct) { sdp in
                    try await codex.start(offer: sdp)
                }
            } else if usesLive {
                if let key { liveScreenDescription = { try await VoiceDirect.describeLiveScreen($0, apiKey: key) } }
                else { liveScreenDescription = bridge?.liveScreenReader }
                try await link.connectLive(microphone: microphone, direct: direct) { sdp in
                    if let key { return try await VoiceDirect.exchangeLiveOffer(sdp, model: token.model, apiKey: key) }
                    guard let bridge else { throw VoiceError.noBridge }
                    return try await bridge.exchangeLiveOffer(sdp)
                }
            } else {
                guard let secret = token.value else { throw VoiceError.noBridge }
                try await link.connect(secret: secret, base: token.base.flatMap { URL(string: $0) }, microphone: microphone, direct: direct)
            }
        }
        do {
            let openingLink = captureOpening && microphone ? makeLink(attempt: 1, direct: false) : nil
            if let openingLink {
                let captureStarted = time.now()
                holdingMicrophone = true
                openingCapture = try openingLink.startOpeningCapture(session: number)
                if openingCapture != nil {
                    let firstTimeAuth = openingSpeech.authorizationStatus() == .notDetermined
                    let authStart = time.now()
                    let authorized = await openingSpeech.authorize(present: presentSpeechPermission)
                    guard number == session else { return }
                    let authMS = max(0, Int(time.now().timeIntervalSince(authStart) * 1000))
                    openingTiming = (captureStarted, firstTimeAuth, authMS, nil, false)
                    openingSpeechAuthorized = authorized
                }
            }
            var token = try await configuration()
            // Ended (End, or the button again) while the key was exchanged.
            guard number == session else { return }
            transcript = ("voice-\(UUID().uuidString.prefix(8).lowercased())", Date(), lines.count)
            if microphone { holdingMicrophone = true }
            if subscription {
                lastActivity = time.now()
                watchForStall(session: number)
            }
            do {
                let first = openingLink ?? makeLink(attempt: 1, direct: false)
                try await connect(first, token, direct: false)
            } catch VoiceError.noPath {
                // No path opened: once more, off VPN interfaces (Poki's loopback, a proxy
                // app) and with a fresh key, before telling the owner.
                guard number == session else { return }
                closeConnection("network path failed; retrying without VPN interfaces")
                ready = false
                phase = .connecting
                if subscription { codex.stop() }
                token = try await configuration()
                guard number == session else { return }
                let second = makeLink(attempt: 2, direct: true)
                second.useOpeningCapture(openingCapture)
                try await connect(second, token, direct: true)
            }
            guard number == session, liveCloseTimeout == nil, let link else { return }
            connectionOpen = true
            if var timing = openingTiming {
                timing.connectedMS = max(0, Int(time.now().timeIntervalSince(timing.started) * 1000))
                openingTiming = timing
            }
            trace("connection open")
            if subscription {
                ready = true
                phase = .listening
            }
            if !sendOpeningAudioIfReady() {
                if !waitsForOpeningDictation { await openingDictation?.value }
                return
            }
            lastActivity = time.now()
            if subscription {
                endIfDone()
            }
            watchForStall(session: number)
            link.setRemoteVolume(muted || liveSpeechStopped ? 0 : 1)
            if usesLive { watchLivePlayback(link, session: number) }
        } catch {
            // Ended while connecting: stop() already put everything back.
            guard number == session, liveCloseTimeout == nil else { return }
            if startOpeningDictation() {
                // Return control to Shortcuts so the owner can run Poki Anytime again.
                if !waitsForOpeningDictation { await openingDictation?.value }
                return
            }
            transcript = nil
            appAudio = nil
            _ = releaseOpeningCapture(session: number)
            if subscription {
                endSession()
            } else {
                closeConnection("could not connect")
                holdingMicrophone = false
            }
            phase = .lost(captureOpening ? Self.openingAudioUnsent : VoiceError.reason(for: error))
            needsChatGPTSignIn = error as? CodexVoice.Failure == .signIn
            log.add("voice", "could not connect: \(error.localizedDescription)")
        }
    }

    private static var openingAudioUnsent: String {
        AppLocalization.text(LocalizedStringResource("The opening recording didn’t go through.", table: "Entry"))
    }

    private static var openingSpeechUnavailable: String {
        AppLocalization.text(LocalizedStringResource("Voice couldn’t connect, and I couldn’t turn the recording into text.", table: "Entry"))
    }

    private static var openingUncertainAfterAction: String {
        AppLocalization.text(LocalizedStringResource("Connection lost after Poki started working. Nothing was sent again. Check whether the rest of what you said went through.", table: "Entry"))
    }

    private static var openingUncertainEarlierPart: String {
        AppLocalization.text(LocalizedStringResource("Connection lost after Poki started working. Only the unsent end will be sent as text. Check whether the earlier part was already handled.", table: "Entry"))
    }

    private func sendOpeningAudioIfReady() -> Bool {
        guard ready, connectionOpen, let capture = openingCapture else { return true }
        if capture.audio.allowSending(session: session) {
            if var timing = openingTiming, !timing.logged {
                timing.logged = true
                openingTiming = timing
                let mode = timing.firstTimeAuth ? "first-time-auth" : "pre-authorized"
                let readyMS = max(0, Int(time.now().timeIntervalSince(timing.started) * 1000))
                let connectMS = timing.connectedMS ?? readyMS
                trace("opening timing (\(mode)): auth \(timing.authMS) ms, connect \(connectMS) ms, ready \(readyMS) ms")
            }
            return true
        }
        if startOpeningDictation() { return false }
        let number = session
        transcript = nil
        _ = releaseOpeningCapture(session: number)
        endVoiceConnection()
        session += 1
        phase = .lost(Self.openingAudioUnsent)
        return false
    }

    @discardableResult
    private func startOpeningDictation() -> Bool {
        let number = session
        guard appAudio == nil,
              let capture = openingCapture,
              let outcome = capture.audio.prepareForOwnerDictation(session: number) else { return false }
        let plan: OpeningVoiceAudio.RecoveryPlan
        switch outcome {
        case .confirmed:
            return false
        case .uncertainPrefixUsed:
            trace("voice connection lost after work started without server audio position")
            endSession()
            session += 1
            let note = Self.openingUncertainAfterAction
            phase = .lost(note)
            lines.append(VoiceLine(role: .note, text: note))
            endTranscript()
            return true
        case .dictation(let recoveryPlan):
            plan = recoveryPlan
        }
        if plan.kind == .fullOpening {
            for call in calls where call.session == number && call.state == .running && !startedCallIDs.contains(call.id) {
                abortedOpeningCallIDs.insert(call.id)
            }
        }
        let authorized = openingSpeechAuthorized
        trace("voice connection failed before confirmed use of opening audio")
        closeConnection("switching to on-device dictation")
        endVoiceConnection()
        if plan.hasUncertainEarlierAudio {
            lines.append(VoiceLine(role: .note, text: Self.openingUncertainEarlierPart))
            endTranscript()
        } else {
            transcript = nil
        }
        guard authorized else {
            _ = releaseOpeningCapture(session: number, forDictation: false)
            phase = .lost(Self.openingSpeechUnavailable)
            openingDictation = Task { [weak self] in
                guard let self else { return }
                defer {
                    if session == number { openingDictation = nil }
                }
                await openingSpeech.announce(Self.openingSpeechUnavailable)
                if session == number { phase = .lost(Self.openingSpeechUnavailable) }
            }
            return true
        }
        phase = .listening
        waitsForOpeningDictation = true
        openingDictation = Task { [weak self] in
            guard let self else { return }
            defer {
                if session == number {
                    openingDictation = nil
                    waitsForOpeningDictation = false
                }
            }
            let deadline = Task { [time, weak audio = capture.audio] in
                await time.sleep(.seconds(45))
                guard !Task.isCancelled else { return }
                audio?.finishForDictation(session: number, discard: true)
            }
            for await _ in plan.finished {}
            deadline.cancel()
            guard session == number, !Task.isCancelled else { return }
            waitsForOpeningDictation = false
            let audio = releaseOpeningCapture(session: number, forDictation: true)
            phase = .thinking
            let text: String?
            if let audio { text = try? await openingSpeech.transcribe(audio) }
            else { text = nil }
            guard session == number, !Task.isCancelled else { return }
            if let text, !text.isEmpty, openingSpeech.sendText(text) {
                let notice = plan.hasUncertainEarlierAudio
                    ? Self.openingUncertainEarlierPart
                    : AppLocalization.text(LocalizedStringResource("Voice couldn’t connect. I’ll handle this as text.", table: "Entry"))
                await openingSpeech.announce(notice)
                if session == number { phase = .off }
            } else {
                let why = text?.isEmpty == false ? Self.openingAudioUnsent : Self.openingSpeechUnavailable
                phase = .lost(why)
                await openingSpeech.announce(why)
                if session == number { phase = .lost(why) }
            }
        }
        return true
    }

    /// Poki Anytime runs again after the owner finishes speaking. The separate End control
    /// continues to cancel the recording without submitting a task.
    func finishOpeningDictation() -> Bool {
        guard waitsForOpeningDictation,
              openingCapture?.audio.finishForDictation(session: session) == true else { return false }
        waitsForOpeningDictation = false
        return true
    }

    @discardableResult
    private func releaseOpeningCapture(session number: Int, forDictation: Bool = false) -> AVAudioPCMBuffer? {
        guard number == session, let capture = openingCapture else { return nil }
        openingCapture = nil
        let audio = capture.audio.stopCapture(session: number, forDictation: forDictation)
        holdingMicrophone = false
        return audio
    }

    private func trace(_ event: String) {
        guard let attempt = connectionAttempt else { return }
        log.add("voice", "session \(session) connection \(attempt): \(event)")
    }

    private func closeConnection(_ reason: String) {
        guard let link, let attempt = connectionAttempt else { return }
        trace("connection closing: \(reason)")
        connectionAttempt = nil
        connectionOpen = false
        self.link = nil
        link.close()
        log.add("voice", "session \(session) connection \(attempt): connection closed")
    }

    private func saveTranscript() {
        guard let transcript, lines.count >= transcript.from else { return }
        SessionStore.shared.save(voice: transcript.id, started: transcript.started, lines: Array(lines[transcript.from...]), live: link != nil)
    }

    /// The chat the conversation was held in (Poki's chat): when it ends, what was said and done goes
    /// into that chat's history, where it stays, instead of a separate row that the next conversation
    /// or a relaunch would take off the screen.
    var onConversationEnded: (@MainActor (_ lines: [VoiceLine], _ started: Date) -> Void)?

    private func endTranscript() {
        guard let ended = transcript else { return }
        saveTranscript()
        transcript = nil
        let said = lines.count >= ended.from ? Array(lines[ended.from...]) : []
        guard let onConversationEnded, !said.isEmpty else { return }
        onConversationEnded(said, ended.started)
        // Now in the chat's own session: the voice row (kept while it ran, in case Poki closed) goes.
        SessionStore.shared.delete(ended.id)
        lines.removeAll()
    }

    /// Ends the conversation. Calls already running keep running; the next session hears how they ended.
    func stop() {
        guard liveCloseTimeout == nil else { return }
        releaseOpeningCapture(session: session)
        if let dictation {
            dictation.cancel()
            self.dictation = nil
        }
        if usesLive, !usesCodexLive, ready, let link {
            ready = false
            keepOpen()
            stallWatch?.cancel()
            livePlayback?.cancel()
            link.setRemoteVolume(0)
            phase = .off
            liveCloseTimeout = Task { [weak self, time] in
                await time.sleep(.seconds(3))
                guard !Task.isCancelled else { return }
                self?.finishLiveClose("timed out waiting for session.closed")
            }
            if !link.send(["type": "session.close"]) {
                finishLiveClose("could not send session.close")
            }
            return
        }
        finishStop()
    }

    private func finishLiveClose(_ reason: String, confirmed: Bool = false) {
        logLiveClose(reason, confirmed: confirmed)
        finishStop()
    }

    private func logLiveClose(_ reason: String, confirmed: Bool) {
        let usage = liveUsageSeconds.map { "\($0) s" } ?? "unavailable"
        log.add("voice", "Live finalization \(confirmed ? "confirmed" : "unconfirmed") (\(reason)), usage: \(usage)")
    }

    private func finishStop() {
        endSession()
        // A start still connecting sees this and stops where it is.
        session += 1
        phase = .off
        endTranscript()
    }

    /// Drops the connection and the state of its turns; calls already running keep running. The lines of
    /// the conversation are kept for one opened soon after, before the chat takes them.
    private func endSession() {
        releaseOpeningCapture(session: session)
        openingDictation?.cancel()
        openingDictation = nil
        waitsForOpeningDictation = false
        startedCallIDs.removeAll()
        abortedOpeningCallIDs.removeAll()
        endVoiceConnection()
        holdingMicrophone = false
    }

    private func endVoiceConnection() {
        if usesCodexLive {
            codex.stop()
            usesCodexLive = false
        }
        codexBackendBusy = false
        activeCodexTools = 0
        keepOpen()
        openingTiming = nil
        livePlayback?.cancel()
        livePlayback = nil
        loggedLiveInputDuringPlayback = false
        liveCaptions.removeAll()
        liveSpeechStopped = false
        liveDelegations.removeAll()
        liveHasCancellation = false
        liveCallerSpeech = LiveCallerSpeech()
        liveUsageSeconds = nil
        liveScreenDescription = nil
        liveResultReceipts.removeAll()
        liveContinuationAfter = nil
        liveAwaitingPlayback = false
        interruptedLapse?.cancel()
        interrupted = false
        stallWatch?.cancel()
        stallWatch = nil
        if appAudio != nil {
            lastEnd = nil
            lastLines = []
        } else if ready || liveCloseTimeout != nil, let from = transcript?.from {
            let said = lines[min(from, lines.count)...].filter { $0.role == .you || $0.role == .poki }
            if !said.isEmpty {
                lastEnd = time.now()
                lastLines = said
            }
        }
        liveCloseTimeout?.cancel()
        liveCloseTimeout = nil
        closeConnection("session ended")
        usesLive = false
        appAudio = nil
        screenItem = nil
        ready = false
        activeResponse = nil
        wantsResponse = false
        manualRealtimeTurns = false
        pendingRealtimeTurns = 0
        committedRealtimeItems.removeAll()
        awaitingAnswer = false
        requestedAnswer = nil
    }

    /// Something is still to be said or done: an answer is expected, being given or about to be asked for,
    /// the person is speaking, or a step is running.
    /// Poki is still on the person's request: it thinks, runs a step, owes an answer or is saying it,
    /// or the person is still speaking. The Live Activity finishes a talk's run of steps when this turns
    /// false, not by a guess at a pause (ESP-954).
    var midTurn: Bool { isOn && (answerDue || phase == .thinking) }

    private var codexBusy: Bool { codexBackendBusy || activeCodexTools > 0 }

    private var answerDue: Bool {
        awaitingAnswer || liveAwaitingPlayback || !liveResultReceipts.isEmpty || activeResponse != nil || wantsResponse || pendingRealtimeTurns > 0
            || phase == .hearing || phase == .speaking || calls.contains { $0.state == .running } || codexBusy
    }

    /// The server owes something: the end of the person's speech, an answer, the end of the audio. A step
    /// that is running is not the server's to answer for, and it has its own time limits.
    private var waitingOnServer: Bool {
        !ready || (awaitingAnswer || liveAwaitingPlayback || !liveResultReceipts.isEmpty || activeResponse != nil || wantsResponse
            || pendingRealtimeTurns > 0 || phase == .hearing || phase == .speaking)
            && !calls.contains { $0.state == .running } && !codexBusy
    }

    /// Ends the conversation when the server owes something and has said nothing for `stall` (30 s in the
    /// background). A lost event, or an error that names no request, would otherwise leave the microphone on.
    private func watchForStall(session number: Int) {
        stallWatch?.cancel()
        stallWatch = Task { [weak self, time] in
            var wait = self?.stallLeft() ?? .zero
            while true {
                await time.sleep(wait)
                guard !Task.isCancelled, let self, number == session, isOn else { return }
                let left = stallLeft()
                if left > .zero { wait = left; continue }
                if waitingOnServer {
                    log.add("voice", "the server said nothing for \(inBackground ? Self.backgroundStall : Self.stall) while Poki waited on it: conversation ended")
                    lines.append(VoiceLine(role: .note, text: AppLocalization.text(LocalizedStringResource("The server did not answer. The talk ended."))))
                    if !startOpeningDictation() { stop() }
                    return
                }
                wait = inBackground ? Self.backgroundStall : Self.stall
            }
        }
    }

    /// How much longer the wait for the server may last, counted from the last activity.
    private func stallLeft() -> Duration {
        let limit = inBackground ? Self.backgroundStall : Self.stall
        let passed = time.now().timeIntervalSince(lastActivity)
        return max(.zero, limit - .seconds(passed))
    }

    /// The answer has played and nothing it asked for is still running or still to be said.
    private var idle: Bool { link != nil && ready && !answerDue }

    /// In the background, once completely idle, the conversation waits `backgroundFollowUp` for the person
    /// to go on; if nobody speaks it ends and lets go of the microphone. In the foreground, silence stays open.
    private func endIfDone() {
        guard inBackground, idle, endWindow == nil else { return }
        let number = session
        let openingDelay = openingCapture?.audio.bufferedDuration ?? .zero
        endWindow = Task { [weak self, time] in
            await time.sleep(Self.backgroundFollowUp + openingDelay)
            guard let self, !Task.isCancelled, number == session else { return }
            endWindow = nil
            guard inBackground, idle else { return }
            log.add("voice", "nobody spoke for \(Self.backgroundFollowUp) in the background while idle: conversation ended")
            stop()
        }
    }

    private func keepOpen() {
        endWindow?.cancel()
        endWindow = nil
    }

    private func watchLivePlayback(_ link: VoiceConnection, session number: Int) {
        livePlayback = Task { [weak self] in
            var quiet = 0
            var audible = false
            var suppressedWhileHearing = 0
            while !Task.isCancelled {
                let playing = await link.hasRemoteSpeech()
                guard let self, number == session, !Task.isCancelled else { return }
                let suppressHearingDrain = usesCodexLive && phase == .hearing && audible && suppressedWhileHearing < 3
                if ready && playing && !liveSpeechStopped && !suppressHearingDrain {
                    if !audible {
                        loggedLiveInputDuringPlayback = false
                        trace("reply playback started (remote audio level)")
                        openingCapture?.audio.markRemoteReplied(session: number)
                        audible = true
                    }
                    quiet = 0
                    suppressedWhileHearing = 0
                    keepOpen()
                    lastActivity = time.now()
                    phase = .speaking
                    if usesCodexLive, awaitingAnswer {
                        awaitingAnswer = false
                        recordSpokenAnswer(at: lastActivity)
                    }
                    if liveAwaitingPlayback, !awaitingAnswer, activeResponse == nil {
                        liveAwaitingPlayback = false
                        recordSpokenAnswer(at: lastActivity)
                    }
                } else if suppressHearingDrain {
                    if playing {
                        quiet = 0
                        suppressedWhileHearing += 1
                    } else {
                        quiet += 1
                        if quiet >= 3 {
                            trace("reply playback went quiet (remote audio level)")
                            audible = false
                            quiet = 0
                            suppressedWhileHearing = 0
                        }
                    }
                } else if phase == .speaking || audible {
                    quiet += 1
                    if quiet >= 3 {
                        if audible {
                            trace("reply playback went quiet (remote audio level)")
                            audible = false
                        }
                        quiet = 0
                        suppressedWhileHearing = 0
                        if phase == .speaking {
                            let working = awaitingAnswer || liveAwaitingPlayback || activeResponse != nil
                                || calls.contains { $0.state == .running } || codexBusy
                            phase = working ? .thinking : .listening
                            endIfDone()
                        }
                    }
                } else {
                    quiet = 0
                    suppressedWhileHearing = 0
                }
                await time.sleep(.milliseconds(160))
            }
        }
    }

    /// A conversation opened soon after the last one hears what was said last, so it goes on from there.
    private func carryOver(_ link: VoiceConnection) {
        guard let lastEnd, time.now().timeIntervalSince(lastEnd) < Self.carryOver else { return }
        let turns = lastLines.suffix(Self.carriedLines)
        if usesLive {
            link.send(note(liveCarryOver(turns)))
            return
        }
        let said = turns.map { "\($0.role == .you ? "User" : "Poki"): \($0.text)" }.joined(separator: "\n")
        link.send(note("This continues a conversation from a few minutes ago. What was said, oldest first. Use it only as context for what the user says next; do not answer or repeat it.\n" + said))
    }

    private func liveCarryOver(_ turns: ArraySlice<VoiceLine>) -> String {
        let header = "Recent conversation for context only. Do not repeat prior actions or answers."
        var available = Self.liveNoteByteLimit - header.utf8.count
        // Preserve the latest request even when Poki's reply is long.
        var priority = [turns.lastIndex { $0.role == .you }, turns.indices.last].compactMap { $0 }
        if priority.count == 2 && priority[0] == priority[1] { priority.removeLast() }
        func label(for index: Int) -> String { turns[index].role == .you ? "\nUser: " : "\nPoki: " }
        let replyBytes = priority.dropFirst().first.map { label(for: $0).utf8.count + turns[$0].text.utf8.count } ?? 0
        let replyReserve = min(available / 2, replyBytes)
        var kept: [Int: String] = [:]
        for (position, index) in priority.enumerated() {
            let prefix = label(for: index)
            let limit = available - prefix.utf8.count - (position == 0 ? replyReserve : 0)
            let line = prefix + Self.liveExcerpt(turns[index].text, bytes: limit)
            kept[index] = line
            available -= line.utf8.count
        }
        for index in turns.indices.reversed() where kept[index] == nil {
            let line = label(for: index) + turns[index].text
            guard line.utf8.count <= available else { continue }
            kept[index] = line
            available -= line.utf8.count
        }
        return header + turns.indices.compactMap { kept[$0] }.joined()
    }

    // MARK: Dictation

    /// The button pressed: starts the conversation, or (dictating) listens for the next request.
    func press() async {
        if let dictation {
            guard phase != .hearing, phase != .thinking else { return }
            holdingMicrophone = true
            do { try dictation.listen(); phase = .hearing } catch {
                holdingMicrophone = false
                phase = .lost(VoiceError.reason(for: error))
            }
            return
        }
        if !isOn, canTalk { await start() }
    }

    /// The button let go. Realtime knows by itself when you stopped; dictation sends what it heard.
    func released() {
        guard let dictation, phase == .hearing else { return }
        phase = .thinking
        Task {
            let text = await dictation.finish()
            guard self.dictation === dictation else { return }
            holdingMicrophone = false
            if lines.last?.role == .you, lines.last?.text != text { lines.removeLast() }
            guard !text.isEmpty else { phase = .listening; return }
            if lines.last?.text != text { lines.append(VoiceLine(role: .you, text: text)) }
            guard let chat = AskPoki.chat else { phase = .lost(VoiceError.noBridge.words); return }
            if chat.running { lines.append(VoiceLine(role: .note, text: AppLocalization.text(LocalizedStringResource("Poki is still on the last task.")))); phase = .listening; return }
            let before = chat.entries.count
            chat.send(text)
            while chat.running { try? await Task.sleep(for: .milliseconds(200)) }
            let reply = chat.entries.dropFirst(before).compactMap { entry -> String? in if case .poki(let t) = entry.kind { return t }; return nil }.last
                ?? AppLocalization.text(LocalizedStringResource("Done."))
            lines.append(VoiceLine(role: .poki, text: reply))
            guard self.dictation === dictation else { return }
            phase = .speaking
            dictation.speak(reply.replacingOccurrences(of: "**", with: ""))
        }
    }

    private func startDictation() async {
        guard await Dictation.allowed() else { phase = .lost(AppLocalization.text(LocalizedStringResource("Poki needs the microphone and speech recognition: allow them in Settings › Poki."))); return }
        let dictation = Dictation()
        dictation.onHeard = { [weak self] text in
            guard let self, self.phase == .hearing else { return }
            if self.lines.last?.role == .you { self.lines.removeLast() }
            self.lines.append(VoiceLine(role: .you, text: text))
        }
        dictation.onSpoken = { [weak self] in if self?.phase == .speaking { self?.phase = .listening } }
        self.dictation = dictation
        holdingMicrophone = true
        do {
            try dictation.listen()
            phase = .hearing
            log.add("voice", "dictation to the chat (no Realtime key or bridge)")
        } catch {
            self.dictation = nil
            holdingMicrophone = false
            phase = .lost(VoiceError.reason(for: error))
        }
    }

    /// Stops Poki's voice reply. Anything running on the phone keeps running.
    func stopTalking() {
        if let dictation { dictation.stopSpeaking(); if phase == .speaking { phase = .listening }; return }
        guard let link, liveCloseTimeout == nil else { return }
        trace("reply stop requested by owner")
        if usesLive {
            stopLivePlayback(on: link, note: "The user stopped playback. Stay silent until they speak again.")
            return
        }
        if phase == .speaking { markInterrupted() }
        if activeResponse != nil { link.send(["type": "response.cancel"]) }
        link.send(["type": "output_audio_buffer.clear"])
        // Without this the next answer (say, when a running step finishes) picks the cut-off reply back up.
        if ready { link.send(note(Self.stoppedNote)) }
    }

    private static let stoppedNote = "The user pressed Stop talking. Drop the reply you were giving; do not continue or repeat it. When a running step finishes, report only its result, in one sentence."

    private func stopLivePlayback(on link: VoiceConnection, note message: String) {
        guard !liveSpeechStopped else { return }
        if phase == .speaking { markInterrupted() }
        liveSpeechStopped = true
        liveAwaitingPlayback = false
        for index in calls.indices where !calls[index].delivered { calls[index].silentResult = true }
        link.setRemoteVolume(0)
        phase = (calls.contains { $0.state == .running } || codexBusy) ? .thinking : .listening
        if ready { link.send(note(message)) }
        endIfDone()
    }

    #if DEBUG
    /// Recorded speech instead of the microphone, for test runs: 24 kHz mono PCM16, sent as one user turn.
    func say(pcm24k: Data) {
        guard let link, ready else { return }
        // A data channel message carries about 256 KB at most, so speech goes in as parts of 2 seconds.
        let part = 96_000
        var sent = true
        for start in stride(from: 0, to: pcm24k.count, by: part) {
            let audio = pcm24k.subdata(in: start..<min(start + part, pcm24k.count)).base64EncodedString()
            sent = link.send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_audio", "audio": audio]]]]) && sent
        }
        if !sent { log.add("voice", "the recorded speech did not go out on the data channel") }
        clock = TurnClock(said: Date())
        wantsResponse = true
        flush()
    }
    #endif

    private func closed(_ reason: String, session number: Int, confirmed: Bool = false, lostMessage: String? = nil, note: String? = nil) {
        guard number == session, link != nil else { return }
        if liveCloseTimeout != nil {
            finishLiveClose(reason, confirmed: confirmed)
            return
        }
        if !confirmed, startOpeningDictation() { return }
        if usesLive && ready { logLiveClose(reason, confirmed: confirmed) }
        endSession()
        session += 1
        phase = .lost(lostMessage ?? TalkState.connectionLost)
        lines.append(VoiceLine(role: .note, text: note ?? AppLocalization.text(LocalizedStringResource("Connection lost. Nothing is sent again. Talk again to hear how running steps ended."))))
        endTranscript()
        log.add("voice", "connection lost: \(reason)")
    }

    // MARK: Events

    private func handleCodex(_ method: String, params: CodexVoice.JSON, session number: Int) {
        guard number == session, usesCodexLive, let link else { return }
        switch method {
        case "thread/realtime/closed", "thread/realtime/error":
            let needsSignIn = CodexVoice.failure(in: params, fallback: .ended) == .signIn
            closed("the ChatGPT voice session ended", session: number, confirmed: method == "thread/realtime/closed")
            if needsSignIn {
                needsChatGPTSignIn = true
                phase = .lost(CodexVoice.Failure.signIn.localizedDescription)
            }
        case "thread/realtime/itemAdded":
            guard (params["item"] as? CodexVoice.JSON)?["type"] as? String == "handoff_request" else { return }
            codexBackendBusy = true
            lastActivity = time.now()
            keepOpen()
            if phase != .speaking && phase != .hearing { phase = .thinking }
        case "poki/backend/turnStarted":
            codexBackendBusy = true
            lastActivity = time.now()
            keepOpen()
            if phase != .speaking && phase != .hearing { phase = .thinking }
        case "poki/backend/turnCompleted":
            codexBackendBusy = false
            awaitingAnswer = false
            lastActivity = time.now()
            if params["status"] as? String == "failed" {
                let failure = CodexVoice.failure(in: params, fallback: .backendFailed)
                let reason = failure.localizedDescription
                if failure == .signIn { needsChatGPTSignIn = true }
                closed("the ChatGPT voice backend failed", session: number, confirmed: true, lostMessage: reason, note: reason)
                return
            }
            if phase == .thinking, !answerDue { phase = .listening }
            endIfDone()
        case "poki/backend/error":
            lastActivity = time.now()
            if params["willRetry"] as? Bool == true {
                codexBackendBusy = true
                keepOpen()
                if phase != .speaking && phase != .hearing { phase = .thinking }
            } else {
                codexBackendBusy = false
                awaitingAnswer = false
                let failure = CodexVoice.failure(in: params, fallback: .backendFailed)
                let reason = failure.localizedDescription
                if failure == .signIn { needsChatGPTSignIn = true }
                closed("the ChatGPT voice backend failed", session: number, confirmed: true, lostMessage: reason, note: reason)
            }
        case "thread/realtime/transcript/delta":
            guard params["role"] as? String == "user" else { return }
            resumeLiveAudio(link)
            lastActivity = time.now()
            keepOpen()
            phase = .hearing
        case "thread/realtime/transcript/done":
            guard let role = params["role"] as? String else { return }
            let text = params["text"] as? String ?? ""
            if role == "user" {
                resumeLiveAudio(link)
                lastActivity = time.now()
                keepOpen()
                if text.isEmpty {
                    if phase == .hearing {
                        phase = codexBusy ? .thinking : .listening
                        endIfDone()
                    }
                    return
                }
                lines.append(VoiceLine(role: .you, text: text))
                awaitingAnswer = true
                phase = .thinking
                watchForStall(session: number)
            } else if role == "assistant", !text.isEmpty {
                openingCapture?.audio.markRemoteReplied(session: number)
                lines.append(VoiceLine(role: .poki, text: text))
            }
        default:
            break
        }
    }

    private func handle(_ event: [String: Any], session number: Int) {
        guard number == session, let link, let type = event["type"] as? String else { return }
        if type == "session.usage.updated" || type == "session.closed" {
            if let seconds = (event["usage"] as? [String: Any])?["seconds"] as? NSNumber {
                liveUsageSeconds = seconds.doubleValue
            }
            if type == "session.closed" {
                closed(event["reason"] as? String ?? "the Live session ended", session: number, confirmed: true)
            }
            return
        }
        guard liveCloseTimeout == nil else { return }
        lastActivity = time.now()
        switch type {
        case "session.created", "session.started":
            if type == "session.created", !usesLive {
                let audio = (event["session"] as? [String: Any])?["audio"] as? [String: Any]
                let detection = (audio?["input"] as? [String: Any])?["turn_detection"] as? [String: Any]
                manualRealtimeTurns = detection?["create_response"] as? Bool == false
            }
            trace("model session ready")
            ready = true
            watchForStall(session: number)
            phase = .listening
            if let appAudio {
                let notes = appAudio.modelNotes(byteLimit: usesLive ? Self.liveNoteByteLimit : nil)
                guard notes.allSatisfy({ link.send(note($0)) }) else {
                    closed("could not send the media context", session: number)
                    return
                }
            }
            guard sendOpeningAudioIfReady() else { return }
            if appAudio == nil {
                carryOver(link)
                catchUp(link)
            }
            endIfDone()
        case "session.input_transcript.delta", "session.output_transcript.delta":
            let role: VoiceLine.Role = type == "session.input_transcript.delta" ? .you : .poki
            guard let text = event["delta"] as? String, !text.isEmpty else { return }
            let start = event["start_ms"] as? Int
            let end = event["end_ms"] as? Int
            keepOpen()
            appendLiveCaption(text, role: role, start: start ?? 0, end: end ?? 0)
            if role == .you {
                if let end, end > 0 {
                    openingCapture?.audio.confirmRemoteAudio(session: number, endMilliseconds: end)
                }
                if phase == .speaking, !loggedLiveInputDuringPlayback {
                    loggedLiveInputDuringPlayback = true
                    let timing = if let start, let end { " (model audio \(start)–\(end) ms)" } else { "" }
                    trace("model reported input during reply playback\(timing)")
                }
                let audio: Range<Int>? = if let start, let end, start >= 0, end > start { start..<end } else { nil }
                let itemID = event["item_id"] as? String
                if liveCallerSpeech.isReplay(itemID: itemID ?? liveCallerSpeech.itemID, audio: audio) {
                    liveCallerSpeech.discardReplay()
                    endIfDone()
                    return
                }
                appendLiveSpeech(text, audio: audio, itemID: itemID)
                let utterance = Self.liveSpeechParts(liveCallerSpeech.text).filter { !Self.liveBackchannels.contains($0) }
                if !liveCallerSpeech.alreadyHandled, Self.liveRequestsStop(utterance) {
                    trace("reply stop requested by recognized voice command")
                    if appAudio == nil { cancelLiveTask() }
                    let stopped = appAudio == nil ? "The user stopped the reply and cancelled the phone task." : "The user stopped the reply."
                    stopLivePlayback(on: link, note: stopped + " Drop the reply and stay silent until a new request.")
                } else if !liveCallerSpeech.alreadyHandled, !utterance.isEmpty {
                    resumeLiveAudio(link)
                    if !answerDue, phase != .thinking { clock = TurnClock(said: time.now()) }
                    else if clock.call == nil { clock.said = time.now() }
                }
            } else {
                openingCapture?.audio.markRemoteReplied(session: number)
                if clock.delivered != nil { clock.reply += text }
            }
            endIfDone()
        case "session.delegation.created":
            if let offset = event["offset_ms"] as? Int, offset > 0 {
                openingCapture?.audio.confirmRemoteAudio(session: number, endMilliseconds: offset)
            }
            if let id = (event["delegation"] as? [String: Any])?["id"] as? String, liveDelegations[id] == nil {
                if liveCallerSpeech.alreadyHandled {
                    liveCallerSpeech.clearPendingSpeech()
                    liveDelegations[id] = .duplicate
                    log.add("voice", "delegation \(id) ignored (duplicate)")
                    return
                }
                let parts = Self.liveSpeechParts(liveCallerSpeech.text)
                let audio = liveCallerSpeech.pending?.audio
                let fallback = liveCallerSpeech.pendingTextReceipt
                liveCallerSpeech.markHandled()
                if !parts.isEmpty, parts.allSatisfy(Self.liveBackchannels.contains) {
                    liveDelegations[id] = .acknowledgment
                    log.add("voice", "delegation \(id) ignored (acknowledgment)")
                    return
                }
                let request = parts.filter { !Self.liveBackchannels.contains($0) }
                let newRequest = !request.isEmpty && !Self.liveRequestsStop(request)
                if liveHasCancellation && !newRequest {
                    liveDelegations[id] = .cancelled
                    log.add("voice", "delegation \(id) ignored (cancelled)")
                } else if let audio {
                    liveDelegations[id] = .awaitingFirstTool(audio: audio, fallback: fallback)
                    log.add("voice", "delegation \(id) created")
                } else {
                    liveDelegations[id] = .active
                    log.add("voice", "delegation \(id) created")
                }
            }
            link.send(["type": "session.thinking.append", "event_id": UUID().uuidString, "delegation_id": NSNull(), "content": ""])
        case "session.commentary.appended":
            guard let id = event["client_event_id"] as? String,
                  let call = liveResultReceipts.removeValue(forKey: id),
                  let index = calls.firstIndex(where: { $0.id == call }) else { return }
            calls[index].delivered = true
            endIfDone()
        case "response.event":
            guard var backend = event["event"] as? [String: Any], let kind = backend["type"] as? String else { return }
            if let state = (event["delegation_id"] as? String).flatMap({ liveDelegations[$0] }),
               !state.canRunTools,
               kind != "response.output_item.done" { return }
            switch kind {
            case "response.completed", "response.failed", "response.incomplete":
                backend["type"] = "response.done"
                backend["live_failed"] = kind != "response.completed"
            case "response.created", "response.output_item.done":
                backend["delegation_id"] = event["delegation_id"]
            default:
                return
            }
            handle(backend, session: number)
        case "input_audio_buffer.speech_started":
            trace("model speech started, reply was playing: \(phase == .speaking)")
            keepOpen()
            if usesLive {
                let eventID = event["event_id"] as? String
                if let eventID {
                    guard eventID != liveCallerSpeech.lastStartEvent else { return }
                    liveCallerSpeech.lastStartEvent = eventID
                }
                liveCallerSpeech.hasSpeechStartEvents = true
                let itemID = event["item_id"] as? String
                liveCallerSpeech.recordInput(id: itemID ?? eventID)
                liveCallerSpeech.begin(itemID: itemID)
                endIfDone()
                return
            }
            // Spoken over Poki's answer: the server drops the answer's audio, and the talk says so.
            if phase == .speaking { markInterrupted() }
            phase = .hearing
        case "input_audio_buffer.speech_stopped":
            trace("model speech stopped")
            if let end = event["audio_end_ms"] as? Int, end > 0 {
                openingCapture?.audio.confirmRemoteAudio(session: number, endMilliseconds: end)
            }
            guard !usesLive else { return }
            phase = .thinking
            awaitingAnswer = true
            clock = TurnClock(said: Date())
        case "input_audio_buffer.committed":
            if let end = event["audio_end_ms"] as? Int, end > 0 {
                openingCapture?.audio.confirmRemoteAudio(session: number, endMilliseconds: end)
            }
            if usesLive {
                liveCallerSpeech.recordInput(id: (event["item_id"] as? String) ?? (event["event_id"] as? String))
                return
            }
            guard manualRealtimeTurns, let item = event["item_id"] as? String, !item.isEmpty,
                  committedRealtimeItems.insert(item).inserted else { return }
            pendingRealtimeTurns += 1
            flush()
        case "conversation.item.added":
            if (event["item"] as? [String: Any])?["role"] as? String == "user" { clock.heard = clock.heard ?? Date() }
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String, !text.isEmpty {
                lines.append(VoiceLine(role: .you, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        case "response.created":
            guard !usesLive || !liveSpeechStopped else { return }
            let id = (event["response"] as? [String: Any])?["id"] as? String
            if usesLive, awaitingAnswer, let id, id == liveContinuationAfter { return }
            activeResponse = id
            keepOpen()
            awaitingAnswer = false
            requestedAnswer = nil
            liveContinuationAfter = nil
        case "response.done":
            let response = event["response"] as? [String: Any]
            if response?["status"] as? String == "cancelled" {
                let detail = response?["status_details"] as? [String: Any]
                let reason = detail?["reason"] as? String
                let source = switch reason {
                case "turn_detected": "model detected input"
                case "client_cancelled": "client cancellation"
                default: "unspecified"
                }
                trace("model cancelled a response: \(source)")
            }
            if let usage = response?["usage"] as? [String: Any] { clock.add(usage: usage) }
            if response?["id"] as? String == activeResponse {
                activeResponse = nil
                if !awaitingAnswer, event["live_failed"] as? Bool == true { liveAwaitingPlayback = false }
            }
            if usesLive, phase == .thinking, !answerDue { phase = .listening }
            flush()
            endIfDone()
        case "response.output_audio_transcript.done":
            if let text = event["transcript"] as? String, !text.isEmpty {
                openingCapture?.audio.markRemoteReplied(session: number)
                lines.append(VoiceLine(role: .poki, text: text))
                if clock.delivered != nil { clock.reply += text }
            }
        case "output_audio_buffer.started":
            guard !usesLive || !liveSpeechStopped else { return }
            trace("reply playback started (model event)")
            openingCapture?.audio.markRemoteReplied(session: number)
            phase = .speaking
            recordSpokenAnswer(at: Date())
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            trace(type == "output_audio_buffer.cleared" ? "model cleared reply playback" : "reply playback stopped (model event)")
            // Cleared because the person started speaking over the answer: they are still being heard.
            if phase != .hearing { phase = calls.contains { $0.state == .running } ? .thinking : .listening }
            endIfDone()
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                  let id = item["call_id"] as? String, let name = item["name"] as? String else { return }
            run(VoiceCall(id: id, name: name, arguments: item["arguments"] as? String ?? "{}", session: number,
                          delegation: event["delegation_id"] as? String))
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            log.add("voice", "realtime error: \(message)")
            // An error can be all the server sends after the person spoke, or the answer to Poki's own
            // response.create; no answer is coming then. An error about something else, while Poki's
            // request for an answer is out, leaves that answer expected.
            let error = event["error"] as? [String: Any]
            let about = (error?["client_event_id"] ?? error?["event_id"]) as? String
            if let about, liveResultReceipts.removeValue(forKey: about) != nil {
                endIfDone()
                return
            }
            if let pending = requestedAnswer, about == pending {
                awaitingAnswer = false
                requestedAnswer = nil
                liveAwaitingPlayback = false
            } else if requestedAnswer == nil, !usesLive || about == nil {
                awaitingAnswer = false
            }
            if manualRealtimeTurns, pendingRealtimeTurns > 0 { flush() }
            endIfDone()
        default:
            break
        }
    }

    private func recordSpokenAnswer(at start: Date) {
        guard let said = clock.said, let delivered = clock.delivered, clock.spoken == nil else { return }
        clock.spoken = start
        let elapsed = Int(start.timeIntervalSince(said) * 1000)
        lastTurnMS = elapsed
        log.add("voice", "turn: end of speech to spoken result \(elapsed) ms (tool result in \(Int(delivered.timeIntervalSince(said) * 1000)) ms)")
    }

    private func appendLiveCaption(_ text: String, role: VoiceLine.Role, start: Int, end: Int) {
        if let previous = liveCaptions[role], lines.indices.contains(previous.index), start - previous.end < 600 {
            lines[previous.index].text += text
            liveCaptions[role] = (previous.index, max(end, previous.end))
        } else {
            liveCaptions[role] = (lines.count, end)
            lines.append(VoiceLine(role: role, text: text))
        }
    }

    private func stopped(_ call: VoiceCall) -> Bool {
        if abortedOpeningCallIDs.contains(call.id) { return true }
        if livePhoneOperations[call.id]?.isCancelled == true { return true }
        guard usesLive, call.session == session else { return false }
        // After cancellation, only a tool tied to a new delegation can start.
        guard let id = call.delegation, let state = liveDelegations[id] else { return liveHasCancellation }
        return state == .cancelled
    }

    private static let liveStopPhrases: Set<String> = ["停", "停止", "停一下", "别动", "别做了", "stop", "cancel"]
    private static let liveBackchannels: Set<String> = ["嗯", "哦", "好的", "好", "uh-huh", "mm-hmm"]

    private func appendLiveSpeech(_ text: String, audio: Range<Int>?, itemID: String?) {
        if let itemID, itemID != liveCallerSpeech.itemID {
            liveCallerSpeech.begin(itemID: itemID)
        } else if !liveCallerSpeech.hasSpeechStartEvents, liveCallerSpeech.itemID == nil, let audio,
                  liveCallerSpeech.end > 0, audio.lowerBound >= liveCallerSpeech.end {
            let preceding = Self.liveSpeechParts(liveCallerSpeech.text)
            let joined = Self.liveSpeechParts(liveCallerSpeech.text + text)
            let afterAcknowledgment = preceding.allSatisfy(Self.liveBackchannels.contains) && !joined.allSatisfy(Self.liveBackchannels.contains)
            let afterStop = Self.liveRequestsStop(preceding) && !Self.liveRequestsStop(joined)
            if preceding.isEmpty || afterAcknowledgment || afterStop || audio.lowerBound - liveCallerSpeech.end >= 600 {
                liveCallerSpeech.begin(itemID: nil)
            }
        }
        liveCallerSpeech.append(text, audio: audio, received: lastActivity)
    }

    /// Match whole clauses of the caller's speech since delegation, independent of subtitle grouping.
    private static func liveSpeechParts(_ text: String) -> [String] {
        text.lowercased().split { ",，。.!！?？;；".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func liveRequestsStop(_ parts: [String]) -> Bool {
        guard let first = parts.first, liveStopPhrases.contains(first) else { return false }
        return parts.dropFirst().allSatisfy { part in liveStopPhrases.contains { $0.hasPrefix(part) } }
    }

    private func cancelLiveTask() {
        liveDelegations = liveDelegations.mapValues { $0.canRunTools ? .cancelled : $0 }
        liveHasCancellation = true
        for operation in livePhoneOperations.values { operation.cancel() }
        activeResponse = nil
        wantsResponse = false
        awaitingAnswer = false
        requestedAnswer = nil
        liveContinuationAfter = nil
        liveAwaitingPlayback = false
    }

    private enum ScreenAttachmentOutcome {
        case none
        case liveDescribed(chars: Int)
        case liveFailed(String)
        case liveUnavailable(String)
        case liveSkipped(String)
        case realtimeImageFailed(String)

        var logTag: String? {
            switch self {
            case .none: nil
            case .liveDescribed(let chars): "desc=ok(\(chars)c)"
            case .liveFailed(let reason): "desc=failed(\(reason))"
            case .liveUnavailable(let reason): "desc=unavailable(\(reason))"
            case .liveSkipped(let reason): "desc=skipped(\(reason))"
            case .realtimeImageFailed(let reason): "image=failed(\(reason))"
            }
        }
    }

    private static func screenFailureNote(_ prefix: String, reason: String) -> String {
        "\n\(prefix): \(reason). Use the screen elements above if available, and tell the user honestly if visual details are missing."
    }

    private func completeLiveControl(_ call: VoiceCall, state: VoiceCall.State, output: String) {
        var result = call
        result.state = state
        result.output = output
        result.finished = Date()
        result.delivered = ready && link?.send(["type": "response.item.create", "item": [
            "type": "function_call_output", "call_id": call.id, "output": output,
        ]]) == true
        if let index = calls.firstIndex(where: { $0.id == call.id }) { calls[index] = result }
        else { calls.append(result) }
        log.add("voice", "tool \(call.name) \(state == .done ? "done" : "failed") | control: \(Self.sanitizeLogText(output, limit: 120))")
        if phase == .thinking, !answerDue { phase = .listening }
        endIfDone()
    }

    private static let stoppedStep = "The user cancelled the task. This step did not run."

    private func resumeLiveAudio(_ link: VoiceConnection) {
        guard liveSpeechStopped else { return }
        liveSpeechStopped = false
        link.setRemoteVolume(muted ? 0 : 1)
    }

    /// Runs a call once. The same call_id again (a repeated event) is ignored.
    private func run(_ call: VoiceCall) {
        guard !calls.contains(where: { $0.id == call.id }) else { return }
        if appAudio != nil {
            refuseMediaTool(call)
            return
        }
        if usesLive, let refusal = call.delegation.flatMap({ liveDelegations[$0] })?.refusal {
            completeLiveControl(call, state: .failed, output: refusal)
            return
        }
        if usesLive, call.name == VoiceDirect.cancelCurrentTask {
            trace("phone task cancellation requested by model tool")
            if call.delegation.flatMap({ liveDelegations[$0] }) != .cancelled { cancelLiveTask() }
            completeLiveControl(call, state: .done, output: "Cancelled further steps. A phone action already running may finish.")
            return
        }
        if stopped(call) {
            completeLiveControl(call, state: .failed, output: Self.stoppedStep)
            return
        }
        var call = call
        call.silentResult = usesLive && liveSpeechStopped
        calls.append(call)
        clock.call = clock.call ?? Date()
        clock.callNames.append(call.name)
        phase = .thinking
        lines.append(VoiceLine(role: .tool, text: Self.describe(call)))
        log.add("voice", "tool \(call.name) \(call.arguments)")
        let local = localTools.contains(call.name)
        let bridge = bridge
        let live = usesLive
        let describeScreen = liveScreenDescription
        Task {
            if stopped(call) {
                completeLiveControl(call, state: .failed, output: Self.stoppedStep)
                return
            }
            if live, call.session == session, let id = call.delegation {
                if case .awaitingFirstTool(let audio, let fallback) = liveDelegations[id] {
                    // Two delegations can arrive before either tool starts.
                    if fallback != nil && liveCallerSpeech.executedAudio.contains(where: audio.overlaps) {
                        liveDelegations[id] = .duplicate
                    } else {
                        liveCallerSpeech.executedAudio.insert(audio)
                        if let fallback { liveCallerSpeech.remember(fallback) }
                        liveDelegations[id] = .active
                    }
                }
                if let refusal = liveDelegations[id]?.refusal {
                    completeLiveControl(call, state: .failed, output: refusal)
                    return
                }
            }
            let operation = live ? PhoneOperationCancellation() : nil
            livePhoneOperations[call.id] = operation
            defer { livePhoneOperations.removeValue(forKey: call.id) }
            startedCallIDs.insert(call.id)
            openingCapture?.audio.markPhoneActionStarted(session: call.session)
            var state = VoiceCall.State.done
            var output: String
            var screen: Data?
            if local, Self.phoneTools.contains(call.name) {
                let answer = await runPhoneTool(call.name, arguments: call.arguments, cancellation: operation)
                output = answer.text.count > 6000 ? String(answer.text.prefix(6000)) + "…" : answer.text
                screen = answer.screen
                if answer.failed { state = .failed }
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state = .failed
                    output = "error: \(call.name) returned empty output"
                }
            } else if local {
                output = Self.localTool(call.name)
            } else if let bridge {
                do {
                    var result = try await bridge.run(callID: call.id, name: call.name, arguments: call.arguments)
                    var note = ""
                    if result.state == "check", let target = result.target {
                        if stopped(call) {
                            completeLiveControl(call, state: .failed, output: Self.stoppedStep)
                            return
                        }
                        // A tap: Poki's approval rules first, and the owner's OK on the phone when they ask for it.
                        let app = result.app
                        let clearance = await clearTap(target.says, app?.bundle_id, app?.name)
                        if stopped(call) {
                            completeLiveControl(call, state: .failed, output: Self.stoppedStep)
                            return
                        }
                        if clearance.mayTap {
                            if case .approved(let why) = clearance { note = "The user allowed it on the phone (\(why)). "; log.add("voice", "tap approved: \(why)") }
                            var checked = ["text": target.text]
                            checked["app"] = app?.bundle_id
                            result = try await bridge.run(callID: call.id, name: call.name, arguments: call.arguments, checked: checked)
                        } else {
                            result = Self.refused(clearance)
                            log.add("voice", "tap not sent: \(result.output)")
                        }
                    }
                    output = note + result.output
                    if result.state != "done" { state = .failed }
                } catch {
                    // The bridge may have run it; never send it again. The model hears that the outcome is unknown.
                    output = "unknown: the bridge did not answer (\(error.localizedDescription)); the action may have run. Read the screen before trying again."
                    state = .failed
                }
            } else {
                output = "error: no voice bridge"
                state = .failed
            }
            let rawToolOutput = output
            var screenOutcome = ScreenAttachmentOutcome.none
            let screenBytes = screen?.count
            var deliveredScreenURL: String?
            if live, let screen {
                if let describeScreen {
                    if call.session != session || !ready || stopped(call) {
                        screenOutcome = .liveSkipped(stopped(call) ? "cancelled" : "session closed")
                    } else {
                        switch VoiceScreen.encodeDataURL(screen) {
                        case .ok(let image):
                            do {
                                let description = try await describeScreen(image).trimmingCharacters(in: .whitespacesAndNewlines)
                                if description.isEmpty {
                                    let reason = "screen description returned empty text"
                                    output += Self.screenFailureNote("Current screen description failed", reason: reason)
                                    screenOutcome = .liveFailed(reason)
                                } else {
                                    output += "\nCurrent screen description: " + description
                                    screenOutcome = .liveDescribed(chars: description.count)
                                }
                            } catch {
                                let reason = Self.screenDescriptionFailureReason(for: error)
                                output += Self.screenFailureNote("Current screen description failed", reason: reason)
                                screenOutcome = .liveFailed(reason)
                            }
                        case .empty:
                            let reason = "screenshot image was empty"
                            output += Self.screenFailureNote("Current screen description failed", reason: reason)
                            screenOutcome = .liveFailed(reason)
                        case .invalidImage(let bytes):
                            let reason = "screenshot (\(bytes) bytes) could not be encoded as JPEG"
                            output += Self.screenFailureNote("Current screen description failed", reason: reason)
                            screenOutcome = .liveFailed(reason)
                        case .tooLarge(let bytes):
                            let reason = "screenshot (\(bytes) bytes) exceeded the upload size limit after compression"
                            output += Self.screenFailureNote("Current screen description failed", reason: reason)
                            screenOutcome = .liveFailed(reason)
                        }
                    }
                } else {
                    output += "\nScreenshot descriptions require an HTTPS voice bridge. Use the screen elements."
                    screenOutcome = .liveUnavailable("HTTPS voice bridge required")
                }
            } else if !live, let screen {
                switch VoiceScreen.encodeDataURL(screen) {
                case .ok(let image):
                    deliveredScreenURL = image
                case .empty:
                    let reason = "screenshot image was empty"
                    output += Self.screenFailureNote("Screenshot unavailable", reason: reason)
                    screenOutcome = .realtimeImageFailed(reason)
                case .invalidImage(let bytes):
                    let reason = "screenshot (\(bytes) bytes) could not be encoded as JPEG"
                    output += Self.screenFailureNote("Screenshot unavailable", reason: reason)
                    screenOutcome = .realtimeImageFailed(reason)
                case .tooLarge(let bytes):
                    let reason = "screenshot (\(bytes) bytes) exceeded the data channel size limit after compression"
                    output += Self.screenFailureNote("Screenshot unavailable", reason: reason)
                    screenOutcome = .realtimeImageFailed(reason)
                }
            }
            finish(call.id, state: state, output: output, rawToolOutput: rawToolOutput,
                   screenDataURL: deliveredScreenURL, screenBytes: screenBytes, screenOutcome: screenOutcome)
        }
    }

    private static let mediaToolRefusal = "This is a media question. Phone tools are unavailable. Answer the user's question from the media excerpt."

    private func runPhoneTool(_ name: String, arguments: String, cancellation: PhoneOperationCancellation?) async -> PhoneAnswer {
        guard appAudio == nil else {
            log.add("voice", "tool refused during media questions")
            return (Self.mediaToolRefusal, true, nil)
        }
        return await phoneTool(name, arguments, cancellation)
    }

    private func refuseMediaTool(_ call: VoiceCall) {
        log.add("voice", "tool refused during media questions")
        let item: [String: Any] = ["type": "function_call_output", "call_id": call.id,
                                  "output": Self.mediaToolRefusal]
        let event = usesLive ? "response.item.create" : "conversation.item.create"
        if link?.send(["type": event, "item": item]) == true, !usesLive {
            wantsResponse = true
            flush()
        }
    }

    private func finish(_ id: String, state: VoiceCall.State, output: String, rawToolOutput: String? = nil,
                        screenDataURL: String? = nil, screenBytes: Int? = nil, screenOutcome: ScreenAttachmentOutcome = .none) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[index].state = state
        calls[index].output = output
        calls[index].screenDataURL = screenDataURL
        calls[index].finished = Date()
        clock.toolDone = Date()
        let summary = Self.summarizeToolOutput(tool: calls[index].name, rawOutput: rawToolOutput ?? output,
                                               outputChars: output.count, state: state,
                                               screenBytes: screenBytes, screenOutcome: screenOutcome)
        log.add("voice", "tool \(calls[index].name) \(state == .done ? "done" : "failed") | \(summary)")
        if calls[index].silentResult {
            if phase == .thinking, !answerDue { phase = .listening }
            endIfDone()
            return
        }
        deliver(index)
    }

    private static func sanitizeLogText(_ text: String, limit: Int) -> String {
        let scrubbed = VoiceDirect.scrubSecrets(text)
        let compact = scrubbed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    private static func screenDescriptionFailureReason(for error: Error) -> String {
        if let voiceError = error as? VoiceError {
            switch voiceError {
            case .realtime(let code, let reason):
                let clean = sanitizeLogText(reason, limit: 140)
                switch code {
                case 400: return "vision request was rejected (400: \(clean))"
                case 401, 403: return "authentication failed (\(code): \(clean))"
                case 404: return "vision model or endpoint unavailable (404: \(clean))"
                case 408, 504: return "vision service timed out (\(code): \(clean))"
                case 429: return "rate limit reached (429: \(clean))"
                case 502 where clean.localizedCaseInsensitiveContains("no screen description"):
                    return "empty screen description (\(clean))"
                default: return "vision service failed (\(code): \(clean))"
                }
            case .bridge(let code, let reason):
                let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                let clean = sanitizeLogText(trimmed?.isEmpty == false ? trimmed! : "no reason given", limit: 140)
                if (300..<400).contains(code) {
                    return "the HTTPS voice bridge redirected the screenshot request, which Poki blocks"
                }
                if code == 400 {
                    return "the voice bridge rejected the screenshot request (400: \(clean))"
                }
                if code == 404 {
                    let lower = trimmed?.lowercased() ?? ""
                    if lower.isEmpty || lower == "not found" || lower == "unknown token" {
                        return "the voice bridge address or token was not recognized (404)"
                    }
                    return "upstream or bridge endpoint unavailable (404: \(clean))"
                }
                return "the voice bridge failed (\(code): \(clean))"
            default:
                return sanitizeLogText(voiceError.localizedDescription, limit: 180)
            }
        }
        if error is DecodingError {
            return "the voice bridge returned an unreadable screen description response"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "the screenshot description request timed out"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return "could not reach the screenshot description server (network error)"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "TLS connection failed for screenshot description"
            default:
                return sanitizeLogText(urlError.localizedDescription, limit: 180)
            }
        }
        return sanitizeLogText(error.localizedDescription, limit: 180)
    }

    private static func summarizeToolOutput(tool: String, rawOutput: String, outputChars: Int, state: VoiceCall.State,
                                            screenBytes: Int?, screenOutcome: ScreenAttachmentOutcome) -> String {
        let lines = rawOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let isElementLine: (String) -> Bool = { line in
            guard let space = line.firstIndex(of: " "), space != line.startIndex else { return false }
            return line[..<space].allSatisfy(\.isASCII) && line[..<space].allSatisfy(\.isNumber)
        }
        let elementCount = lines.filter(isElementLine).count
        var metrics = ["chars=\(outputChars)", "elements=\(elementCount)", "screen=\(screenBytes.map { "\($0)B" } ?? "none")"]
        if let tag = screenOutcome.logTag { metrics.append(tag) }

        var headers: [String] = []
        for line in lines {
            if isElementLine(line) { break }
            if line.hasPrefix("app: ") {
                let appHeader = line.components(separatedBy: "   read:").first ?? line
                headers.append(sanitizeLogText(appHeader, limit: 100))
            } else if line.hasPrefix("poki: ") {
                let firstSentence = line.firstIndex(of: ".").map { String(line[...$0]) } ?? line
                headers.append(sanitizeLogText(firstSentence, limit: 100))
            } else if line.hasPrefix("screen: ") {
                headers.append(sanitizeLogText(line, limit: 80))
            } else if line.hasPrefix("screenshot: none") {
                headers.append(sanitizeLogText(line, limit: 100))
            } else if line.hasPrefix("error: ") || line.hasPrefix("not_sent: ") || line.hasPrefix("unknown: ") {
                headers.append(sanitizeLogText(line, limit: 160))
            }
        }
        if headers.isEmpty {
            if state == .failed, let first = lines.first(where: { !$0.isEmpty }) {
                headers.append(sanitizeLogText(first, limit: 160))
            } else if tool == "get_ios_version", let first = lines.first(where: { !$0.isEmpty }) {
                headers.append(sanitizeLogText(first, limit: 120))
            }
        }
        let metricText = metrics.joined(separator: " ")
        return headers.isEmpty ? metricText : "\(metricText) | \(headers.joined(separator: "; "))"
    }

    /// Hands a finished call to the model: as its function_call_output in the session that asked, or as a
    /// note in a later session. With no session, it waits for the next one.
    private func deliver(_ index: Int) {
        guard appAudio == nil, let link, ready, !calls[index].delivered,
              !calls[index].silentResult, calls[index].state != .running else { return }
        let call = calls[index]
        let sameSession = call.session == session
        if usesLive && !sameSession {
            reportLiveReconnect(call, on: link)
            return
        }
        let itemEvent = usesLive ? "response.item.create" : "conversation.item.create"
        let reconnect = "While the connection was down, \(call.name) \(call.arguments) finished. It already ran; do not run it again. Tell the user in one sentence how it ended. Result: \(call.output)"
        let sent = sameSession
            ? link.send(["type": itemEvent, "item": ["type": "function_call_output", "call_id": call.id, "output": call.output]])
            : link.send(note(reconnect, spoken: true))
        guard sent else { return }
        if !usesLive, sameSession, let imageURL = call.screenDataURL { show(imageURL, on: link) }
        calls[index].screenDataURL = nil
        calls[index].delivered = true
        lastActivity = time.now()
        clock.delivered = Date()
        if usesLive, stopped(call) {
            endIfDone()
            return
        }
        wantsResponse = sameSession || !usesLive
        flush()
    }

    private func reportLiveReconnect(_ call: VoiceCall, on link: VoiceConnection) {
        let id = "reconnect-\(call.id)"
        guard liveResultReceipts[id] == nil else { return }
        let raw = call.output.utf8
        let result = raw.count <= 360 ? call.output
            : String(decoding: raw.prefix(176), as: UTF8.self) + " … " + String(decoding: raw.suffix(176), as: UTF8.self)
        let status = call.state == .done ? "finished" : "failed"
        var event = note("A previous \(call.name) step \(status). Do not repeat it. Report this result in one sentence: \(result)", spoken: true)
        event["event_id"] = id
        guard link.send(event) else { return }
        liveResultReceipts[id] = call.id
        lastActivity = time.now()
        keepOpen()
    }

    /// A function_call_output carries text only, so the screenshot behind it follows as an image in a
    /// user message. Only the latest stays: the one before is deleted, as it no longer shows the screen.
    private func show(_ image: String, on link: VoiceConnection) {
        if let old = screenItem { link.send(["type": "conversation.item.delete", "item_id": old, "event_id": "delete-\(old)"]) }
        let id = "screen-\(UUID().uuidString.prefix(8).lowercased())"
        let item: [String: Any] = ["id": id, "type": "message", "role": "user", "content": [["type": "input_image", "image_url": image]]]
        screenItem = link.send(["type": "conversation.item.create", "event_id": "add-\(id)", "item": item]) ? id : nil
        if screenItem == nil { log.add("voice", "screenshot not sent (\(image.count) characters)") }
    }

    /// A new session after a drop: say what already ran, so the model reports it instead of asking again.
    private func catchUp(_ link: VoiceConnection) {
        let running = calls.filter { $0.state == .running && !$0.silentResult }
        if !running.isEmpty {
            let steps = running.map { usesLive ? $0.name : "\($0.name) \($0.arguments)" }
            link.send(note("Before the connection dropped, these were started and are still running. Their results will follow. Do not start them again: " + steps.joined(separator: ", ")))
        }
        for index in calls.indices where calls[index].state != .running && !calls[index].delivered { deliver(index) }
    }

    /// Asks for a response once none is active (the API takes one at a time).
    private func flush() {
        guard wantsResponse || pendingRealtimeTurns > 0,
              usesLive || (activeResponse == nil && requestedAnswer == nil), ready, let link else { return }
        let id = UUID().uuidString
        var event: [String: Any] = ["type": "response.create", "event_id": id]
        if appAudio != nil, !usesLive { event["response"] = ["tool_choice": "none"] }
        guard link.send(event) else { return }
        wantsResponse = false
        if pendingRealtimeTurns > 0 { pendingRealtimeTurns -= 1 }
        awaitingAnswer = true
        requestedAnswer = id
        if usesLive {
            liveContinuationAfter = activeResponse
            liveAwaitingPlayback = true
            keepOpen()
        }
        lastActivity = time.now()
    }

    // MARK: Test runs (development builds only)

    #if DEBUG
    /// `-pokiVoiceLink "poki://voice?test=1-20"`: each turn opens a fresh session, plays recorded utterance n from the bridge
    /// over the data channel (no microphone, Poki's voice muted), waits for the spoken result and reports
    /// the turn to the bridge.
    func runTest(_ numbers: ClosedRange<Int>) async {
        guard let bridge else { phase = .lost(VoiceError.noBridge.words); return }
        muted = true
        // Test runs have no microphone, so no voice-chat audio session keeps Poki running while a step
        // brings another app to the front; a silent one does, as for a Poki session.
        let awake = KeepAlive()
        try? awake.start()
        defer { awake.stop() }
        log.add("voice", "test run \(numbers.lowerBound)-\(numbers.upperBound) started")
        for n in numbers {
            stop()
            var report: [String: Any] = ["n": n, "device": Self.localTool("get_ios_version")]
            await start(microphone: false)
            if await until(10, { self.ready }), let pcm = try? await bridge.utterance(n) {
                say(pcm24k: pcm)
                let ok = await until(40, { self.clock.spoken != nil && !self.clock.reply.isEmpty && self.activeResponse == nil })
                report["ok"] = ok
                report["calls"] = clock.callNames
                report["reply"] = clock.reply
                report["tokens"] = clock.tokens
                report["ms"] = ["heard": clock.ms(\.heard), "call": clock.ms(\.call), "toolDone": clock.ms(\.toolDone), "delivered": clock.ms(\.delivered), "spoken": clock.ms(\.spoken)].compactMapValues { $0 }
            } else {
                report["ok"] = false
                report["error"] = { if case .lost(let why) = self.phase { return why } else { return "no session" } }()
            }
            stop()
            try? await bridge.report(report)
        }
        log.add("voice", "test run finished")
    }

    private func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func range(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first, let last = parts.last, first >= 1, last >= first, last <= 99 else { return nil }
        return first...last
    }
    #endif

    private static func refused(_ clearance: TapClearance) -> VoiceBridge.ToolResult {
        let output: String
        switch clearance {
        case .declined(let why): output = "not_sent: the user declined on the phone (\(why)). Nothing was tapped."
        case .unanswered(let why): output = "not_sent: the user did not allow it on the phone in time (\(why)). Nothing was tapped."
        case .refused(let why): output = "not_sent: \(why). Nothing was tapped."
        case .clear, .approved: output = ""
        }
        return VoiceBridge.ToolResult(state: "failed", output: output)
    }

    private func note(_ text: String, spoken: Bool = false) -> [String: Any] {
        if usesLive {
            // Every token consumes at least one byte.
            return ["type": spoken ? "session.commentary.append" : "session.instructions.append",
                    "delegation_id": NSNull(), "content": Self.utf8Prefix(text, bytes: Self.liveNoteByteLimit)]
        }
        return ["type": "conversation.item.create", "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]]
    }

    private static func liveExcerpt(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let separator = " … "
        let budget = limit - separator.utf8.count
        let head = utf8Prefix(text, bytes: budget / 2)
        let tail = text.utf8.suffix(budget - budget / 2).drop { $0 & 0xC0 == 0x80 }
        return head + separator + String(decoding: tail, as: UTF8.self)
    }

    private static func utf8Prefix(_ text: String, bytes limit: Int) -> String {
        let bytes = text.utf8
        guard let end = bytes.index(bytes.startIndex, offsetBy: limit, limitedBy: bytes.endIndex) else { return text }
        var boundary = end
        while boundary != bytes.endIndex, bytes[boundary] & 0xC0 == 0x80 {
            bytes.formIndex(before: &boundary)
        }
        return String(decoding: bytes[..<boundary], as: UTF8.self)
    }

    private static func describe(_ call: VoiceCall) -> String {
        switch call.name {
        case "get_ios_version": AppLocalization.text(LocalizedStringResource("Reading the iOS version"))
        case "open_settings": AppLocalization.text(LocalizedStringResource("Opening Settings"))
        case "read_screen": AppLocalization.text(LocalizedStringResource("Reading the screen"))
        case "open_app": AppLocalization.text(LocalizedStringResource("Opening an app"))
        case "tap_text": AppLocalization.text(LocalizedStringResource("Tapping"))
        case "go_home": AppLocalization.text(LocalizedStringResource("Going Home"))
        case "look": AppLocalization.text(LocalizedStringResource("Looking at the screen"))
        case "do": AppLocalization.text(LocalizedStringResource("Using the phone"))
        default: call.name
        }
    }

    /// PokiCore's tools, answered on this phone through the runner.
    static let phoneTools: Set<String> = ["look", "do", "open_app"]

    /// Tools the phone answers itself. They change nothing.
    static func localTool(_ name: String) -> String {
        switch name {
        case "get_ios_version":
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return #"{"model":"\#(machine)","ios_version":"\#(UIDevice.current.systemVersion)"}"#
        default:
            return "error: \(name) is not a phone tool"
        }
    }
}
