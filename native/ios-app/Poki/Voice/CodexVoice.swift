import Foundation
import Observation

@MainActor protocol SubscriptionVoice {
    func prepare(onEvent: @escaping (String, [String: Any]) -> Void, onTool: @escaping (String, String) async -> PhoneAnswer) async throws
    func start(offer: String) async throws -> String
    func stop()
}

@MainActor
@Observable
final class CodexVoice: SubscriptionVoice {
    static let shared = CodexVoice()
    static let model = "gpt-live-1-codex"

    struct Authorization {
        let url: URL
        let code: String
    }

    enum LoginMethod {
        case browser((URL) throws -> Void)
        case deviceCode

        var type: String {
            switch self {
            case .browser: "chatgpt"
            case .deviceCode: "chatgptDeviceCode"
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, signIn, ended, timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: AppLocalization.text("ChatGPT voice could not start. Try again.")
            case .signIn: AppLocalization.text("Sign in to ChatGPT again to start a voice conversation.")
            case .ended: AppLocalization.text("The ChatGPT voice conversation ended.")
            case .timedOut: AppLocalization.text("ChatGPT voice took too long to connect. Try again.")
            }
        }
    }

    typealias JSON = [String: Any]
    private struct Pending {
        let continuation: CheckedContinuation<JSON, any Error>
        let timeout: Task<Void, Never>
    }

    private(set) var authorization: Authorization?
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var completed: [String: Result<JSON, any Error>] = [:]
    @ObservationIgnored private var running = false
    @ObservationIgnored private var active: UUID?
    @ObservationIgnored private var loginAttempt: UUID?
    @ObservationIgnored private var loginID: String?
    @ObservationIgnored private var thread: String?
    @ObservationIgnored private var nextRequest = 0
    @ObservationIgnored private var onEvent: ((String, JSON) -> Void)?
    @ObservationIgnored private var onTool: ((String, String) async -> PhoneAnswer)?

    private var homePath: String { CodexAccount.home.path(percentEncoded: false) }

    func prepare(onEvent: @escaping (String, JSON) -> Void, onTool: @escaping (String, String) async -> PhoneAnswer) async throws {
        let generation = UUID()
        active = generation
        self.onEvent = onEvent
        self.onTool = onTool
        try await requireAccount(generation)
        let answer = try await request("thread/start", [
            "cwd": homePath, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
            "dynamicTools": VoiceDirect.codexTools,
        ])
        try check(generation)
        guard let thread = (answer["thread"] as? JSON)?["id"] as? String else { throw Failure.unavailable }
        self.thread = thread
    }

    func start(offer: String) async throws -> String {
        guard let thread, let active else { throw Failure.ended }
        let answerKey = "sdp:\(thread)"
        try await request("thread/realtime/start", [
            "threadId": thread, "model": Self.model, "version": "v3", "outputModality": "audio",
            "voiceSessionId": active.uuidString,
            "transport": ["type": "webrtc", "sdp": offer],
        ])
        try check(active)
        let answer = try await awaitMessage(answerKey, timeout: .seconds(60))
        try check(active)
        guard let sdp = answer["sdp"] as? String, !sdp.isEmpty else { throw Failure.unavailable }
        return sdp
    }

    func stop() {
        active = nil
        onEvent = nil
        onTool = nil
        cancelLogin()
        if let thread {
            self.thread = nil
            finish("sdp:\(thread)", .failure(CancellationError()))
            sendWithoutWaiting("thread/realtime/stop", ["threadId": thread])
        }
        completed.removeAll()
    }

    func signOut() async throws {
        guard running || FileManager.default.fileExists(atPath: homePath) else { return }
        onEvent?("thread/realtime/closed", [:])
        stop()
        try await request("account/logout", [:])
    }

    private func requireAccount(_ generation: UUID) async throws {
        let state = try await request("account/read", ["refreshToken": false])
        try check(generation)
        guard (state["account"] as? JSON)?["type"] as? String == "chatgpt" else { throw Failure.signIn }
    }

    func refreshAccount() async throws {
        let account = try await request("account/read", ["refreshToken": true])
        guard (account["account"] as? JSON)?["type"] as? String == "chatgpt" else { throw Failure.signIn }
    }

    func cancelLogin() {
        loginAttempt = nil
        authorization = nil
        guard let id = loginID else { return }
        loginID = nil
        completed.removeValue(forKey: "login:\(id)")
        finish("login:\(id)", .failure(CancellationError()))
        sendWithoutWaiting("account/login/cancel", ["loginId": id])
    }

    func authorize(_ method: LoginMethod) async throws {
        guard loginAttempt == nil else { throw Failure.signIn }
        let attempt = UUID()
        loginAttempt = attempt
        defer { if loginAttempt == attempt { cancelLogin() } }

        let response = try await request("account/login/start", ["type": method.type])
        guard let id = response["loginId"] as? String else { throw Failure.signIn }
        guard loginAttempt == attempt else {
            sendWithoutWaiting("account/login/cancel", ["loginId": id])
            throw CancellationError()
        }
        loginID = id
        switch method {
        case .browser(let open):
            guard let address = response["authUrl"] as? String,
                  var url = URLComponents(string: address), url.scheme == "https", url.host == "auth.openai.com",
                  url.path == "/oauth/authorize",
                  url.queryItems?.first(where: { $0.name == "redirect_uri" })?.value == "http://127.0.0.1:1455/auth/callback",
                  var parameters = url.percentEncodedQueryItems,
                  let originator = parameters.firstIndex(where: { $0.name == "originator" }) else { throw Failure.signIn }
            // The embedded server uses its host's name. This sign-in opens the CLI's browser flow.
            parameters[originator].value = "codex_cli_rs"
            url.percentEncodedQueryItems = parameters
            guard let destination = url.url else { throw Failure.signIn }
            try open(destination)
        case .deviceCode:
            guard let userCode = response["userCode"] as? String,
                  let address = response["verificationUrl"] as? String, let url = URL(string: address),
                  url.scheme == "https", url.host() == "auth.openai.com", url.path() == "/codex/device" else { throw Failure.signIn }
            authorization = Authorization(url: url, code: userCode)
        }
        let login = try await awaitMessage("login:\(id)", timeout: .seconds(900))
        guard loginAttempt == attempt else { throw CancellationError() }
        loginID = nil
        guard login["success"] as? Bool == true else { throw Failure.signIn }
        let authorized = try await request("account/read", ["refreshToken": false])
        guard loginAttempt == attempt else { throw CancellationError() }
        guard (authorized["account"] as? JSON)?["type"] as? String == "chatgpt" else { throw Failure.signIn }
    }

