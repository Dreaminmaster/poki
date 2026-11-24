import Foundation
import PiSwiftAI

/// pi's HTTP client for a custom OpenAI-compatible address, with two additions.
///
/// It repairs a stream some gateways (a vLLM backend behind one, issue #344) send when asked for
/// `text/event-stream`: each event comes as `data:data: {…}`, which pi's parser reads as `data: {…}`,
/// not JSON, so every chunk was dropped and the answer ended with "Stream ended without finish_reason".
/// A repeated `data:` prefix is folded into one; every other line passes through unchanged.
///
/// It moves a request to a provider's next address when one can't be reached: no connection, or a
/// gateway error (502, 503, 504) before any of the answer. The addresses are tried in the provider's
/// order, each once per request; the model's words are never sent twice, since a request that got an
/// answer is not repeated.
///
/// It also keeps what the address answered to the last request, for Poki's log when the request
/// fails: the address without its query, the HTTP status and content type, and for an error the
/// start of the server's words, with the key replaced. A stream's contents (the model's words) are
/// never kept, only how many events it had and whether it ended.
final class CustomEndpointClient: ProviderHTTPClient, @unchecked Sendable {
    struct Seen: Equatable, Sendable {
        var url: String
        var status: Int?
        var contentType: String?
        var failure: String?
        var errorBody = ""
        var events = 0
        var repaired = 0
        var sawDone = false
        /// Addresses tried before this one for the same request, as the log shows them.
        var movedFrom: [String] = []

        /// One line for Poki's log, without the key.
        func summary(key: String?) -> String {
            var parts = ["custom address \(url)"]
            if !movedFrom.isEmpty { parts.append("after \(movedFrom.joined(separator: ", ")) could not be reached") }
            if let failure { parts.append("no answer (\(failure))") }
            if let status {
                parts.append("HTTP \(status)" + (contentType.map { " (\($0))" } ?? ""))
                if (200..<300).contains(status) {
                    parts.append("\(events) stream events, \(repaired) with a doubled data: prefix repaired, " + (sawDone ? "[DONE] seen" : "no [DONE]"))
                } else if !errorBody.isEmpty {
                    parts.append(CustomEndpointClient.redacted(errorBody, key: key))
                }
            }
            return parts.joined(separator: ", ")
        }
    }

    private let inner: any ProviderHTTPClient
    private let lock = NSLock()
    private var last: Seen?
    /// The address requests are made for, and the ones to move them to, in order.
    private let primary: String?
    let backups: [String]
    /// The conversation that owns requests made by this HTTP client. Never take this from global chat state.
    private let conversationSessionID: String?

    init(inner: any ProviderHTTPClient = DefaultProviderHTTPClient(), primary: String? = nil,
         backups: [String] = [], conversationSessionID: String? = nil) {
        self.inner = inner
        self.primary = primary.map(ModelCatalog.normalizedAddress)
        self.backups = backups.map(ModelCatalog.normalizedAddress).filter { !$0.isEmpty }
        self.conversationSessionID = conversationSessionID
    }

    /// The client for one custom provider's model and one saved conversation.
    convenience init(for model: Model, sessionID: String? = nil) {
        self.init(primary: model.baseUrl, backups: Self.backupAddresses(for: model),
                  conversationSessionID: sessionID)
    }

    /// A backup URL is a *new* recipient. Do not forward the primary's OpenCode session
    /// headers into an unrelated gateway. Even for an OpenCode-hosted backup, use the
    /// request owner's ID, not a header captured from a different request or chat.
    static func routedFallback(_ request: URLRequest, to url: URL, conversationSessionID: String?) -> URLRequest {
        var moved = request
        moved.url = url
        for name in (moved.allHTTPHeaderFields ?? [:]).keys
            where name.caseInsensitiveCompare("x-opencode-session") == .orderedSame ||
                  name.caseInsensitiveCompare("x-opencode-client") == .orderedSame {
            moved.setValue(nil, forHTTPHeaderField: name)
        }
        let host = url.host?.lowercased() ?? ""
        let trustedOpenCode = url.scheme?.lowercased() == "https"
            && (host == "opencode.ai" || host.hasSuffix(".opencode.ai"))
        if trustedOpenCode, let sessionID = conversationSessionID, !sessionID.isEmpty {
            moved.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
            moved.setValue("Poki", forHTTPHeaderField: "x-opencode-client")
        }
        return moved
    }

