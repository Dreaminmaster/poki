import SwiftUI
import UIKit

/// The cellular test (issue 484): does a connection opened while the iPhone has no cellular at all
/// stay open once cellular is back, although iOS refuses every new one there?
///
/// Two things are logged side by side every few seconds while the owner switches Wi-Fi, Airplane
/// Mode or Cellular Data by hand: whether a NEW connection to 10.7.0.1 is accepted, and whether the
/// launcher's one held tunnel still reads the screen (the same run Screen History uses). The trick
/// is proven when reads go on while new connections are refused on cellular alone.
@MainActor
@Observable
final class CellularTrick {
    static let shared = CellularTrick()

    private(set) var lines: [String] = []
    private(set) var running = false
    private(set) var verdict = ""
    private var record: [[String: Any]] = []
    private var lastRead: (ok: Bool, at: Date, error: String)?
    private var run = 0

    static let seconds = 180
    private static let every = 3

    func start(model: AppModel) {
        guard !running else { return }
        guard let pairing = model.pairingPath else { note("not paired: nothing to test", ["step": "refused"]); return }
        running = true
        run += 1
        let me = run
        lines = []; record = []; lastRead = nil; verdict = ""
        // Screen History's own run would share the launcher: it stands aside until Poki is opened again.
        HistoryCollector.shared.ownerStop()
        note("Leave Poki after Start: open Settings or another app, and come back to read the log.", ["step": "hint"])
        note("start: \(Self.seconds) s. Switch Wi-Fi off, then Airplane Mode (or Cellular Data) on and off, and watch.", ["step": "begin"])
        let screen = UIScreen.main.bounds
        let points = [0.5, 0.3, 0.7, 0.15].map { [Double(screen.midX), Double(screen.height) * $0] }
        let request: [String: Any] = [
            "op": "run", "device_address": "10.7.0.1", "pairing_file": pairing, "host_name": "Poki",
            "direct_points": points, "interval_ms": Self.every * 1000, "duration_s": Self.seconds,
        ]
        // The held tunnel: one launcher run for the whole test. It opens a tunnel at its first read
        // and a new one only after a read failed.
        Task {
            do {
                let answer = try await HistoryBridge.call(request) { [weak self] data in
                    Task { @MainActor [weak self] in
                        // A line about the tunnel (opened, lost, a check answered) is not a read.
                        guard let self, self.run == me, let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], line["event"] == nil else { return }
                        self.lastRead = (line["ok"] as? Bool == true, Date(), line["error"] as? String ?? "")
                    }
                }
                guard self.run == me else { return }
                let summary = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
                self.note("launcher: \(summary["reads"] ?? "?") reads, \(summary["failures"] ?? "?") failed, \(summary["connections"] ?? "?") tunnels opened, longest gap \(summary["longest_gap_ms"] ?? "?") ms",
                          (["step": "launcher_summary"] as [String: Any]).merging(summary) { a, _ in a })
            } catch {
                guard self.run == me else { return }
                self.note("launcher: the run ended: \(error.localizedDescription)", ["step": "launcher_error", "error": error.localizedDescription])
            }
            self.finish(me)
        }
        // The new connections: one try each round, beside the held tunnel.
        Task {
            let began = Date()
            var heldOnCellular = 0
            var openedWithoutCellular = false
            while self.run == me, Date().timeIntervalSince(began) < Double(Self.seconds) {
                let fresh = await probe(label: "trick", host: "10.7.0.1", port: RemotePairingPort.current, timeout: 1.5)
                guard self.run == me else { return }
                let monitor = model.loopback
                let network = monitor.wifiUp ? (monitor.cellularUp ? "Wi-Fi and cellular" : "Wi-Fi") : monitor.cellularUp ? "cellular only" : "no network"
                let read = self.lastRead.flatMap { Date().timeIntervalSince($0.at) < Double(Self.every * 2 + 12) ? $0 : nil }
                let held = read.map { $0.ok ? "reads" : "FAILS (\($0.error.replacingOccurrences(of: "no tree at hit test: no point of the screen answered the hit test ", with: "hit test ").prefix(220)))" } ?? "no read yet"
                let accepted = fresh.outcome == "connected"
                if !monitor.cellularUp, read?.ok == true { openedWithoutCellular = true }
                if monitor.cellularUp, !monitor.wifiUp, read?.ok == true, !accepted { heldOnCellular += 1 }
                self.note(String(format: "%3d s  %@  new connection: %@  held tunnel: %@", Int(Date().timeIntervalSince(began)), network, fresh.outcome, held),
                          ["step": "round", "wifi": monitor.wifiUp, "cellular": monitor.cellularUp, "new": fresh.outcome, "held_ok": read?.ok ?? false, "held_error": read?.error ?? ""])
                // Three rounds in a row is about ten seconds of reading on a connection iOS would not open now.
                if heldOnCellular >= 3, self.verdict.isEmpty {
                    self.verdict = openedWithoutCellular ? "Proven: reads go on over cellular while new connections are refused."
                        : "Reads go on over cellular while new connections are refused (the tunnel was opened before the test saw no cellular)."
                    self.note(self.verdict, ["step": "verdict", "proven": true])
                }
                try? await Task.sleep(for: .seconds(Self.every))
            }
        }
    }

    func stop() {
        guard running else { return }
        HistoryBridge.cancel()
        finish(run)
    }

    private func finish(_ me: Int) {
        guard me == run, running else { return }
        run += 1
        running = false
        if verdict.isEmpty {
            verdict = "Not shown in this run: reading on cellular alone with new connections refused was not seen for ten seconds."
            note(verdict, ["step": "verdict", "proven": false])
        }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("cellular-trick.json"))
    }

    private func note(_ line: String, _ fields: [String: Any]) {
        var entry = fields
        entry["at"] = Date().timeIntervalSince1970
        entry["line"] = line
        record.append(entry)
        lines.append(line)
        AppLog.shared.add("cellular-test", line)
    }
}

/// General › Testing Options › Cellular Connection Test. Diagnostics text, in English like the
/// other probes' output.
struct CellularTrickSection: View {
    @Environment(AppModel.self) private var model
    private var test: CellularTrick { CellularTrick.shared }

    var body: some View {
        Section {
            if test.running {
                Button("Stop", role: .destructive) { test.stop() }
            } else {
                Button("Start Cellular Connection Test") { test.start(model: model) }
            }
            if !test.verdict.isEmpty { Text(test.verdict).font(.allo(.callout, .semibold)) }
            ForEach(Array(test.lines.suffix(12).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Run Reconnect Now") { Task { _ = await HistoryCollector.shared.reconnect(model, by: "Testing Options") } }
                .disabled(test.running)
        } header: {
            Text("Cellular Connection Test")
        } footer: {
            Group {
                Text("1. Turn Wi-Fi off and tap Start. New connections should be refused. 2. Turn Airplane Mode on with Wi-Fi still off, or turn Cellular Data off, and wait until the held tunnel reads. 3. Turn it back. If the held tunnel keeps reading while new connections are refused, the trick works. The log is saved as cellular-trick.json and in the app log.")
            }
            .settingsFooter()
        }
    }
}
