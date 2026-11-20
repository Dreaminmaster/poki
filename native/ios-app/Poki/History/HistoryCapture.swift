import Foundation
import Observation
import PokiCore
import SwiftUI
import UIKit
import notify
import UserNotifications

/// A process-local lease for screen text already fetched by asynchronous agent queries.
/// Revoking a lease does not try to undo an answer already delivered to the caller.
private final class HistoryQueryPermissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var deletions = 0
    private var enabled = HistoryCapture.isEnabled
    private var unlocked = false

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Read the complete grant under the same lock as its revision.
    var grant: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return enabled && unlocked && deletions == 0 ? value : nil
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        value &+= 1
        lock.unlock()
    }

    func setUnlocked(_ unlocked: Bool) {
        lock.lock()
        self.unlocked = unlocked
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

/// Reads the front app through the accessibility service over the local connection.
/// Only reads allowed by the owner's app list are stored.
@MainActor
final class HistoryCapture: ObservableObject {
    static let shared = HistoryCapture()

    /// Includes the values written by earlier versions so their observing records still display.
    enum Status: String {
        case off, waiting, reading, finished, stopped, locked, task, noConnection, notPaired, paused
    }

    enum ListMode: String, CaseIterable, Identifiable {
        case exclude, include
        var id: String { rawValue }
    }

    // MARK: Settings (kept in UserDefaults)

    nonisolated static let enabledKey = "history.recordingEnabled"
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
        return "Screen History is locked or temporarily unavailable. Unlock it in Poki before querying."
    }

    /// HistoryLock owns authentication; publish its decision to the synchronous agent gate.
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
            guard oldValue != enabled else { return }
            Self.queryLease.setEnabled(enabled)
            save(enabled, Self.enabledKey)
            if enabled {
                reconcile()
            } else {
                pause(.stopped)
            }
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
    /// Bumped when a read is kept or history is deleted, so an open panel reloads.
    @Published private(set) var changes = 0
    @Published private(set) var lastKept: Date?

    var isRunning: Bool { captureTask?.isCancelled == false }

    private static let interval = 5

    private weak var model: AppModel?
    private var captureTask: Task<Void, Never>?
    private var needsActivation = true
    /// A callback from an earlier native run must never supply text to a new one.
    private var run = 0
    /// The app last read that was an app, for a web page whose own process names none.
    private var host: String?
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
        if defaults.object(forKey: Self.enabledKey) == nil,
           let legacyEnabled = defaults.object(forKey: "history.enabled") as? Bool {
            defaults.set(legacyEnabled, forKey: Self.enabledKey)
            // HistoryLock can initialize the query lease before capture starts.
            Self.queryLease.setEnabled(legacyEnabled)
        }
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
    nonisolated static let overlays = [
        "com.apple.ScreenshotServicesService", "com.apple.InCallService", "com.apple.CoreAuthUI",
        "com.apple.SharingViewService", "com.apple.PassbookUIService", "com.apple.AuthKitUIService",
    ]

    /// Not an app the owner was using: the Home Screen's widgets and Apple's sheets that belong to
    /// no app. Never kept, never listed.
    nonisolated static func isNoise(_ app: String) -> Bool {
        let low = app.lowercased()
        if low.isEmpty || low.hasPrefix("com.apple.chrono") || low.contains("widgetrenderer") { return true }
        if overlays.contains(where: { $0.lowercased() == low }) { return true }
        return low.hasPrefix("com.apple.") && (low.hasSuffix("uiservice") || low.hasSuffix("viewservice"))
    }

    /// A WebKit process that draws a page for some app: one per tab, with no app's name.
    nonisolated static func isWeb(_ app: String) -> Bool { app.lowercased().hasPrefix("com.apple.webkit") }

    nonisolated static let safari = "com.apple.mobilesafari"

    /// Removes what was kept before system processes were left out, and counts the reads of web
    /// pages' own processes as Safari's.
    func tidy() async {
        let apps = await HistoryStore.shared.everyApp()
        let web = apps.filter(Self.isWeb)
        let processes = apps.filter { !Self.isWeb($0) && HistoryAppNames.isProcess($0) }
        guard !web.isEmpty || !processes.isEmpty else { return }
        HistoryStore.shared.tidy(processes: processes, web: web, browser: Self.safari)
        BacktapeNotes.shared.reset()
    }

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

    private func unavailable(_ model: AppModel) -> Status? {
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

    func monitor(model: AppModel) {
        self.model = model
        observeAvailability(model)
    }

    private func observeAvailability(_ model: AppModel) {
        withObservationTracking {
            _ = unavailable(model)
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.observeAvailability(model)
                self.reconcile()
            }
        }
    }

    func appDidBecomeActive() {
        needsActivation = false
        reconcile()
    }

    private func reconcile() {
        guard enabled, !needsActivation, let model else { return }
        if lockedOrDark { pause(.locked); return }
        if let reason = unavailable(model) { pause(reason); return }
        guard captureTask == nil else { return }
        run += 1
        let me = run
        background = UIApplication.shared.beginBackgroundTask(withName: "poki-screen-history") { [weak self] in
            guard let self, self.run == me else { return }
            AppLog.shared.add("history", "iOS ended the background time")
            self.waitForActivation()
        }
        guard background != .invalid else { waitForActivation(); return }
        HistoryLock.shared.readStarting()
        prune()
        set(.waiting)
        captureTask = Task {
            if !Task.isCancelled { await collect(run: me, model: model) }
            captureTask = nil
            if Task.isCancelled {
                reconcile()
            } else {
                waitForActivation()
            }
        }
    }

    private func collect(run me: Int, model: AppModel) async {
        #if targetEnvironment(simulator)
        await runOnSimulator(model: model)
        #else
        guard let pairing = model.pairingPath else { return }
        let screen = UIScreen.main.bounds
        let points = [0.5, 0.3, 0.7, 0.15].map { [Double(screen.midX), Double(screen.height) * $0] }
        let request: [String: Any] = [
            "op": "run", "device_address": "10.7.0.1", "pairing_file": pairing, "host_name": "Poki",
            "direct_points": points, "interval_ms": Self.interval * 1000, "continuous": true,
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
    }

    private func waitForActivation() {
        needsActivation = true
        pause(.paused)
    }

    private func pause(_ reason: Status) {
        if let captureTask, !captureTask.isCancelled {
            captureTask.cancel()
            HistoryBridge.cancel()
        }
        set(reason)
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
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
        guard lockedOrDark else { reconcile(); return }
        HistoryLock.shared.lock()
        if enabled { pause(.locked) }
        HistoryStore.shared.close()
    }

    /// One read from the launcher. Only a screen whose text changed carries text.
    private func took(_ data: Data, run me: Int, model: AppModel) {
        guard me == run, isRunning, !lockedOrDark,
              let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let reason = unavailable(model) { pause(reason); return }
        guard line["ok"] as? Bool == true else { set(.paused); return }
        set(.reading)
        keep(line)
    }

    /// Keeps a read of the launcher's when the app lists allow it. Returns whether it was kept.
    @discardableResult
    func keep(_ line: [String: Any]) -> Bool {
        guard line["ok"] as? Bool == true else { return false }
        var app = line["app"] as? String ?? ""
        let home = app.caseInsensitiveCompare("com.apple.springboard") == .orderedSame
        if app.isEmpty || Self.isWeb(app) {
            // A web page's own process. It counts as the app that shows it: the one the launcher
            // found around the page, else the app read just before, else Safari.
            app = (line["host"] as? String).flatMap { $0.isEmpty || Self.isWeb($0) ? nil : $0 } ?? host ?? (app.isEmpty ? "" : Self.safari)
        } else if home {
            host = nil
        } else if !HistoryAppNames.isProcess(app) {
            host = app
        }
        guard let read = line["text"] as? [String], !read.isEmpty else { return false }
        // The Home Screen is left out with its notification banners: a banner names the sending app
        // only by its display name, so the app lists could not leave it out. A left-out app leaves
        // no trace, not even a line in the observing record.
        if app.caseInsensitiveCompare("com.apple.springboard") == .orderedSame { return false }
        if HistoryAppNames.isProcess(app) { return false }
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

    private func runOnSimulator(model: AppModel) async {
        var lastApp = ""
        var lastLines: [String] = []
        defer {
            Self.simulatorQueue.async { _ = PKInProcess.shared().close() }
        }
        while !Task.isCancelled {
            if let reason = unavailable(model) { pause(reason); return }
            let snapshot: (app: String, title: String, lines: [String])? = await withCheckedContinuation { done in
                Self.simulatorQueue.async {
                    let probe = PKInProcess.shared()
                    let ready = (probe.prepare()["ok"] as? Bool) == true
                    guard ready else { done.resume(returning: nil); return }
                    let front = probe.frontApp()
                    let app = (front["bundleId"] as? String) ?? ""
                    guard !app.isEmpty else { done.resume(returning: nil); return }
                    if Self.isPoki(app) { done.resume(returning: (app, "", [])); return }
                    guard let xml = probe.sourceXML(nil, maxDepth: 40, maxChildren: 400, code: nil) else {
                        done.resume(returning: nil)
                        return
                    }
                    let parsed = SimulatorScreenXML.parse(xml)
                    done.resume(returning: (app, parsed.title, parsed.lines))
                }
            }
            guard !Task.isCancelled, !lockedOrDark else { return }
            if let reason = unavailable(model) { pause(reason); return }
            set(snapshot == nil ? .paused : .reading)
            if let snapshot, snapshot.app != lastApp || snapshot.lines != lastLines {
                lastApp = snapshot.app
                lastLines = snapshot.lines
                keep([
                    "ok": true,
                    "app": snapshot.app,
                    "title": snapshot.title,
                    "text": snapshot.lines,
                ])
            }
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
