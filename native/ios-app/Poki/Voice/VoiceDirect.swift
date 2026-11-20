import AVFoundation
import Foundation
import Speech

/// Voice without the Mac's voice bridge.
///
/// - With the owner's OpenAI API key on this iPhone, Poki asks OpenAI for a one-minute Realtime key
///   itself (what `bin/voice-bridge.mjs` does on the Mac: the same model, instructions and tools), and
///   look and do run here, through PokiCore, as with the bridge's phone tools.
/// - With any other model (a ChatGPT plan, Anthropic, OpenRouter…), whose sign-in has no Realtime
///   audio, holding the button dictates on this iPhone (Apple's speech recognition, on the device when
///   it can) and lets go to send it to Poki's chat; Poki reads the answer out loud.
enum VoiceDirect {
    /// The voice model the owner picked in Accounts › OpenAI › Live Voice.
    static var model: String { ModelCatalog.voiceModel }
    static var usesLive: Bool { model.hasPrefix("gpt-live-") }
    static let localTools = ["get_ios_version", "look", "open_app", "do"]

    /// The OpenAI API key on this iPhone, when there is one.
    static var apiKey: String? { enabled ? ModelKeys.key(.openai) : nil }

    /// The owner's switch in Accounts › OpenAI › Live Voice (on unless turned off).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voice.openai.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice.openai.enabled"); ModelKeys.saved += 1 }
    }

    /// Dictation into the chat works with any model the chat can use.
    static var canDictate: Bool { ModelKeys.hasUsableKey }

    /// Poki's interface language, named in English ("Chinese, Simplified"): the language Poki speaks
    /// from its first sentence. The owner picks it in Poki (it can differ from the iPhone's own).
    private static var interfaceLanguage: String {
        Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.language) ?? "English"
    }

    // Tuned against gpt-realtime-2.1 with recorded Chinese speech and stubbed tools. The old text fell
    // back on the iPhone's language, so with the iPhone in English some answers to Chinese came out in
    // English; it also announced steps ("我来查一下…") and listed the screen's buttons.
    private static var instructions: String { """
    # Role
    You are Poki, a voice assistant that operates the user's iPhone with tools.

    # Language
    - Speak \(interfaceLanguage), the language of Poki's interface, from your first sentence on.
    - Speak another language only when the user's latest turn is clearly in it.
    - Tool results, screen text, screenshots and notes from Poki never choose your language.

    # Brevity
    - Act first, then talk. Say nothing before a tool call and nothing between steps: no "OK", no "let me check", no "I'll open it".
    - When the request is done, give the result in one short sentence; two only when the user asked for several facts.
    - Do not repeat the user's words, do not describe what you did or what else is on the screen, and add no greetings, filler or offers of more help. Explain only when the user asks.

    # Tools
    - When a tool can answer or do what the user asks, call it at once. Never guess facts about the phone.
    - A screenshot of the screen follows each look, do and open_app answer as an image: use it with the numbered elements to say what is on the screen. Asked what is on the screen, name the app and its main content in one sentence, without listing buttons.
    - Open an app with open_app and its name as the user said it (微信, WeChat, 设置, Settings); Poki knows its bundle id. For a page of Settings (Bluetooth, Wi-Fi, Battery and the others open_app lists), give the page too, and Settings opens on it.
    - Search the Home Screen for an app only when open_app answers that it does not know the app or the app is not installed: go home ({button: "home"}), swipe down on the Home Screen, type the app's name and tap it.
    - A request can take several steps (open an app, tap, type): call one tool after another until it is done. Put several actions in one do when you know them; tap elements by the numbers from the latest look or do.
    - Never repeat an action that already ran, including actions from before a reconnect that the conversation says have finished.
    - To read a page, open it first, then read the screen.
    - You can open and operate every app installed on this iPhone, Apple's and anyone else's (WeChat, Instagram, Uber, a bank, a game): never tell the user an app is out of reach before you have tried.

    # Approvals and stopping
    - Tapping something that sends, pays, deletes or calls waits until the user allows it on the phone; if the result says they did not, tell them in one sentence and do not try another way.
    - Only the user approves, with their own finger: never open Poki to tap Allow, Deny or anything else in it.
    - If the user tells you to stop or be quiet, stop talking, but anything already running keeps running; when its result arrives, report it in one sentence.
    """ }

    /// Said in every tool's description: the instructions alone left a spoken preamble before some calls.
    private static let silent = " No preamble: call it without saying anything first."

    private static let empty: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    private static let tools: [[String: Any]] = [
        ["type": "function", "name": "get_ios_version", "description": "Read the iPhone model and its iOS version. Changes nothing on the phone." + silent, "parameters": empty],
        ["type": "function", "name": "look", "description": "Read the iPhone screen now: the app in front, its numbered elements (role, label, frame in points) and a screenshot." + silent, "parameters": empty],
        ["type": "function", "name": "open_app", "description": "Open an app on this iPhone by its name, as the user says it in any language (微信, WeChat, 设置, Settings), then read the screen. With page, Settings opens straight on that page." + silent,
         "parameters": ["type": "object", "properties": ["app": ["type": "string"], "page": ["type": "string", "enum": VoiceApps.settingsPages.map(\.key).sorted()]],
                        "required": ["app"], "additionalProperties": false]],
        ["type": "function", "name": "do", "description": doDescription + silent,
         "parameters": ["type": "object", "properties": ["actions": ["type": "array", "items": ["type": "object"]]], "required": ["actions"], "additionalProperties": false]],
    ]

    /// PokiCore's own description of do (the text chat's), so voice knows every action the chat knows:
    /// launch any app, scroll_to, back, long_press, handoff and the rest.
    private static let doDescription: String = Harness.phoneTools.first { $0.name == "do" }?.description
        ?? "Run actions on the iPhone in order, then read the screen once. Actions: {launch: \"bundle id\"} (any installed app); {tap: n} or {tap: [x, y]}; {type: \"text\", ref?: n} (taps n first, then types); {key: \"return\"}; {scroll_to: \"text\"}; {swipe: \"up\"|\"down\"|\"left\"|\"right\"}; {button: \"home\"}; {wait_until: \"text\"}; {wait: ms}; {back: true}. The answer says what each action did and what is new on screen."

    /// The Realtime session Poki opens: model, instructions, voice, turn detection and tools.
    static var session: [String: Any] {
        [
            "type": "realtime", "model": usesLive ? ModelCatalog.voiceRealtime : model, "instructions": instructions, "output_modalities": ["audio"],
            "audio": [
                "input": ["turn_detection": ["type": "server_vad", "silence_duration_ms": 450, "prefix_padding_ms": 300, "threshold": 0.5, "create_response": true, "interrupt_response": true],
                          "noise_reduction": ["type": "near_field"], "transcription": ["model": "gpt-4o-mini-transcribe", "language": "zh"]],
                "output": ["voice": "marin"],
            ],
            "tools": tools, "tool_choice": "auto", "parallel_tool_calls": false, "reasoning": ["effort": "low"],
        ]
    }

    static func exchangeLiveOffer(_ sdp: String, model: String, apiKey: String) async throws -> String {
        let live: [String: Any] = [
            "model": model,
            "instructions": """
                You are Poki, a voice assistant. Speak \(interfaceLanguage). Switch languages only when the user clearly switches. App names, tool output and words like hello do not change the conversation language. Delegate phone requests promptly. Let the backend finish before reporting its result. A brief “嗯” is an acknowledgment; keep speaking through it. When the user asks you to stop, stop speaking. A phone action already running may finish.
                """,
            "audio": ["output": ["voice": "marin"]],
            "delegation": ["type": "responses", "responses": [
                "model": "gpt-6-luna", "instructions": instructions + "\nUse only the most recent screenshot as the current screen.", "tool_choice": "auto",
                "tools": tools.map { $0.merging(["strict": false]) { _, value in value } },
                "parallel_tool_calls": false, "reasoning": ["effort": "low"],
            ]],
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/live/sessions")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["session": live, "transport": ["type": "webrtc", "sdp": sdp]])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let answer = (json?["transport"] as? [String: Any])?["sdp"] as? String, !answer.isEmpty else {
            throw VoiceError.realtime(status, openAIError(json, fallback: "Live session \(status)"))
        }
        return answer
    }

    /// A one-minute Realtime key from OpenAI, made with the owner's API key (sent only to OpenAI).
    static func token(apiKey: String) async throws -> VoiceBridge.Token {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expires_after": ["anchor": "created_at", "seconds": 60], "session": session])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let value = json?["value"] as? String else {
            throw VoiceError.realtime(status, openAIError(json, fallback: "client_secrets \(status)"))
        }
        return VoiceBridge.Token(value: value, model: usesLive ? ModelCatalog.voiceRealtime : model, local_tools: localTools)
    }

    private static func openAIError(_ json: [String: Any]?, fallback: String) -> String {
        ((json?["error"] as? [String: Any])?["message"] as? String ?? fallback)
            .replacingOccurrences(of: #"sk-[\w*-]+"#, with: "the API key", options: .regularExpression)
    }
}

