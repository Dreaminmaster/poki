import CryptoKit
import Foundation
import Network
import PokiCore

/// The app's side of local frames, v1 (issue #609): a TCP listener that Poki Setup's poki-mcp
/// reaches over the USB cable (usbmuxd forwards the port, as iproxy does) or, on the same Wi-Fi,
/// through the Bonjour service `_poki._tcp`. PokiCore does the handshake and answers the requests;
/// this only accepts connections and frames them one message per line.
///
/// Unconfirmed on a phone: which interface a usbmuxd-forwarded connection reports. A connection that
/// does not come over Wi-Fi is taken as USB; the computer's signed hello names its transport too, and
/// a hello signed for another transport is refused.
final class LocalListener: @unchecked Sendable {
    static let port: NWEndpoint.Port = 47_100
    static let service = "_poki._tcp"

    private let queue = DispatchQueue(label: "poki.local-listener")
    private let lock = NSLock()
    /// Guarded by `lock`: `start` and `stop` run on the caller's thread, a failure on `queue`.
    private var listener: NWListener?
    private let serve: @Sendable (WebSocketConnection, LocalTransport) async -> Void
    private let log: @Sendable (String) -> Void

    init(serve: @escaping @Sendable (WebSocketConnection, LocalTransport) async -> Void, log: @escaping @Sendable (String) -> Void) {
        self.serve = serve
        self.log = log
    }

    /// Starts listening; `name` is the Bonjour name computers see (the phone's name).
    func start(name: String) {
        guard lock.withLock({ listener == nil }) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: Self.port)
            listener.service = NWListener.Service(name: String(name.prefix(60)), type: Self.service)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener, log] state in
                switch state {
                case .ready: log("listening for computers on port \(Self.port.rawValue)")
                case .failed(let error):
                    log("local listener failed: \(error)")
                    // A failed listener never listens again: it is let go so the next start makes a new one.
                    listener?.cancel()
                    self?.forget(listener)
                default: break
                }
            }
            lock.withLock { self.listener = listener }
            listener.start(queue: queue)
        } catch {
            log("local listener could not start: \(error)")
        }
    }

    func stop() {
        let stopped = lock.withLock { () -> NWListener? in
            defer { listener = nil }
            return listener
        }
        stopped?.cancel()
    }

    /// Lets go of `failed` if it is still the current listener (a newer one is kept).
    func forget(_ failed: NWListener?) {
        lock.withLock { if let failed, listener === failed { listener = nil } }
    }

    private func accept(_ connection: NWConnection) {
        // The path is known only once the connection is ready; read before, it is nil and Wi-Fi would
        // be taken for USB (and the computer's hello, signed for Wi-Fi, refused).
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                let transport = Self.transport(of: connection.currentPath)
                self.log("a computer connected over \(transport.rawValue)")
                let framed = LineConnection(connection)
                Task { [serve] in await serve(framed, transport) }
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// The transport a ready connection came over: Wi-Fi when its path uses Wi-Fi, otherwise USB.
    static func transport(of path: NWPath?) -> LocalTransport {
        path?.usesInterfaceType(.wifi) == true ? .wifi : .usb
    }
}

/// One message per line over a TCP connection. JSON serialized by PokiCore never holds a raw newline,
/// and the keepalive is the bare words "ping" and "pong".
final class LineConnection: WebSocketConnection, @unchecked Sendable {
    static let maxLine = 17 << 20
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ text: String) async throws {
        var data = Data(text.utf8)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> String {
        while true {
            if let line = lock.withLock({ () -> Data? in
                guard let end = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return Data(line)
            }) {
                return String(decoding: line, as: UTF8.self)
            }
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                    if let error { c.resume(throwing: error); return }
                    if let data, !data.isEmpty { c.resume(returning: data); return }
                    if done { c.resume(throwing: NWError.posix(.ECONNRESET)); return }
                    c.resume(returning: Data())
                }
            }
            let tooLong = lock.withLock { buffer.append(chunk); return buffer.count > Self.maxLine }
            if tooLong { close(code: 1009, reason: "line too long"); throw NWError.posix(.EMSGSIZE) }
        }
    }

    func close(code: Int, reason: String) { connection.cancel() }
}

/// The computers the owner allowed, by key, and the checks PokiCore asks for. The keys are public, so
/// the list lives in the app's defaults; forgetting a computer is removing its id.
final class LocalComputers: LocalLinkHost, @unchecked Sendable {
    static let key = "local.trustedComputers"
    private let host: AppCoreHost
    private let ask: @Sendable (LocalClient) async -> Bool

    init(host: AppCoreHost, ask: @escaping @Sendable (LocalClient) async -> Bool) {
        self.host = host
        self.ask = ask
    }

    func signingKey() throws -> RelayKey { try host.signingKey() }

    func verify(signature: Data, of message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    func isTrusted(computer id: String) -> Bool { Self.trusted[id] != nil }

    func approve(computer: LocalClient) async -> Bool { await ask(computer) }

    func trust(computer: LocalClient) {
        var all = Self.trusted
        all[computer.id] = computer.name
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    /// id → the name it gave when it was allowed.
    static var trusted: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
    static func forget(_ id: String) {
        var all = trusted
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: key)
    }
}