    static func backupAddresses(for model: Model) -> [String] {
        CustomProviders.provider(piProvider: model.provider)?.backups.map(\.normalized) ?? []
    }

    /// Resolve the original API against the backup's own base address, using pi's path rules.
    static func moved(_ url: URL?, from base: String, to other: String) -> URL? {
        guard let url else { return nil }
        let responses = url.path.hasSuffix("/responses")
        guard url == requestURL(base, responses: responses) else { return nil }
        return requestURL(other, responses: responses)
    }

    private static func requestURL(_ address: String, responses: Bool) -> URL? {
        let base = ModelCatalog.normalizedAddress(address)
        guard let url = URL(string: base), url.host != nil else { return nil }
        let route = responses ? "/responses" : "/chat/completions"
        if base.hasSuffix(route) { return url }
        let prefix = responses && url.path.isEmpty ? "/v1" : ""
        return URL(string: base + prefix + route)
    }

    /// A failure another address may not have: no connection, or a gateway with nothing behind it.
    static func movable(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .timedOut,
                .secureConnectionFailed, .notConnectedToInternet].contains(code)
    }

    /// What the address answered to the last request, or nil before the first.
    var seen: Seen? { lock.withLock { last } }

    /// Only official OpenAI HTTPS endpoints are confirmed to accept OpenAI's prompt-cache body
    /// field and session-routing headers.
    static func acceptsSessionCache(url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.openai.com",
              url.port == nil || url.port == 443 else {
            return false
        }
        return true
    }

    /// Strips OpenAI session-cache fields and headers when an outgoing request targets a
    /// non-official endpoint (for example, when failing over from `api.openai.com` to a
    /// third-party backup address).
    static func scopedForDestination(_ request: URLRequest) -> URLRequest {
        guard !acceptsSessionCache(url: request.url) else { return request }
        var updated = request
        if let fields = updated.allHTTPHeaderFields {
            let dropped: Set<String> = ["session_id", "x-client-request-id", "x-session-affinity"]
            for key in fields.keys where dropped.contains(key.lowercased()) {
                updated.setValue(nil, forHTTPHeaderField: key)
            }
        }
        if let body = updated.httpBody,
           var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           payload.removeValue(forKey: "prompt_cache_key") != nil,
           let encoded = try? JSONSerialization.data(withJSONObject: payload) {
            updated.httpBody = encoded
            if let fields = updated.allHTTPHeaderFields {
                for key in fields.keys where key.lowercased() == "content-length" {
                    updated.setValue("\(encoded.count)", forHTTPHeaderField: key)
                }
            }
        }
        return updated
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await send(request, timeoutPolicy: .request)
    }

    func send(_ request: URLRequest, timeoutPolicy: ProviderHTTPTimeoutPolicy) async throws -> ProviderHTTPResponse {
        var attempts = [Self.scopedForDestination(request)]
        if let primary {
            for backup in backups {
                guard let url = Self.moved(request.url, from: primary, to: backup) else { continue }
                let next = Self.routedFallback(request, to: url, conversationSessionID: conversationSessionID)
                attempts.append(Self.scopedForDestination(next))
            }
        }
        var tried: [String] = []
        var response: ProviderHTTPResponse?
        for (index, attempt) in attempts.enumerated() {
            let isLast = index == attempts.count - 1
            lock.withLock {
                last = Seen(url: Self.shown(attempt.url))
                last?.movedFrom = tried
            }
            do {
                let answer = try await inner.send(attempt, timeoutPolicy: timeoutPolicy)
                if !isLast, [502, 503, 504].contains(answer.statusCode) {
                    tried.append(Self.shown(attempt.url) + " (HTTP \(answer.statusCode))")
                    continue
                }
                response = answer
                break
            } catch {
                let failure = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error))
                lock.withLock { last?.failure = failure }
                if isLast || !Self.movable(error) || Task.isCancelled { throw error }
                tried.append(Self.shown(attempt.url) + " (\(failure))")
            }
        }
        guard let response else { throw URLError(.cannotConnectToHost) }
        let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value
        lock.withLock {
            last?.status = response.statusCode
            last?.contentType = type
        }
        let streams = (200..<300).contains(response.statusCode)
        let body = response.body
        let repairedBody = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var repair = SSERepair()
                do {
                    for try await chunk in body {
                        guard streams else {
                            self.keepError(chunk)
                            continuation.yield(chunk)
                            continue
                        }
                        let fixed = repair.feed(chunk)
                        self.note(repair)
                        if !fixed.isEmpty { continuation.yield(fixed) }
                    }
                    if streams {
                        let rest = repair.flush()
                        self.note(repair)
                        if !rest.isEmpty { continuation.yield(rest) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ProviderHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: repairedBody)
    }

    private func note(_ repair: SSERepair) {
        lock.withLock {
            last?.events = repair.events
            last?.repaired = repair.repaired
            last?.sawDone = repair.sawDone
        }
    }

    private func keepError(_ chunk: Data) {
        lock.withLock {
            guard let current = last?.errorBody, current.utf8.count < 1024 else { return }
            last?.errorBody = current + String(decoding: chunk.prefix(1024 - current.utf8.count), as: UTF8.self)
        }
    }

    /// The address as the log shows it: scheme, host, port and path, without a query or a user.
    static func shown(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? "?"
    }

    /// At most 300 characters of the server's words on one line, with the key replaced.
    static func redacted(_ text: String, key: String?) -> String {
        var text = text
        if let key, key.count >= 6 { text = text.replacingOccurrences(of: key, with: "[redacted]") }
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }
}

