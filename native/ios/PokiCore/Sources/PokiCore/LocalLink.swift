import Foundation

/// Local frames, v1 (docs/ios-core.md, "Local frames, v1"; issue #609): Poki Setup's poki-mcp on a
/// computer talks to the phone without the relay, over the USB cable (usbmuxd forwards a TCP port, as
/// iproxy does) or over Wi-Fi (the app's Bonjour service, `_poki._tcp`). The frames after the
/// handshake are the relay's own (`req`, `res`, `cancel`, `ping`/`pong`), so one MCP server answers
/// both ways. The phone is the listener here, so the handshake runs the other way round: the phone
/// sends a challenge, the computer signs it with its own Ed25519 key (made once by Poki Setup), and
/// the phone signs the computer's nonce back with its relay key, so each side knows the other.
///
/// A computer the owner has not allowed yet waits for their OK on the phone, once; after that its key
/// is remembered and it connects without a prompt. Nothing is answered before the handshake ends.
public enum LocalTransport: String, Sendable {
    case usb, wifi
}

/// Who is on the other end of a local connection, as its hello says.
public struct LocalClient: Sendable, Equatable {
    /// base32 of the computer's public key: the key is the identity.
    public var id: String
    public var key: Data
    public var name: String
    public var app: String
    public var version: String
    public var agent: String
    public var transport: LocalTransport
    /// What the owner sees when asked: "ZhehanZ's MacBook Pro over USB".
    public var describe: String { "\(name) over \(transport == .usb ? "USB" : "Wi-Fi")" }
    /// The connector this computer's calls go through (where a relay request has its secret's hash).
    public var connector: String { "local:\(id)" }
}

/// What a local link needs from the app. Each answer fails closed: a host that does not implement
/// one refuses every computer.
public protocol LocalLinkHost: AnyObject, Sendable {
    func signingKey() throws -> RelayKey
    /// Checks an Ed25519 signature (CryptoKit's Curve25519.Signing on the phone).
    func verify(signature: Data, of message: Data, publicKey: Data) -> Bool
    /// Whether the owner allowed this computer's key before.
    func isTrusted(computer id: String) -> Bool
    /// Asks the owner, on the phone, whether this computer may use Poki. Only the owner answers.
    func approve(computer: LocalClient) async -> Bool
    /// Remembers an allowed computer, so its next connection needs no prompt.
    func trust(computer: LocalClient)
}

struct LocalLinkFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Serves one accepted connection: the handshake, then the computer's requests until it goes.
final class LocalLink: @unchecked Sendable {
    static let maxBody = 16 << 20
    static let handshakeTimeout = 15.0
    /// The owner's answer to a first connection, on top of the handshake's own time.
    static let approvalTimeout = 120.0

    weak var host: LocalLinkHost?
    let handler: @Sendable (RelayRequest) async -> RelayResponse
    var silentLimit = 90.0

    init(host: LocalLinkHost, handler: @escaping @Sendable (RelayRequest) async -> RelayResponse) {
        self.host = host
        self.handler = handler
    }

    static func challengeMessage(phone: String, transport: LocalTransport, nonce: Data) -> Data {
        var m = Data("poki-local-v1:\(phone):\(transport.rawValue):".utf8)
        m.append(nonce)
        return m
    }

    static func answerMessage(computer: String, nonce: Data) -> Data {
        var m = Data("poki-local-v1-phone:\(computer):".utf8)
        m.append(nonce)
        return m
    }

