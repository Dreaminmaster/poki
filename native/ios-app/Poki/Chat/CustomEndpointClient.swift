import Foundation
import PiSwiftAI

/// pi's HTTP client for a custom OpenAI-compatible address, with two additions.
///
/// It repairs a stream some gateways (a vLLM backend behind one, issue #344) send when asked for
/// `text/event-stream`: each event comes as `data:data: {…}`, which pi's parser reads as `data: {…}`,
/// not JSON, so every chunk was dropped and the answer ended with "Stream ended without finish_reason".
/// A repeated `data:` prefix is folded into one; every other line passes through unchanged.
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

        /// One line for Poki's log, without the key.
        func summary(key: String?) -> String {
            var parts = ["custom address \(url)"]
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

    init(inner: any ProviderHTTPClient = DefaultProviderHTTPClient()) {
        self.inner = inner
    }

    /// What the address answered to the last request, or nil before the first.
    var seen: Seen? { lock.withLock { last } }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await send(request, timeoutPolicy: .request)
    }

    func send(_ request: URLRequest, timeoutPolicy: ProviderHTTPTimeoutPolicy) async throws -> ProviderHTTPResponse {
        lock.withLock { last = Seen(url: Self.shown(request.url)) }
        let response: ProviderHTTPResponse
        do {
            response = try await inner.send(request, timeoutPolicy: timeoutPolicy)
        } catch {
            let failure = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error))
            lock.withLock { last?.failure = failure }
            throw error
        }
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
