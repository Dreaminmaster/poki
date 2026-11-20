import Foundation
import PokiCore
import SwiftUI
import UIKit
import notify

/// A process-local lease for screen text already fetched by asynchronous agent queries.
/// Revoking a lease does not try to undo an answer already delivered to the caller.
final class HistoryQueryPermissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var deletions = 0
    private var enabled: Bool
    private var deadline: ContinuousClock.Instant?
    private let now: @Sendable () -> ContinuousClock.Instant
    // Provisional policy, to be agreed with the maintainer. Never extended by a query.
    private let duration: Duration

    init(enabled: Bool = UserDefaults.standard.bool(forKey: "history.enabled"),
         duration: Duration = .seconds(300),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.enabled = enabled
        self.duration = duration
        self.now = now
    }

    /// Called under lock: use a continuous clock so sleep and wall-clock adjustments cannot extend access.
    private func expireIfNeeded() {
        if let deadline, now() >= deadline {
            self.deadline = nil
            value &+= 1
        }
    }

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        expireIfNeeded()
        return value
    }

    /// Read the complete grant under the same lock as its revision.
    var grant: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        expireIfNeeded()
        return enabled && deadline != nil && deletions == 0 ? value : nil
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled { deadline = nil }
        value &+= 1
        lock.unlock()
    }

    func setUnlocked(_ unlocked: Bool) {
        lock.lock()
        deadline = unlocked && enabled ? now().advanced(by: duration) : nil
        value &+= 1
        lock.unlock()
    }

    func revoke() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func beginDeletion() {
        lock.lock()
        value &+= 1
        deletions += 1
        lock.unlock()
    }

    func endDeletion() {
        lock.lock()
        deletions = max(0, deletions - 1)
        value &+= 1
        lock.unlock()
    }
}

/// iPhone History's capture and its privacy controls (issue 356), as an experiment.
///
/// Nothing is read until the owner asks in Testing Options: one read 10 seconds later, or a short
/// run of a few minutes. The launcher then reads the app in front as text through the accessibility
/// service over the loopback, with no automation session. A run ends when its time is up, when the
/// iPhone locks or the screen goes dark, when an agent's task opens a session, or when iOS ends
/// Poki's background time. No audio plays to keep Poki awake. A read that passes the app list goes
/// to `HistoryStore`. Nothing leaves the phone.
@MainActor
final class HistoryCapture: ObservableObject {
    static let shared = HistoryCapture()

    /// What the short run is doing, or why the last one ended or did not start, as Testing Options
    /// and the observing record say it.
    enum Status: String {
        case off, waiting, reading, finished, stopped, locked, task, noConnection, notPaired
    }

    enum ListMode: String, CaseIterable, Identifiable {
        case exclude, include
        var id: String { rawValue }
    }

    // MARK: Settings (kept in UserDefaults)

    nonisolated static let enabledKey = "history.enabled"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    nonisolated private static let queryLease = HistoryQueryPermissionLease()
    nonisolated static var accessRevision: UInt64 { queryLease.revision }
    nonisolated static var agentQueryRevision: UInt64? {
        guard isEnabled else { return nil }
        return queryLease.grant
    }
    nonisolated static var agentQueryAllowed: Bool { agentQueryRevision != nil }
    nonisolated static var agentQueryUnavailableMessage: String {
        guard isEnabled else { return PokiCore.screenHistoryOffMessage }
        return "Screen History agent access is locked or expired. Choose Allow Agent Access in Poki to authenticate and grant access."
    }

    /// HistoryLock owns authentication; true starts a fresh, bounded grant. False revokes it.
    nonisolated static func setAgentHistoryUnlocked(_ unlocked: Bool) {
        queryLease.setUnlocked(unlocked)
    }

    nonisolated static func validateAgentAnswer(_ answer: PokiCore.ToolAnswer, revision: UInt64?) -> PokiCore.ToolAnswer {
        guard !answer.isError else { return answer }
        guard let revision, agentQueryRevision == revision else {
            return PokiCore.ToolAnswer(text: PokiCore.screenHistoryRevokedMessage, jpeg: nil, isError: true)
        }
        return answer
    }

