import Foundation
import Network
import SwiftUI

/// The ways a shortcut asks Poki to open its connection again, and the note of the last time one did.
///
/// A shortcut that is shared as a link names the Reconnect Poki action by the bundle id of the Poki
/// it was made with, and every owner's Poki has its own (the team is part of it), so the action is
/// missing on any other iPhone. A request to this iPhone itself has no such name in it: the shared
/// shortcut asks `http://127.0.0.1:47684/reconnect`, which answers `true` as soon as the tunnel opens
/// (at most a few seconds) and keeps trying in the background as the network changes. The address is the
/// iPhone's own, which iOS never refuses, on Wi-Fi or cellular.
///
/// `http://127.0.0.1:47684/ready` is the question to ask before Cellular Data goes off. It answers
/// `true` when there is nothing to do (the tunnel still answers, or Wi-Fi is there), and otherwise
/// `false` once the proxy's VPN has been steady for a few seconds: turned off any sooner after
/// Wi-Fi dropped, cellular took the VPN down with it and no connection could be made at all.
///
/// The shared shortcut, Poki Loopback (the owner's, 2026-11-20), asks in that order: Set VPN, `/ready`,
/// and only on `false` Wi-Fi off, Cellular Data off, `/reconnect`, Cellular Data on, Wi-Fi on. So it
/// changes nothing while the connection is fine, and can be run at any time the loopback is off.
@MainActor
final class HistoryReconnect: ObservableObject {
    static let shared = HistoryReconnect()

    static let port: UInt16 = 47684
    /// The shared shortcut, Poki Loopback, with its Wi-Fi automation. The owner's link (2026-11-20).
    static let shortcut = URL(string: "https://www.icloud.com/shortcuts/cef403d76ef04d0586d03dd69476b96e")!
    /// Runs the shared shortcut by the name it arrives with.
    static let run = URL(string: "shortcuts://run-shortcut?name=Poki%20Loopback")!

    /// When a shortcut last asked, and whether a read came through.
    @Published private(set) var lastAt: Date? = UserDefaults.standard.object(forKey: "history.reconnect.at") as? Date
    @Published private(set) var lastWorked = UserDefaults.standard.bool(forKey: "history.reconnect.ok")

    /// The owner was shown the shortcut in Setup and opened it or its steps: the loopback step no
    /// longer waits on this page for it.
    @Published var asked = UserDefaults.standard.bool(forKey: "loopback.cellularAsked") {
        didSet { UserDefaults.standard.set(asked, forKey: "loopback.cellularAsked") }
    }

    /// The link of the shared shortcut the owner last opened from Poki. The one before it had
    /// another name (Poki Loopback Cellular) and did not ask `/ready`, so it is not run by name.
    @Published private(set) var opened = UserDefaults.standard.string(forKey: "loopback.shortcutLink") {
        didSet { UserDefaults.standard.set(opened, forKey: "loopback.shortcutLink") }
    }

    /// Whether the owner got the shortcut that can be run at any time: Run the Shortcut is offered.
    var canRun: Bool { opened == Self.shortcut.absoluteString }

    /// The owner opens the shared shortcut's link: the link to open, noted as shown and as theirs.
    func take() -> URL {
        asked = true
        opened = Self.shortcut.absoluteString
        return Self.shortcut
    }

    /// The shortcut asked Poki to reconnect at least once on this iPhone: it is set up. Screen
    /// History cannot be turned on before that (the owner, 2026-11-19: optional in Setup, needed
    /// for Screen History). A switch that is already on stays on.
    var isSetUp: Bool { lastAt != nil }

    /// The Screen History switch, which turns on only once the shortcut is set up.
    static func gated(_ enabled: Binding<Bool>, refused: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { enabled.wrappedValue },
            set: { on in
                if on, !shared.isSetUp {
                    refused.wrappedValue = true
                } else {
                    enabled.wrappedValue = on
                }
            }
        )
    }

    private var listener: NWListener?
    private nonisolated let queue = DispatchQueue(label: "nz.zheha.poki.history.reconnect")

    /// A shortcut asked and got its answer. The collector's own line says what happened.
    func note(worked: Bool) {
        lastAt = Date()
        lastWorked = worked
        UserDefaults.standard.set(lastAt, forKey: "history.reconnect.at")
        UserDefaults.standard.set(worked, forKey: "history.reconnect.ok")
    }

    /// Listens while Poki runs, and only on this iPhone's own address.
    func listen(_ on: Bool, model: AppModel) {
        guard on != (listener != nil) else { return }
        guard on else {
            listener?.cancel()
            listener = nil
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: parameters) else {
            AppLog.shared.add("loopback", "reconnect: cannot listen on 127.0.0.1:\(Self.port)")
            return
        }
        let queue = queue
        listener.newConnectionHandler = { [weak model] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let first = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let reconnects = first.hasPrefix("GET /reconnect") || first.hasPrefix("POST /reconnect")
                let readies = first.hasPrefix("GET /ready") || first.hasPrefix("POST /ready")
                let asks = reconnects || readies
                Task { @MainActor in
                    var body = "not found"
                    if asks, let model {
                        let collector = HistoryCollector.shared
                        let yes: Bool
                        if readies {
                            yes = await collector.ready(model, by: "a shortcut")
                        } else {
                            yes = await collector.reconnectSoon(model, by: "a shortcut")
                        }
                        body = yes ? "true" : "false"
                    }
                    let answer = "HTTP/1.1 \(asks ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    AppLog.shared.add("loopback", "reconnect: the listener failed: \(error.localizedDescription)")
                    self?.listener?.cancel()
                    self?.listener = nil
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }
}
