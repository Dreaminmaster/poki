import SwiftUI
import UIKit
import Vision
import ImageIO

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

    /// One line per subscription of a read: what the service sent back, in numbers and names only.
    private static func attempts(_ value: [[String: Any]]) -> [String] {
        value.enumerated().map { index, attempt in
            func number(_ key: String) -> Int { attempt[key] as? Int ?? 0 }
            func counts(_ key: String) -> String {
                let all = attempt[key] as? [String: Any] ?? [:]
                return all.keys.sorted().map { "\($0)x\(all[$0] as? Int ?? 0)" }.joined(separator: " ")
            }
            var line = "try \(index + 1) \(attempt["answered"] as? Bool == true ? "answered" : "no answer") in \(number("took_ms")) of \(number("window_ms")) ms, \(number("messages")) messages, \(number("bytes")) bytes, \(number("archives")) archives, \(number("dumps")) dumps, \(number("roots")) roots, \(number("nodes")) nodes"
            let types = counts("request_types"), entries = counts("dump_entries")
            if !types.isEmpty { line += ", types \(types)" }
            if !entries.isEmpty { line += ", entries \(entries)" }
            if let selectors = attempt["selectors"] as? [String], !selectors.isEmpty { line += ", selectors \(selectors.joined(separator: " "))" }
            if let error = attempt["error"] as? String { line += ", error \(error)" }
            return line
        }
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

    /// One subscription kept open for `seconds` while the owner uses the phone: how the tree fills in.
    func watch(model: AppModel, seconds: Int = 30) async {
        guard !reading, !running, var request = makeRequest("watch", model: model) else { return }
        reading = true
        defer { reading = false }
        request["seconds"] = seconds
        note("watch \(seconds) s: \(context(model: model))", keep: false)
        if keepAwake { try? keepAlive.start() }
        let hold = UIApplication.shared.beginBackgroundTask(withName: "poki-history-watch")
        defer { keepAlive.stop(); if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) } }
        do {
            let data = try await HistoryBridge.call(request)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let attempts = value["attempts"] as? [[String: Any]] ?? []
            for line in Self.attempts(attempts) { note(line, keep: false) }
            for attempt in attempts {
                for dump in attempt["timeline"] as? [[String: Any]] ?? [] {
                    func number(_ key: String) -> Int { dump[key] as? Int ?? 0 }
                    note("dump at \(number("at_ms")) ms, \(number("bytes")) bytes, \(number("roots")) roots, \(number("nodes")) nodes, \(number("listed_children")) children listed, \(number("missing_children")) not described", keep: false)
                }
                for app in attempt["apps"] as? [[String: Any]] ?? [] {
                    let id = app["bundle_id"] as? String ?? "unnamed"
                    let children = (app["children"] as? Int).map { "\($0)" } ?? "none"
                    let visible = (app["visible_children"] as? Int).map { "\($0)" } ?? "none"
                    note("app \(id) pid \(app["pid"] as? Int ?? 0), described \(app["described"] as? Bool == true ? "yes" : "no"), children \(children), visible \(visible)", keep: false)
                }
            }
            if value["tree"] as? Bool == true {
                note("\(Self.apps(value)), \(value["elements"] as? Int ?? 0) elements, \(value["text_lines"] as? Int ?? 0) text lines, \(value["text_characters"] as? Int ?? 0) characters", keep: false)
            } else {
                note("NO TREE at the end of the watch", keep: false)
            }
            note("after: \(context(model: model))", keep: false)
        } catch {
            let failure = error as? HistoryBridge.Failure
            note("watch failed (\(failure?.code ?? "error")): \(error.localizedDescription)", keep: false)
            if let fix = failure?.fix { note(fix, keep: false) }
        }
    }

    /// How the element walk asks the phone not to draw its highlight (1 to 3).
    @Published var walkVariant = 1

    /// What the phone says about the app in front without its contents, after `delay` seconds so the
    /// owner can put another app in front: two overlapping subscriptions, the processes behind the
    /// apps they name, and one screenshot read as text on this phone. The picture is deleted at once.
    func front(model: AppModel, delay: Int = 10, endSleepScreen: Bool = false, walk: Bool = false) async {
        guard !reading, !running, var request = makeRequest("front", model: model) else { return }
        reading = true
        defer { reading = false }
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("history-front-\(UUID().uuidString).png")
        request["screenshot_path"] = picture.path
        if endSleepScreen { request["end_sleep_screen"] = true }
        if walk { request["walk"] = true; request["walk_variant"] = walkVariant }
        note("front app check in \(delay) s, Poki is pid \(ProcessInfo.processInfo.processIdentifier): \(context(model: model))", keep: false)
        if keepAwake { try? keepAlive.start() }
        let hold = UIApplication.shared.beginBackgroundTask(withName: "poki-history-front")
        defer {
            keepAlive.stop()
            if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
            try? FileManager.default.removeItem(at: picture)
        }
        try? await Task.sleep(for: .seconds(delay))
        do {
            let data = try await HistoryBridge.call(request)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            func number(_ key: String) -> String { (value[key] as? Int).map { "\($0)" } ?? "none" }
            if let count = value["sleep_screen_ended"] as? Int { note("ended \(count) Sleep screen processes before reading", keep: false) }
            if let error = value["sleep_screen_error"] as? String { note("the Sleep screen process could not be ended: \(error)", keep: false) }
            let attempts = value["attempts"] as? [[String: Any]] ?? []
            for line in Self.attempts(attempts) { note(line, keep: false) }
            for (index, attempt) in attempts.enumerated() {
                for app in attempt["apps"] as? [[String: Any]] ?? [] {
                    let id = app["bundle_id"] as? String ?? "unnamed"
                    let children = (app["children"] as? Int).map { "\($0)" } ?? "none"
                    note("subscription \(index + 1) app \(id) pid \(app["pid"] as? Int ?? 0), children \(children)", keep: false)
                }
            }
            if value["tree"] as? Bool == true {
                note("tree \(Self.apps(value)), \(number("elements")) elements, \(number("text_lines")) text lines", keep: false)
            } else {
                note("no tree from either subscription", keep: false)
            }
            if let walked = value["walk"] as? [String: Any] {
                let selectors = (walked["selectors"] as? [String: Int] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: " ")
                let elements = walked["elements"] as? [[String: Any]] ?? []
                note("element walk: service \(walked["listed"] as? Bool == true ? "listed" : "not listed"), \(walked["messages"] as? Int ?? 0) messages, \(elements.count) elements, \(selectors.isEmpty ? "no selectors" : selectors)", keep: false)
                note("element walk variant \(walkVariant)", keep: false)
                note("element walk: \(walked["silent"] as? Int ?? 0) moves with no answer, other events say \((walked["other"] as? [String] ?? []).joined(separator: " | "))", keep: false)
                if let error = walked["error"] as? String { note("element walk failed at \(walked["stage"] as? String ?? "start"): \(error)", keep: false) }
                for (index, element) in elements.prefix(12).enumerated() {
                    note("element \(index + 1): \(element["strings"] as? Int ?? 0) strings, \(element["characters"] as? Int ?? 0) characters, starts \(element["starts"] as? String ?? "none")", keep: false)
                }
            }
            if let error = value["instruments_error"] as? String { note("instruments failed: \(error)", keep: false) }
            if let error = value["processes_error"] as? String { note("process list failed: \(error)", keep: false) }
            for process in value["processes"] as? [[String: Any]] ?? [] {
                let pid = process["pid"] as? Int ?? 0
                if process["running"] as? Bool == true {
                    note("pid \(pid) is \(process["name"] as? String ?? "unnamed"), app name \(process["app_name"] as? String ?? "none"), bundle \(process["bundle_id"] as? String ?? "not found"), application \(process["is_application"] as? Bool == true ? "yes" : "no")", keep: false)
                } else {
                    note("pid \(pid) is not in the process list", keep: false)
                }
            }
            if value["processes"] != nil {
                note("instruments connect \(number("instruments_connect_ms")) ms, \(number("running_applications")) apps running, \(number("installed_applications")) installed", keep: false)
                if let keys = value["application_keys"] as? [String] { note("app keys \(keys.joined(separator: " "))", keep: false) }
            }
            if let error = value["screenshot_error"] as? String {
                note("screenshot failed: \(error)", keep: false)
            } else if value["screenshot_ms"] != nil {
                note("screenshot \(number("screenshot_ms")) ms, \(number("screenshot_bytes")) bytes", keep: false)
                let asked = Date()
                let read = await Task.detached(priority: .userInitiated) { HistoryProbe.readText(at: picture) }.value
                let took = String(format: "%.2f", Date().timeIntervalSince(asked))
                if let read {
                    note("text from the picture in \(took) s: \(read.lines) lines, \(read.characters) characters, \(read.width) x \(read.height) pixels", keep: false)
                } else {
                    note("the picture could not be read as text (\(took) s)", keep: false)
                }
            }
            note("after: \(context(model: model)). Did iOS show a banner, an indicator or a prompt?", keep: false)
        } catch {
            let failure = error as? HistoryBridge.Failure
            note("front app check failed (\(failure?.code ?? "error")): \(error.localizedDescription)", keep: false)
            if let fix = failure?.fix { note(fix, keep: false) }
        }
    }

    /// Counts only: the words themselves are not kept or logged.
    nonisolated private static func readText(at url: URL) -> (lines: Int, characters: Int, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.filter { !$0.isEmpty }
        return (lines.count, lines.reduce(0) { $0 + $1.count }, image.width, image.height)
    }

    private func answerOnce(_ request: [String: Any], model: AppModel) async {
        do {
            let data = try await HistoryBridge.call(request)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            func ms(_ key: String) -> String { (value[key] as? Int).map { String(format: "%.2f s", Double($0) / 1000) } ?? "none" }
            let attempts = Self.attempts(value["attempts"] as? [[String: Any]] ?? [])
            guard value["tree"] as? Bool == true else {
                note("NO TREE: connect \(ms("connect_ms")), waited \(ms("read_ms"))", keep: false)
                for line in attempts { note(line, keep: false) }
                note("services: \((value["services"] as? [String] ?? []).joined(separator: ", "))", keep: false)
                note("after: \(context(model: model)). Did iOS show a banner, an indicator or a prompt?", keep: false)
                return
            }
            for line in attempts { note(line, keep: false) }
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
            Button("Watch Screen for 30 Seconds") { Task { await probe.watch(model: model) } }
                .disabled(probe.reading || probe.running)
            Button("Check Front App in 10 Seconds") { Task { await probe.front(model: model) } }
                .disabled(probe.reading || probe.running)
            Button("End Sleep Screen and Check in 10 Seconds") { Task { await probe.front(model: model, endSleepScreen: true) } }
                .disabled(probe.reading || probe.running)
            Stepper(value: $probe.walkVariant, in: 1...3) {
                LabeledContent("Walk Variant") { Text(verbatim: "\(probe.walkVariant)").monospacedDigit() }
            }
            .disabled(probe.reading || probe.running)
            Button("Walk Elements in 10 Seconds") { Task { await probe.front(model: model, walk: true) } }
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