    @Published var enabled: Bool {
        didSet {
            Self.queryLease.setEnabled(enabled)
            save(enabled, Self.enabledKey)
            if !enabled { stop() }
        }
    }
    @Published var listMode: ListMode {
        didSet { Self.queryLease.revoke(); save(listMode.rawValue, "history.listMode") }
    }
    @Published var excluded: [String] {
        didSet { Self.queryLease.revoke(); save(excluded, "history.excluded") }
    }
    @Published var included: [String] {
        didSet { Self.queryLease.revoke(); save(included, "history.included") }
    }
    @Published var retentionDays: Int { didSet { save(retentionDays, "history.retentionDays"); prune() } }
    /// How long the hour, day and week summaries outlive the tape, in days. 0 is as long as the tape.
    @Published var summaryDays: Int { didSet { save(summaryDays, "history.summaryDays"); prune() } }
    /// The tape's storage limit in megabytes.
    @Published var storageMegabytes: Int { didSet { save(storageMegabytes, "history.storageMegabytes"); prune() } }

    private func prune() {
        guard !loading else { return }
        HistoryStore.shared.prune(days: retentionDays, summaryDays: summaryDays, megabytes: storageMegabytes)
    }

    // MARK: State

    @Published private(set) var status: Status = .off
    /// When the run in progress ends.
    @Published private(set) var ends: Date?
    /// Bumped when a read is kept or history is deleted, so an open panel reloads.
    @Published private(set) var changes = 0
    @Published private(set) var lastKept: Date?

    var isRunning: Bool { status == .waiting || status == .reading }

    /// The short runs Testing Options offers, in minutes.
    static let runMinutes = [3, 5]
    /// The wait before a single read, time to leave Poki and put another app in front.
    static let waitSeconds = 10
    /// Seconds between two reads of a run.
    static let interval = 5

    /// The run in progress. Ending a run moves it on, so a late answer from an older one is ignored.
    private var run = 0
    private var once = false
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var lockToken: Int32 = NOTIFY_TOKEN_INVALID
    private var screenToken: Int32 = NOTIFY_TOKEN_INVALID
    private var loading = true

