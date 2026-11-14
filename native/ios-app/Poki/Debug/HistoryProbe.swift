import SwiftUI
import UIKit

/// poki_history_* through the C ABI (native/launcher/src/history.rs): the screen read as text through
/// the accessibility audit service, on a tunnel of its own and with no XCTest session.
enum HistoryBridge {
    final class Box: @unchecked Sendable {
        let progress: (@Sendable (Data) -> Void)?
        var continuation: CheckedContinuation<Data, Error>?
        init(progress: (@Sendable (Data) -> Void)?, continuation: CheckedContinuation<Data, Error>) {
            self.progress = progress
            self.continuation = continuation
        }
    }

    struct Failure: LocalizedError {
        let message: String
        let fix: String?
        let code: String
        var errorDescription: String? { message }
    }

    /// Runs one request. The answer is the result's `value` as JSON; `progress` gets every read of a
    /// run as JSON, on a launcher thread.
    static func call(_ request: [String: Any], progress: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let box = Unmanaged.passRetained(Box(progress: progress, continuation: c))
            let rc = String(decoding: json, as: UTF8.self).withCString { text in
                poki_history_call(text, { context, event in
                    guard let context, let event else { return }
                    let unmanaged = Unmanaged<Box>.fromOpaque(context)
                    let box = unmanaged.takeUnretainedValue()
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: event).utf8))) as? [String: Any] else { return }
                    if object["event"] as? String == "result" {
                        if object["ok"] as? Bool == true {
                            let value = (try? JSONSerialization.data(withJSONObject: object["value"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                            box.continuation?.resume(returning: value)
                        } else {
                            box.continuation?.resume(throwing: Failure(message: object["error"] as? String ?? "The read failed.", fix: object["fix"] as? String, code: object["code"] as? String ?? ""))
                        }
                        box.continuation = nil
                        unmanaged.release()
                    } else if let line = object["progress"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: line) {
                        box.progress?(data)
                    }
                }, box.toOpaque())
            }
            if rc != 0 {
                box.takeUnretainedValue().continuation = nil
                box.release()
                c.resume(throwing: Failure(message: "The launcher did not take the request.", fix: nil, code: "config"))
            }
        }
    }

    static func cancel() { poki_history_cancel() }
}

/// The first two iPhone History tests (GitHub issue 356), in Testing Options.
///
/// One read: reads the screen once through the accessibility audit service and reports the seconds it
/// took, the apps on screen and the number of elements. The tester reports what iOS showed.
///
/// Background run: reads every few seconds for a set time while Poki is in the background and the
/// phone is in use, then reports the reads made, the failures, the longest gap and the battery used.
///
/// Nothing is stored and no screen text is shown or logged: only counts, timings and app ids. The log
/// is also written to Documents/history-test-log.txt, so it survives Poki being ended by iOS.
@MainActor
final class HistoryProbe: ObservableObject {
    static let shared = HistoryProbe()

    @Published var lines: [String] = []
    @Published var reading = false
    @Published var running = false
    @Published var minutes = 30
    @Published var seconds = 5
    @Published var keepAwake = true

    private let keepAlive = KeepAlive()
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var started: Date?
    private var batteryAtStart: Float = -1
    private var progressSeen = 0
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("history-test-log.txt")
    private static let limit = 400

    init() {
        if let previous = try? String(contentsOf: file, encoding: .utf8), !previous.isEmpty {
            lines = ["previous run:"] + previous.split(separator: "\n").suffix(Self.limit).map(String.init)
        }
    }

