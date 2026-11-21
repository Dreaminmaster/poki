
import Darwin
import Foundation

typealias PhoneAnswer = (text: String, failed: Bool, screen: Data?)
enum VoiceDirect { static let codexTools: [[String: Any]] = [] }
enum CodexAccount { static let home = URL.temporaryDirectory.appending(path: "fixture-voice-account") }
enum AppLocalization { static func text(_ value: String) -> String { value } }
final class AppLog {
    static let shared = AppLog()
    func add(_ category: String, _ message: String) {}
}

enum Session { case missing, valid, rejected }
typealias Emit = @convention(c) (UnsafePointer<CChar>?) -> Void
var emit: Emit?
var state = Session.missing
var authorizationRequests = 0

func poki_codex_start(_ path: UnsafePointer<CChar>, _ next: @escaping Emit) -> Bool {
    emit = next
    return true
}

func poki_codex_send(_ message: UnsafePointer<CChar>) -> Bool {
    let bytes = Data(String(cString: message).utf8)
    guard let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
          let name = body["method"] as? String, let id = body["id"] else { return false }
    var result: [String: Any] = [:]
    switch name {
    case "account/read":
        if state != .missing { result = ["account": ["type": "chatgpt"]] }
    case "account/login/start":
        authorizationRequests += 1
    case "thread/start":
        result = ["thread": ["id": "fixture-thread"]]
    default:
        break
    }
    func push(_ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        String(decoding: data, as: UTF8.self).withCString { emit?($0) }
    }
    push(["id": id, "result": result])
    if name == "thread/realtime/start" {
        if state == .rejected {
            push(["method": "thread/realtime/error", "params": ["threadId": "fixture-thread", "kind": "signInRequired"]])
        } else {
            push(["method": "thread/realtime/sdp", "params": ["threadId": "fixture-thread", "sdp": "fixture-answer"]])
        }
    }
    return true
}

@MainActor func checkAccount() async -> Bool {
    let voice = CodexVoice.shared
    let event: (String, CodexVoice.JSON) -> Void = { _, _ in }
    let tool: (String, String) async -> PhoneAnswer = { _, _ in ("", false, nil) }
    var passed = true
    func expect(_ condition: Bool, _ message: String) {
        passed = passed && condition
        print("\(condition ? "PASS" : "FAIL"): \(message)")
    }
    defer { voice.stop() }

    try? await voice.prepare(onEvent: event, onTool: tool)
    expect(authorizationRequests == 0 && voice.authorization == nil,
           "Opening voice never initiates an unsolicited sign-in")
    voice.stop()

    state = .valid
    do {
        try await voice.prepare(onEvent: event, onTool: tool)
        let sdp = try await voice.start(offer: "fixture-offer")
        expect(sdp == "fixture-answer" && voice.authorization == nil,
               "The shared sign-in opens the voice session without authorization UI")
    } catch {
        expect(false, "The shared sign-in opens the voice session without authorization UI")
    }
    voice.stop()

    state = .rejected
    do {
        try await voice.prepare(onEvent: event, onTool: tool)
        _ = try await voice.start(offer: "fixture-offer")
        expect(false, "An expired account asks the owner to sign in again")
    } catch {
        expect(error.localizedDescription == "Sign in to ChatGPT again to start a voice conversation.",
               "An expired account asks the owner to sign in again")
    }
    return passed
}

if !(await checkAccount()) { exit(1) }