    /// Passwords, banking, payments and messages: left out on a fresh install, and offered again on
    /// the Permissions page when removed.
    static let suggested = [
        "com.apple.Passwords", "com.agilebits.onepassword-ios", "com.apple.Passbook", "com.alipay.iphoneclient",
        "com.paypal.PPClient", "com.apple.MobileSMS", "com.tencent.xin", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph",
    ]

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.enabledKey)
        listMode = ListMode(rawValue: defaults.string(forKey: "history.listMode") ?? "") ?? .exclude
        // Poki's own screens and the suggested apps are left out from the start.
        excluded = defaults.stringArray(forKey: "history.excluded") ?? [Bundle.main.bundleIdentifier ?? "nz.zheha.poki"] + Self.suggested
        included = defaults.stringArray(forKey: "history.included") ?? []
        retentionDays = max(3, defaults.object(forKey: "history.retentionDays") as? Int ?? 14)
        summaryDays = defaults.object(forKey: "history.summaryDays") as? Int ?? 90
        storageMegabytes = max(50, defaults.object(forKey: "history.storageMegabytes") as? Int ?? 200)
        loading = false
    }

    /// Screens that sit over the app in front for a moment and say nothing about what the owner did,
    /// or that show a passcode or an Apple Account sign-in. They are never kept, whatever the lists say.
    static let overlays = [
        "com.apple.ScreenshotServicesService", "com.apple.InCallService", "com.apple.CoreAuthUI",
        "com.apple.SharingViewService", "com.apple.PassbookUIService", "com.apple.AuthKitUIService",
    ]

    /// Poki's own screens are never kept, whatever the lists say.
    nonisolated static func isPoki(_ app: String) -> Bool {
        app.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "nz.zheha.poki") == .orderedSame || app.caseInsensitiveCompare("Poki") == .orderedSame
    }

    private func save(_ value: Any?, _ key: String) {
        guard !loading else { return }
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: The controls

    private func state(_ token: Int32) -> Bool {
        var value: UInt64 = 0
        return token != NOTIFY_TOKEN_INVALID && notify_get_state(token, &value) == NOTIFY_STATUS_OK && value != 0
    }

    private var lockedOrDark: Bool { state(lockToken) || state(screenToken) }

    /// Whether reads of this app are kept, by the list the owner chose.
    func keeps(_ app: String) -> Bool {
        guard app.range(of: #"\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil else { return false }
        if Self.isPoki(app) { return false }
        return switch listMode {
        case .exclude: !excluded.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        case .include: included.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        }
    }

    func exclude(_ app: String) {
        included.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        guard !excluded.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) else { return }
        excluded.append(app)
    }

    /// Why a read cannot happen now, or nil when it can.
    private func refusal(_ model: AppModel) -> Status? {
        if lockedOrDark { return .locked }
        // Reading stays out of the way of an agent's task.
        if model.hasOpenInProcessSession { return .task }
        #if !targetEnvironment(simulator)
        if model.pairingPath == nil { return .notPaired }
        if !model.loopback.isWorking { return .noConnection }
        #endif
        return nil
    }

    private func set(_ next: Status) {
        guard next != status else { return }
        status = next
        HistoryStore.shared.note(next.rawValue)
    }

    // MARK: Short runs

    /// Reads once after `waitSeconds`, or every `interval` seconds for `minutes`.
    func start(minutes: Int? = nil, model: AppModel) {
        guard !isRunning else { return }
        if !enabled { enabled = true }
        watchLock()
        if let refused = refusal(model) { set(refused); return }
        HistoryLock.shared.readStarting()
        run += 1
        let me = run
        once = minutes == nil
        prune()
        background = UIApplication.shared.beginBackgroundTask(withName: "poki-screen-history") { [weak self] in
            Task { @MainActor in
                AppLog.shared.add("history", "iOS ended the background time")
                self?.end(me, .stopped)
            }
        }
        let wait = once ? Self.waitSeconds : 0
        set(once ? .waiting : .reading)
        ends = Date().addingTimeInterval(Double(wait + (minutes ?? 0) * 60))
        let duration = max(10, (minutes ?? 0) * 60)
        #if !targetEnvironment(simulator)
        let screen = UIScreen.main.bounds
        let points = [0.5, 0.3, 0.7, 0.15].map { [Double(screen.midX), Double(screen.height) * $0] }
        #endif
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard self.run == me else { return }
            if let refused = self.refusal(model) { self.end(me, refused); return }
            self.set(.reading)
            #if targetEnvironment(simulator)
            await self.runOnSimulator(me: me, duration: duration, model: model)
            #else
            // A single read runs for the launcher's shortest time and ends at the first kept read.
            let request: [String: Any] = [
                "op": "run", "device_address": "10.7.0.1", "pairing_file": model.pairingPath ?? "", "host_name": "Poki",
                "direct_points": points, "interval_ms": Self.interval * 1000, "duration_s": duration,
                "include_text": true, "include_tree": true,
            ]
            do {
                _ = try await HistoryBridge.call(request) { [weak self] line in
                    Task { @MainActor [weak self] in self?.took(line, run: me, model: model) }
                }
            } catch {
                AppLog.shared.add("history", "capture stopped: \(error.localizedDescription)")
            }
            #endif
            self.end(me, .finished)
        }
    }

    func stop() {
        end(run, .stopped)
    }

    /// Ends run `me`, if it is still the one in progress.
    private func end(_ me: Int, _ why: Status) {
        guard me == run, isRunning else { return }
        run += 1
        HistoryBridge.cancel()
        set(why)
        ends = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        // The file is closed when the phone locks, so iOS's file protection holds.
        if why == .locked { HistoryStore.shared.close() }
    }

    /// Monitor device lock independently of a recording run. The observer lives for the
    /// application lifetime; a locked phone must revoke reads even when capture is idle.
    func watchLock() {
        let changed: @Sendable (Int32) -> Void = { [weak self] _ in
            // notify_register_dispatch delivers on DispatchQueue.main.
            MainActor.assumeIsolated {
                self?.deviceLockChanged()
            }
        }
        if lockToken == NOTIFY_TOKEN_INVALID {
            notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, DispatchQueue.main, changed)
        }
        if screenToken == NOTIFY_TOKEN_INVALID {
            notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &screenToken, DispatchQueue.main, changed)
        }
        deviceLockChanged()
    }

    private func deviceLockChanged() {
        guard lockedOrDark else { return }
        HistoryLock.shared.lock()
        HistoryStore.shared.close()
        end(run, .locked)
    }

    /// One read from the launcher. Only a screen whose text changed carries text.
    private func took(_ data: Data, run me: Int, model: AppModel) {
        guard me == run, status == .reading, !lockedOrDark,
              let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if model.hasOpenInProcessSession { end(me, .task); return }
        if keep(line), once { end(me, .finished) }
    }

    /// Keeps a read of the launcher's when the app lists allow it. Returns whether it was kept.
    @discardableResult
    func keep(_ line: [String: Any]) -> Bool {
        guard line["ok"] as? Bool == true, let read = line["text"] as? [String], !read.isEmpty else { return false }
        let app = line["app"] as? String ?? ""
        // The Home Screen is left out with its notification banners: a banner names the sending app
        // only by its display name, so the app lists could not leave it out. A left-out app leaves
        // no trace, not even a line in the observing record.
        if app.caseInsensitiveCompare("com.apple.springboard") == .orderedSame { return false }
        if Self.overlays.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { return false }
        guard keeps(app) else { return false }
        let tree = (line["tree"] as? [Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let now = Date()
        HistoryStore.shared.add(at: now, app: app, title: line["title"] as? String ?? "", text: read.joined(separator: "\n"), tree: tree)
        lastKept = now
        changes += 1
        return true
    }

    // MARK: Deleting

    func clear(last seconds: TimeInterval) async {
        Self.queryLease.beginDeletion()
        defer { Self.queryLease.endDeletion() }
        BacktapeNotes.shared.reset()
        await HistoryStore.shared.delete(from: Date().addingTimeInterval(-seconds), to: Date().addingTimeInterval(60))
        HistoryStore.shared.note("cleared", "\(Int(seconds))")
        changes += 1
    }

    func clearEverything() async {
        Self.queryLease.beginDeletion()
        defer { Self.queryLease.endDeletion() }
        BacktapeNotes.shared.reset()
        await HistoryStore.shared.deleteEverything()
        changes += 1
    }

    func delete(from start: Date, to end: Date) async {
        Self.queryLease.beginDeletion()
        defer { Self.queryLease.endDeletion() }
        BacktapeNotes.shared.reset()
        await HistoryStore.shared.delete(from: start, to: end)
        changes += 1
    }

    #if targetEnvironment(simulator)
    private static let simulatorQueue = DispatchQueue(label: "nz.zheha.poki.history-simulator", qos: .utility)

    private func runOnSimulator(me: Int, duration: Int, model: AppModel) async {
        let deadline = Date().addingTimeInterval(Double(duration))
        var lastApp = ""
        var lastLines: [String] = []
        var openedSession = false
        defer {
            if openedSession {
                Self.simulatorQueue.async { _ = PKInProcess.shared().close() }
            }
        }
        while self.run == me, self.status == .reading, Date() < deadline {
            if model.hasOpenInProcessSession { self.end(me, .task); return }
            let snapshot: (app: String, title: String, lines: [String])? = await withCheckedContinuation { done in
                Self.simulatorQueue.async {
                    let probe = PKInProcess.shared()
                    let ready = (probe.prepare()["ok"] as? Bool) == true
                    guard ready else { done.resume(returning: nil); return }
                    let front = probe.frontApp()
                    let app = (front["bundleId"] as? String) ?? ""
                    guard !app.isEmpty, !Self.isPoki(app) else { done.resume(returning: nil); return }
                    guard let xml = probe.sourceXML(nil, maxDepth: 40, maxChildren: 400, code: nil) else {
                        done.resume(returning: nil)
                        return
                    }
                    let parsed = SimulatorScreenXML.parse(xml)
                    done.resume(returning: (app, parsed.title, parsed.lines))
                }
            }
            openedSession = true
            guard self.run == me, self.status == .reading else { return }
            if let snapshot, !snapshot.lines.isEmpty, (snapshot.app != lastApp || snapshot.lines != lastLines) {
                lastApp = snapshot.app
                lastLines = snapshot.lines
                if let data = try? JSONSerialization.data(withJSONObject: [
                    "ok": true,
                    "app": snapshot.app,
                    "title": snapshot.title,
                    "text": snapshot.lines,
                    "changed": true,
                ]) {
                    self.took(data, run: me, model: model)
                }
            }
            guard self.run == me, self.status == .reading else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
        }
    }
    #endif
}

#if targetEnvironment(simulator)
private final class SimulatorScreenXML: NSObject, XMLParserDelegate {
    private var skipDepth = 0
    private var title = ""
    private var lines: [String] = []
    private static let secretTerms = [
        "password", "passcode", "verification code", "one-time code",
        "密码", "密碼", "验证码", "驗證碼",
    ]

    static func parse(_ xml: String) -> (title: String, lines: [String]) {
        let reader = SimulatorScreenXML()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        _ = parser.parse()
        return (reader.title, reader.lines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        let type = attributes["type"] ?? elementName
        if type == "XCUIElementTypeKeyboard" || type == "XCUIElementTypeKey" || type == "XCUIElementTypeSecureTextField" {
            skipDepth = 1
            return
        }
        if type == "XCUIElementTypeApplication" { return }
        let label = (attributes["label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (attributes["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (attributes["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = "\(name) \(label)".lowercased()
        let isSecret = !value.isEmpty && Self.secretTerms.contains { descriptor.contains($0) }
        if type == "XCUIElementTypeNavigationBar", title.isEmpty, !label.isEmpty {
            title = label
        }
        for piece in isSecret ? [label] : [label, value] where !piece.isEmpty && lines.last != piece {
            lines.append(piece)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1 }
    }
}
#endif