    private func note(_ line: String, keep: Bool = true) {
        let now = Date()
        let since = started.map { String(format: " +%.0fs", now.timeIntervalSince($0)) } ?? ""
        let entry = "\(now.formatted(.dateTime.hour().minute().second()))\(since) \(line)"
        lines.append(entry)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        AppLog.shared.add("history", line)
        guard keep, let data = (entry + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
    }

    private func makeRequest(_ op: String, model: AppModel) -> [String: Any]? {
        guard let path = model.pairingPath else {
            note("not paired: finish Setup > Pairing first", keep: false)
            return nil
        }
        return ["op": op, "device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki"]
    }

    /// What was true around the read, for the tester's report.
    private func context(model: AppModel) -> String {
        let session = model.hasOpenInProcessSession ? "OPEN (a banner now may be the session's, not the read's)" : "closed"
        let front = UIApplication.shared.applicationState == .active ? "front" : "background"
        return "automation session \(session), loopback \(model.loopback.isWorking ? "working" : "not working"), Poki in \(front)"
    }

    private static func apps(_ value: [String: Any]) -> String {
        let all = (value["applications"] as? [[String: Any]] ?? []).map { ($0["bundle_id"] as? String) ?? ($0["name"] as? String) ?? "?" }
        let front = (value["front"] as? [String: Any]).flatMap { ($0["bundle_id"] as? String) ?? ($0["name"] as? String) }
        if let front { return "front app \(front)" }
        return all.isEmpty ? "no app named" : "apps on screen \(all.joined(separator: ", "))"
    }

    /// One read, after `delay` seconds (time to leave Poki and put another app in front).
    func readOnce(model: AppModel, delay: Int = 0) async {
        guard !reading, !running, var request = makeRequest("read_once", model: model) else { return }
        reading = true
        defer { reading = false }
        request["include_text"] = false
        note("one read\(delay > 0 ? " in \(delay) s" : ""): \(context(model: model))", keep: false)
        if delay > 0 {
            if keepAwake { try? keepAlive.start() }
            let hold = UIApplication.shared.beginBackgroundTask(withName: "poki-history-read")
            try? await Task.sleep(for: .seconds(delay))
            defer { keepAlive.stop(); if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) } }
            await answerOnce(request, model: model)
        } else {
            await answerOnce(request, model: model)
        }
    }

    private func answerOnce(_ request: [String: Any], model: AppModel) async {
        do {
            let data = try await HistoryBridge.call(request)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            func ms(_ key: String) -> String { (value[key] as? Int).map { String(format: "%.2f s", Double($0) / 1000) } ?? "none" }
            note("read ok: connect \(ms("connect_ms")), read \(ms("read_ms")), second read \(ms("second_read_ms"))", keep: false)
            note("\(Self.apps(value)), \(value["elements"] as? Int ?? 0) elements, \(value["text_lines"] as? Int ?? 0) text lines, \(value["text_characters"] as? Int ?? 0) characters, \(value["secure_fields_left_out"] as? Int ?? 0) password fields left out", keep: false)
            note("after: \(context(model: model)). Did iOS show a banner, an indicator or a prompt?", keep: false)
        } catch {
            let failure = error as? HistoryBridge.Failure
            note("read failed (\(failure?.code ?? "error")): \(error.localizedDescription)", keep: false)
            if let fix = failure?.fix { note(fix, keep: false) }
        }
    }

    func startRun(model: AppModel) {
        guard !running, !reading, var request = makeRequest("run", model: model) else { return }
        try? FileManager.default.removeItem(at: file)
        lines = []
        started = Date()
        running = true
        progressSeen = 0
        request["interval_ms"] = seconds * 1000
        request["duration_s"] = minutes * 60
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryAtStart = UIDevice.current.batteryLevel
        note("run: a read every \(seconds) s for \(minutes) min, battery \(Self.percent(batteryAtStart)), charging \(Self.charging), keep awake \(keepAwake ? "on" : "off")")
        note(context(model: model))
        if keepAwake {
            do { try keepAlive.start(); note("silent audio keep-alive playing") } catch { note("keep-alive did not start: \(error.localizedDescription)") }
        }
        observe()
        Task {
            do {
                let data = try await HistoryBridge.call(request) { [weak self] line in
                    Task { @MainActor in self?.progress(line) }
                }
                let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                self.finish(value, model: model)
            } catch {
                self.note("run failed: \(error.localizedDescription)")
                self.end()
            }
        }
    }

    func stopRun() {
        guard running else { return }
        note("stop asked")
        HistoryBridge.cancel()
    }

    /// Every failure is logged; of the good reads, the first five and then one a minute.
    private func progress(_ data: Data) {
        guard let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let n = line["n"] as? Int ?? 0
        if line["ok"] as? Bool == true {
            progressSeen += 1
            let every = max(1, 60 / max(1, seconds))
            guard progressSeen <= 5 || progressSeen % every == 0 else { return }
            note("read \(n) ok \(line["ms"] as? Int ?? 0) ms, \(line["app"] as? String ?? "?"), \(line["elements"] as? Int ?? 0) elements\(line["changed"] as? Bool == true ? ", changed" : "")")
        } else {
            note("read \(n) FAILED after \(line["ms"] as? Int ?? 0) ms (\(line["code"] as? String ?? "error")): \(line["error"] as? String ?? "")")
        }
    }

    private func finish(_ value: [String: Any], model: AppModel) {
        func number(_ key: String) -> Int { value[key] as? Int ?? 0 }
        let now = UIDevice.current.batteryLevel
        note("run \(value["ended"] as? String ?? "ended") after \(number("ran_s")) s: \(number("reads")) reads, \(number("failures")) failures, \(number("changed")) with changed text, \(number("connections")) connections")
        note(String(format: "longest gap %.1f s, average read %d ms, slowest %d ms", Double(number("longest_gap_ms")) / 1000, number("average_ms"), number("slowest_ms")))
        if batteryAtStart >= 0, now >= 0 {
            note("battery \(Self.percent(batteryAtStart)) to \(Self.percent(now)), used \(Int(((batteryAtStart - now) * 100).rounded())) points, charging \(Self.charging)")
        } else {
            note("battery level not available")
        }
        if let error = value["last_error"] as? String { note("last error: \(error)") }
        note(context(model: model))
        end()
    }

    private func end() {
        keepAlive.stop()
        endTask()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        running = false
        started = nil
    }

    private static func percent(_ level: Float) -> String { level < 0 ? "unknown" : "\(Int((level * 100).rounded()))%" }
    private static var charging: String {
        switch UIDevice.current.batteryState {
        case .charging, .full: "yes"
        case .unplugged: "no"
        default: "unknown"
        }
    }

    private func observe() {
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "Poki entered background"),
            (UIApplication.didBecomeActiveNotification, "Poki became active"),
            (UIApplication.willTerminateNotification, "Poki will terminate"),
        ]
        for (name, text) in events {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.running else { return }
                    self.note(text)
                    if name == UIApplication.didEnterBackgroundNotification { self.beginTask() }
                    if name == UIApplication.didBecomeActiveNotification { self.endTask() }
                }
            })
        }
    }

    private func beginTask() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "poki-history-run") { [weak self] in
            Task { @MainActor in self?.note("background task expired"); self?.endTask() }
        }
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// General › Testing Options › iPhone History.
struct HistoryTestSection: View {
    @ObservedObject var probe = HistoryProbe.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Button("Read Screen Once") { Task { await probe.readOnce(model: model) } }
                .disabled(probe.reading || probe.running)
            Button("Read in 10 Seconds") { Task { await probe.readOnce(model: model, delay: 10) } }
                .disabled(probe.reading || probe.running)
            Stepper(value: $probe.seconds, in: 1...60) {
                LabeledContent("Seconds Between Reads") { Text(verbatim: "\(probe.seconds)").monospacedDigit() }
            }
            .disabled(probe.running)
            Stepper(value: $probe.minutes, in: 1...240) {
                LabeledContent("Minutes to Run") { Text(verbatim: "\(probe.minutes)").monospacedDigit() }
            }
            .disabled(probe.running)
            Toggle("Keep Poki Awake During the Test", isOn: $probe.keepAwake).disabled(probe.running)
            Button("Start Background Run") { probe.startRun(model: model) }
                .disabled(probe.running || probe.reading)
            Button("Stop", role: .destructive) { probe.stopRun() }.disabled(!probe.running)
            if !probe.lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(probe.lines.indices, id: \.self) { i in Text(verbatim: probe.lines[i]).font(.caption2.monospaced()) }
                }
                .textSelection(.enabled)
            }
        } header: {
            Text("iPhone History")
        } footer: {
            Text("Reads the screen as text through the accessibility service, with no automation session. Nothing is stored, and the log holds only counts, timings and app names. After a read, note whether iOS showed a banner, an indicator or a prompt. For the background run, tap Start, use the iPhone as usual, then come back.")
        }
    }
}
