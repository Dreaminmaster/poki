import Foundation
import Network

/// The ways a shortcut asks Poki to open its connection again, and the note of the last time one did.
///
/// A shortcut that is shared as a link names the Reconnect Poki action by the bundle id of the Poki
/// it was made with, and every owner's Poki has its own (the team is part of it), so the action is
/// missing on any other iPhone. A request to this iPhone itself has no such name in it: the shared
/// shortcut asks `http://127.0.0.1:47684/reconnect` and reads `true` or `false`. The address is the
/// iPhone's own, which iOS never refuses, on Wi-Fi or cellular.
@MainActor
final class HistoryReconnect: ObservableObject {
    static let shared = HistoryReconnect()

    static let port: UInt16 = 47684
    /// The shared shortcut with its Wi-Fi automation. The owner's link (2026-11-19).
    static let shortcut = URL(string: "https://www.icloud.com/shortcuts/6f41ee00f86746188a48cf40db83e512")!

    /// When a shortcut last asked, and whether a read came through.
    @Published private(set) var lastAt: Date? = UserDefaults.standard.object(forKey: "history.reconnect.at") as? Date
    @Published private(set) var lastWorked = UserDefaults.standard.bool(forKey: "history.reconnect.ok")

    private var listener: NWListener?
    private nonisolated let queue = DispatchQueue(label: "nz.zheha.poki.history.reconnect")

    func note(worked: Bool, by source: String) {
        lastAt = Date()
        lastWorked = worked
        UserDefaults.standard.set(lastAt, forKey: "history.reconnect.at")
        UserDefaults.standard.set(worked, forKey: "history.reconnect.ok")
        AppLog.shared.add("loopback", "reconnect asked by \(source): \(worked ? "connected" : "not connected")")
    }

    /// Listens while Screen History is on, and only on this iPhone's own address.
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
                let asks = first.hasPrefix("GET /reconnect") || first.hasPrefix("POST /reconnect")
                Task { @MainActor in
                    var body = "not found"
                    if asks, let model {
                        body = await HistoryCollector.shared.reconnect(model, by: "a shortcut") ? "true" : "false"
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