    private func check(_ generation: UUID) throws {
        guard active == generation else { throw CancellationError() }
    }

    @discardableResult
    private func request(_ method: String, _ params: JSON) async throws -> JSON {
        try startRuntime()
        nextRequest += 1
        let id = nextRequest
        do {
            return try await awaitMessage("rpc:\(id)", timeout: .seconds(60)) {
                self.send(["id": id, "method": method, "params": params])
            }
        } catch {
            AppLog.shared.add("voice", "Codex request failed: \(method), request \(id)")
            throw error
        }
    }

    private func sendWithoutWaiting(_ method: String, _ params: JSON) {
        nextRequest += 1
        _ = send(["id": nextRequest, "method": method, "params": params])
    }

    private func awaitMessage(_ key: String, timeout: Duration, send request: (() -> Bool)? = nil) async throws -> JSON {
        if let answer = completed.removeValue(forKey: key) { return try answer.get() }
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(key, .failure(Failure.timedOut))
            }
            pending[key] = Pending(continuation: continuation, timeout: deadline)
            if let request, !request() { finish(key, .failure(Failure.unavailable)) }
        }
    }

    private func finish(_ key: String, _ result: Result<JSON, any Error>, retain: Bool = false) {
        if let wait = pending.removeValue(forKey: key) {
            wait.timeout.cancel()
            wait.continuation.resume(with: result)
        } else if retain {
            completed[key] = result
        }
    }

    private func startRuntime() throws {
        if running { return }
        running = homePath.withCString { path in
            poki_codex_start(path) { value in
                guard let value else { return }
                let text = String(cString: value)
                Task { @MainActor in CodexVoice.shared.receive(text) }
            }
        }
        if !running { throw Failure.unavailable }
    }

    private func send(_ message: JSON) -> Bool {
        guard running, JSONSerialization.isValidJSONObject(message),
              let bytes = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return String(decoding: bytes, as: UTF8.self).withCString { poki_codex_send($0) }
    }

    private func receive(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON else { return }
        if let id = message["id"] as? Int, message["method"] == nil {
            if let result = message["result"] as? JSON {
                finish("rpc:\(id)", .success(result))
            } else {
                if pending["rpc:\(id)"] != nil, let code = (message["error"] as? JSON)?["code"] as? Int {
                    AppLog.shared.add("voice", "Codex request \(id) returned error \(code)")
                }
                finish("rpc:\(id)", .failure(Self.failure(in: message["error"] as? JSON, fallback: .unavailable)))
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? JSON ?? [:]
        if method == "poki/runtime/closed" {
            running = false
            if let stage = params["stage"] as? String {
                AppLog.shared.add("voice", "Codex runtime stopped at \(stage)")
            }
            for key in Array(pending.keys) { finish(key, .failure(Failure.unavailable)) }
            onEvent?("thread/realtime/error", [:])
            return
        }
        if method == "account/login/completed", let id = params["loginId"] as? String, loginID == id {
            finish("login:\(id)", .success(params), retain: true)
            return
        }
        guard let thread, params["threadId"] as? String == thread else { return }
        switch method {
        case "item/tool/call":
            guard let id = message["id"], let name = params["tool"] as? String, let active,
                  let arguments = params["arguments"], JSONSerialization.isValidJSONObject(arguments),
                  let bytes = try? JSONSerialization.data(withJSONObject: arguments), let onTool else { return }
            Task {
                guard self.active == active else { return }
                let answer = await onTool(name, String(decoding: bytes, as: UTF8.self))
                guard self.active == active else { return }
                var content = [["type": "inputText", "text": String(answer.text.prefix(6000))]]
                if let screen = answer.screen {
                    content.append(["type": "inputImage", "imageUrl": "data:image/jpeg;base64,\(screen.base64EncodedString())"])
                }
                _ = send(["id": id, "result": ["success": !answer.failed, "contentItems": content]])
            }
        case "thread/realtime/sdp":
            finish("sdp:\(thread)", .success(params), retain: true)
        case "thread/realtime/error", "thread/realtime/closed":
            if method == "thread/realtime/error", let diagnostic = params["diagnostic"] as? String {
                AppLog.shared.add("voice", diagnostic)
            }
            finish("sdp:\(thread)", .failure(Self.failure(in: params, fallback: .ended)), retain: true)
            onEvent?(method, params)
        default:
            onEvent?(method, params)
        }
    }

    static func failure(in params: JSON?, fallback: Failure) -> Failure {
        params?["kind"] as? String == "signInRequired" ? .signIn : fallback
    }
}