/// Folds a repeated `data:` prefix (`data:data: {…}`, `data: data: [DONE]`) into one, line by line,
/// across chunk boundaries. A line is passed on once its newline arrives; `flush()` gives the rest.
struct SSERepair {
    private var pending = Data()
    private(set) var events = 0
    private(set) var repaired = 0
    private(set) var sawDone = false

    mutating func feed(_ chunk: Data) -> Data {
        pending.append(chunk)
        guard let end = pending.lastIndex(of: 10) else { return Data() }
        let whole = Data(pending[pending.startIndex...end])
        pending = Data(pending[pending.index(after: end)...])
        return repair(whole)
    }

    mutating func flush() -> Data {
        defer { pending = Data() }
        return pending.isEmpty ? Data() : repair(pending)
    }

    private mutating func repair(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        // Split on the scalar, not the Character: Swift reads "\r\n" as one Character, so a Character
        // split would leave a CRLF stream as one line and fold only its first event.
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        var folded: [String] = []
        for line in lines { folded.append(fold(line)) }
        return Data(folded.joined(separator: "\n").utf8)
    }

    private mutating func fold(_ line: Substring) -> String {
        guard line.hasPrefix("data:") else { return String(line) }
        var rest = line.dropFirst(5)
        var doubled = false
        while rest.drop(while: { $0 == " " }).hasPrefix("data:") {
            rest = rest.drop(while: { $0 == " " }).dropFirst(5)
            doubled = true
        }
        let payload = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !payload.isEmpty { events += 1 }
        if payload == "[DONE]" { sawDone = true }
        if doubled { repaired += 1 }
        return doubled ? "data:" + rest : String(line)
    }
}