    static func randomNonce() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    /// The handshake. Returns the computer it proved to be, or throws after telling it why.
    func handshake(_ socket: WebSocketConnection, transport: LocalTransport, nonce: Data = LocalLink.randomNonce()) async throws -> LocalClient {
        guard let host else { throw LocalLinkFailure("Poki is shutting down") }
        let key = try host.signingKey()
        let phone = base32(key.publicKey)
        let challenge: JSON = ["t": "challenge", "v": 1, "nonce": .string(nonce.base64EncodedString()), "phone": .string(phone)]
        try await socket.send(challenge.serialized())
        let text = try await withDeadline(Self.handshakeTimeout, "the computer's hello") { try await socket.receive() }
        func refuse(_ reason: String) async -> LocalLinkFailure {
            try? await socket.send((["t": "close", "reason": .string(reason)] as JSON).serialized())
            return LocalLinkFailure(reason)
        }
        guard let hello = try? JSON.parse(text), hello["t"]?.string == "hello", hello["v"]?.int == 1 else {
            throw await refuse("expected hello, v 1")
        }
        guard let computerKey = hello["key"]?.string.flatMap({ Data(base64Encoded: $0) }), computerKey.count == 32,
              let sig = hello["sig"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let cnonce = hello["cnonce"]?.string.flatMap({ Data(base64Encoded: $0) }), cnonce.count >= 16 else {
            throw await refuse("hello needs key, sig and cnonce")
        }
        let id = base32(computerKey)
        let info = hello["client"]
        // The client object agreed for #609: kind "computer"; a missing one would be an agent, which
        // never comes over a local link.
        guard info?["kind"]?.string ?? "computer" == "computer", info?["id"]?.string ?? id == id else {
            throw await refuse("client.id must be the base32 of key")
        }
        guard host.verify(signature: sig, of: Self.challengeMessage(phone: phone, transport: transport, nonce: nonce), publicKey: computerKey) else {
            throw await refuse("the signature does not match the key")
        }
        let client = LocalClient(
            id: id, key: computerKey,
            name: String((info?["name"]?.string ?? "A computer").prefix(60)),
            app: String((info?["app"]?.string ?? "poki-mcp").prefix(40)),
            version: String((info?["version"]?.string ?? "").prefix(20)),
            agent: String((info?["agent"]?.string ?? "").prefix(40)),
            transport: transport)
        if !host.isTrusted(computer: id) {
            try? await socket.send((["t": "waiting", "reason": "the owner is asked on the phone"] as JSON).serialized())
            let ok = (try? await withDeadline(Self.approvalTimeout, "the owner's answer") { [weak host] in await host?.approve(computer: client) ?? false }) ?? false
            guard ok else { throw await refuse("the owner did not allow this computer") }
            host.trust(computer: client)
        }
        let ready: JSON = [
            "t": "ready", "v": 1, "phone": .string(phone), "key": .string(key.publicKey.base64EncodedString()),
            "sig": .string(try key.sign(Self.answerMessage(computer: id, nonce: cnonce)).base64EncodedString()),
            "max_body": .number(Double(Self.maxBody)),
        ]
        try await socket.send(ready.serialized())
        return client
    }

    /// One connection, from the handshake to its end. Requests run side by side; each is answered
    /// once, and a `cancel` stops one.
    func serve(_ socket: WebSocketConnection, transport: LocalTransport) async {
        defer { socket.close(code: 1000, reason: "") }
        guard let client = try? await handshake(socket, transport: transport) else { return }
        let inflight = LockedBox<[String: Task<Void, Never>]>([:])
        let lastHeard = LockedBox(now())
        let watchdog = Task { [silentLimit] in
            while !Task.isCancelled {
                await sleep(seconds: 5)
                if now() - lastHeard.value > silentLimit { socket.close(code: 4408, reason: "silent"); return }
            }
        }
        defer {
            watchdog.cancel()
            inflight.value.values.forEach { $0.cancel() }
        }
        while true {
            guard let text = try? await socket.receive() else { return }
            lastHeard.value = now()
            if text == "ping" { try? await socket.send("pong"); continue }
            guard let frame = try? JSON.parse(text) else { continue }
            switch frame["t"]?.string {
            case "req":
                guard let id = frame["id"]?.string else { continue }
                var headers: [String: String] = [:]
                for (k, v) in frame["headers"]?.object ?? [:] { if let s = v.string { headers[k.lowercased()] = s } }
                // Set from the handshake only, never from what the computer sent.
                headers[PokiCore.connectorHeader] = client.connector
                headers[PokiCore.transportHeader] = transport.rawValue
                let request = RelayRequest(id: id, method: frame["method"]?.string ?? "POST", headers: headers, body: frame["body"]?.string ?? "")
                let handler = self.handler
                let task = Task {
                    let response = await handler(request)
                    guard inflight.update({ $0.removeValue(forKey: id) != nil }), !Task.isCancelled else { return }
                    try? await socket.send(Self.frame(for: response).serialized())
                }
                inflight.update { $0[id] = task }
            case "cancel":
                if let id = frame["id"]?.string { inflight.update { $0.removeValue(forKey: id) }?.cancel() }
            case "close":
                return
            default:
                continue
            }
        }
    }

    static func frame(for response: RelayResponse) -> JSON {
        var r = response
        if r.body.utf8.count > maxBody - 1024 {
            r.status = 200
            r.headers["content-type"] = "application/json"
            r.body = (["jsonrpc": "2.0", "id": .null, "error": ["code": -32603, "message": "the answer was too large for the local link"]] as JSON).serialized()
        }
        return ["t": "res", "id": .string(r.id), "status": .number(Double(r.status)), "headers": .object(r.headers.mapValues(JSON.string)), "body": .string(r.body)]
    }
}

extension PokiCore {
    /// Which way a request came: "usb" or "wifi" for a local link, absent for the relay.
    public static let transportHeader = "x-poki-transport"

    /// Serves one connection the app's listener accepted (a TCP connection on the local port, framed
    /// one message per line by the app). Returns when the computer goes.
    public func serveLocal(_ connection: WebSocketConnection, transport: LocalTransport, host: LocalLinkHost) async {
        let link = LocalLink(host: host) { [weak self] request in
            await self?.handle(request) ?? RelayResponse(id: request.id, status: 503, headers: [:], body: "")
        }
        await link.serve(connection, transport: transport)
    }
}