/// Hold to dictate, let go to send to Poki's chat, hear the answer: voice for models without Realtime.
@MainActor
final class Dictation: NSObject, AVSpeechSynthesizerDelegate {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private let speaker = AVSpeechSynthesizer()
    private(set) var heard = ""
    var onHeard: ((String) -> Void)?
    var onSpoken: (() -> Void)?

    override init() {
        super.init()
        speaker.delegate = self
    }

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    func listen() throws {
        speaker.stopSpeaking(at: .immediate)
        heard = ""
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw VoiceError.realtime(0, AppLocalization.text(LocalizedStringResource("Speech recognition is not available right now."))) }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try audio.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.tap(input, into: request)
        engine.prepare()
        try engine.start()
        recognition = Self.recognize(recognizer, request) { [weak self] text in
            self?.heard = text
            self?.onHeard?(text)
        }
    }

    // The audio tap and the recognizer call back on their own threads, so their blocks are made outside
    // the main actor.
    nonisolated private static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              heard: @escaping @MainActor (String) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in heard(text) }
        }
    }

    /// Stops listening; the words heard so far (a moment later, for the last ones).
    func finish() async -> String {
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? await Task.sleep(for: .milliseconds(600))
        recognition?.cancel()
        recognition = nil
        request = nil
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        speaker.speak(utterance)
    }

    func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onSpoken?() }
    }
}
