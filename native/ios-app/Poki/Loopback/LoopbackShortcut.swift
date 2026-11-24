import Foundation
import Network
import SwiftUI

/// Receives the Poki Loopback shortcut on this iPhone's own address.
@MainActor
final class LoopbackShortcut: ObservableObject {
    static let shared = LoopbackShortcut()
    private static let shortcut = URL(string: "https://www.icloud.com/shortcuts/f8ff9cd906194fbf8a58ed51137f6c0a")!
    static let run = URL(string: "shortcuts://run-shortcut?name=Poki%20Loopback")!

    @Published private(set) var lastAt = UserDefaults.standard.object(forKey: "history.reconnect.at") as? Date
    @Published private(set) var lastWorked = UserDefaults.standard.bool(forKey: "history.reconnect.ok")
    @Published private(set) var canRun = UserDefaults.standard.string(forKey: "loopback.shortcutLink") == LoopbackShortcut.shortcut.absoluteString

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nz.zheha.poki.loopback.shortcut")

    var isSetUp: Bool { lastAt != nil && lastWorked }

    func take(model: AppModel) -> URL {
        canRun = true
        UserDefaults.standard.set(Self.shortcut.absoluteString, forKey: "loopback.shortcutLink")
        start(model: model)
        return Self.shortcut
    }

    func start(model: AppModel) {
        guard canRun, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 47684)
        guard let listener = try? NWListener(using: parameters) else { return }
        let queue = self.queue
        listener.newConnectionHandler = { [weak self, weak model] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak model] bytes, _, _, _ in
                let line = bytes.flatMap { String(data: $0, encoding: .utf8) }?.split(whereSeparator: \.isNewline).first
                let parts = line?.split(separator: " ") ?? []
                Task { @MainActor [weak self, weak model] in
                    guard let self, let model, parts.count == 3, ["GET", "POST"].contains(parts[0]),
                          ["/ready", "/reconnect"].contains(parts[1]) else {
                        Self.reply("404 Not Found", body: "false", to: connection)
                        return
                    }
                    let ready = parts[1] == "/ready"
                    let worked = await self.check(model: model)
                    // Do not ask the shortcut to toggle radios when Wi-Fi can carry the probe.
                    let answer = worked || (ready && model.loopback.onWiFi)
                    Self.reply("200 OK", body: answer ? "true" : "false", to: connection)
                }
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.listener?.cancel(); self?.listener = nil }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func check(model: AppModel) async -> Bool {
        let monitor = model.loopback
        let requested = Date.now
        monitor.check()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while monitor.checkedAt.map({ $0 < requested }) ?? true {
            guard clock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let worked = monitor.isWorking
        lastAt = .now
        lastWorked = worked
        UserDefaults.standard.set(lastAt, forKey: "history.reconnect.at")
        UserDefaults.standard.set(worked, forKey: "history.reconnect.ok")
        return worked
    }

    private static func reply(_ status: String, body: String, to connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
