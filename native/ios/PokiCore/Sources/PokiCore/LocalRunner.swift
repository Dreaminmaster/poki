import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The runner's requests answered in this process (the app's InProcessWDA): WebDriverAgent's routes,
/// served the way WebDriverAgent serves them, so PokiCore's `Runner` (its deadlines, its one session,
/// its retry on a lost session) works unchanged. `serve` answers one request; this type decides when
/// it runs: one at a time on one queue, as WDA serves its requests on one thread, and screenshots
/// beside that queue, as WDA does.
public final class LocalRunner: HTTPTransport, @unchecked Sendable {
    /// One request, with the session and element ids taken out of its path: "/session/<id>/wda/tap"
    /// is "POST /wda/tap" for session <id>; "/element/<id>/rect" is "GET /element/rect".
    public struct Request: Sendable {
        public var key: String
        public var session: String?
        public var element: String?
        public var body: JSON?
    }
    public typealias Serve = @Sendable (Request) -> (status: Int, body: Data)

    private let serve: Serve
    private struct Lanes {
        /// One action or read at a time. Replaced when a request holds it for good (see `send`), as a
        /// restarted runner is a new process.
        var queue = DispatchQueue(label: "poki.inprocess.wda", qos: .userInitiated)
        /// The request the queue is serving now and when it began.
        var inFlight: (key: String, since: Double)?
    }
    private let state = LockedBox(Lanes())
    /// Screenshots are answered beside the queue, as WDA does.
    private let pictures = DispatchQueue(label: "poki.inprocess.screenshot", qos: .userInitiated)

    public init(serve: @escaping Serve) {
        self.serve = serve
    }

    static func request(method: String, path: String, body: Data?) -> Request {
        var parts = path.split(separator: "/").map(String.init)
        var session: String?
        if parts.first == "session", parts.count >= 2 { session = parts[1]; parts.removeFirst(2) }
        var element: String?
        if parts.first == "element", parts.count >= 3 { element = parts[1]; parts.remove(at: 1) }
        let short = parts.isEmpty ? "/session" : "/" + parts.joined(separator: "/")
        return Request(key: "\(method) \(short)", session: session, element: element, body: body.flatMap { try? JSON.parse($0) })
    }

    public func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        let request = Self.request(method: method, path: url.path, body: body)
        let key = request.key
        // A request that never comes back (the gym's dense screen: an accessibility snapshot of 1,500
        // elements held the queue past PokiCore's 15 s wedge watchdog) would hold every request after
        // it, the way a wedged WebDriverAgent holds its one thread. The watchdog drops the session and
        // the next call opens a new one: that open gets a new queue, and the held request is left to
        // end on its own, as a restarted runner leaves its old process.
        let lane: DispatchQueue = state.update { s in
            if key == "POST /session", let held = s.inFlight, Date().timeIntervalSince1970 - held.since > 8 {
                s.queue = DispatchQueue(label: "poki.inprocess.wda", qos: .userInitiated)
                s.inFlight = nil
            }
            return key == "GET /screenshot" ? pictures : s.queue
        }
        let asked = Date()
        return await withCheckedContinuation { continuation in
            lane.async { [self] in
                let began = Date().timeIntervalSince1970
                let started = Date()
                if key != "GET /screenshot" { state.update { $0.inFlight = (key, began) } }
                let out = serve(request)
                if key != "GET /screenshot" { state.update { if $0.inFlight?.since == began { $0.inFlight = nil } } }
                // One line per request in the system log (PokiInProcess), with its wait in the queue and
                // its own time, so a slow call can be traced to the request that took it.
                let waited = Int(started.timeIntervalSince(asked) * 1000), took = Int(Date().timeIntervalSince(started) * 1000)
                if waited > 5 || took > 5 { NSLog("%@", "PokiInProcess timing: \(key) \(took) ms\(waited > 5 ? " (queued \(waited) ms)" : "")") }
                continuation.resume(returning: out)
            }
        }
    }
}
