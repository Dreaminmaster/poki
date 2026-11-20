import Foundation
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
///
/// While the switch is on, `HistoryCollector` keeps one run going that has no end of its own
/// (`start(always:)`), from `monitor(model:)` and `appDidBecomeActive()` on. The launcher reads
/// with no automation session. The run is held, with its tunnel kept, while the iPhone is locked
/// or an agent's task has the screen, and waits and tries again while the local connection is
/// down. Nothing leaves the phone.
@MainActor
final class HistoryCapture: ObservableObject {
    static let shared = HistoryCapture()

    /// What the run is doing, or why the last one ended or did not start, as the settings page and
    /// the observing record say it. Includes the values written by earlier versions so their
    /// observing records still display.
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
            // Turned on, the collector starts the run (it watches this switch).
            if !enabled { stop() }
        }
    }
    @Published var listMode: ListMode {
        didSet { Self.queryLease.revoke(); save(listMode.rawValue, "history.listMode"); tellLists() }
    }
    @Published var excluded: [String] {
        didSet { Self.queryLease.revoke(); save(excluded, "history.excluded"); tellLists() }
    }
    @Published var included: [String] {
        didSet { Self.queryLease.revoke(); save(included, "history.included"); tellLists() }
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
    /// When the launcher last made a read, kept or not: the sign that the connection is open.
    private(set) var lastReadAt: Date?
    /// When the launcher last showed its tunnel open: a read, or a held run's line.
    private(set) var lastTunnelAt: Date?
    /// The launcher's last reason for a tunnel or a read that failed.
    private(set) var lastFailure: String?
    /// When the launcher last opened a tunnel, as its own line says: a new tunnel, not a held one.
    private(set) var lastOpenedAt: Date?

    /// What the launcher says of its tunnel when asked.
    enum Tunnel: Equatable {
        /// A new stream inside it was taken by the iPhone.
        case alive(ms: Int)
        /// It did not answer. `givenUp`: the launcher dropped it and tries a new one.
        case dead(String, givenUp: Bool)
        /// The run has no tunnel.
        case missing
    }

    /// The launcher's answers to checks of the tunnel, by the number each carries.
    private var answers: [UInt64: Tunnel] = [:]

    /// Asks the run to look at its tunnel now; `answer(to:)` has what it said once it did. nil when
    /// no run is going. With `replace` a tunnel that does not answer is given up and a new one
    /// tried at once.
    func askTunnel(replace: Bool) -> UInt64? {
        guard isRunning else { return nil }
        if answers.count > 16 { answers = [:] }
        return HistoryBridge.check(replace: replace)
    }

    /// What the run said to this check, or to a later one: both say how the tunnel is now.
    func answer(to check: UInt64) -> Tunnel? {
        answers.filter { $0.key >= check }.min { $0.key < $1.key }?.value
    }

    /// Asks the run whether its tunnel still answers, and waits for what it says. nil when no run
    /// is going or it did not say in time (a read under way is finished first).
    func tunnel(replace: Bool, within seconds: TimeInterval) async -> Tunnel? {
        guard let check = askTunnel(replace: replace) else { return nil }
        let asked = Date()
        while Date().timeIntervalSince(asked) < seconds {
            if let said = answer(to: check) { return said }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return answer(to: check)
    }

    // MARK: The log

    /// The line said last, and how often the same came again: a try that fails five times a second
    /// is one line and a count, not a page of lines (the owner, 2026-11-20).
    private var said: (text: String, more: Int, since: Date)?
    /// A line that goes on repeating is counted out this often.
    private static let sayAgainAfter: TimeInterval = 300

    private func say(_ text: String) {
        if let last = said, last.text == text, Date().timeIntervalSince(last.since) < Self.sayAgainAfter {
            said = (last.text, last.more + 1, last.since)
            return
        }
        sayCount()
        said = (text, 0, Date())
        AppLog.shared.add("history", text)
    }

    /// Ends a run of the same line with its count. Called before a line of another kind.
    private func sayCount() {
        guard let last = said else { return }
        said = nil
        guard last.more > 0 else { return }
        AppLog.shared.add("history", "the same \(last.more) more times in \(Int(Date().timeIntervalSince(last.since).rounded())) s")
    }

    /// A launcher failure as a short line: what it means, without the fix the pages already show.
    nonisolated static func brief(_ error: String) -> String {
        if error.contains("os error 51") || error.contains("Network is unreachable") { return "no route to 10.7.0.1 (the proxy's VPN is down)" }
        if error.contains("os error 61") || error.contains("Connection refused") { return "iOS refused the connection at 10.7.0.1" }
        if error.contains("did not answer within") { return String(error.prefix(70)) }
        return String(error.replacingOccurrences(of: "no tree at hit test: no point of the screen answered the hit test ", with: "no app at the points read ").prefix(140))
    }

    var isRunning: Bool { status == .waiting || status == .reading }

    /// The wait before a single read, time to leave Poki and put another app in front.
    static let waitSeconds = 10
    /// Seconds between two looks of a run that hears nothing of the app in front. A run asks the
    /// phone to tell when an app comes to the front and reads it then, so no visit is missed (the
    /// owner, 2026-11-20, of a first fix that only looked every 30 seconds: "Cant miss things").
    /// Only on an iPhone that tells nothing does it look at this pace (the launcher's history.rs
    /// has the rules). Every 5 seconds, with accessibility left on in between, made the iPhone
    /// noticeably slow (the owner, the same day).
    static let interval = 15

    private weak var model: AppModel?
    /// The run in progress. Ending a run moves it on, so a late answer from an older one is ignored.
    private var run = 0
    private var once = false
    /// A run with no end of its own, started by `HistoryCollector` while Screen History is on.
    private var always = false
    var isAlways: Bool { always && isRunning }
    /// Whether the iPhone is locked or its screen is dark, once the lock is being watched.
    var screenOff: Bool { watchLock(); return lockedOrDark }
    /// Set when a run's launcher call was ended to wait (an agent's task took the screen), so the
    /// run goes on afterwards and is not taken for finished.
    private var interrupted = false
    /// An always run held inside the launcher while an agent's task has the screen.
    private var paused = false
    /// Why the run is waiting to read again, while it does.
    @Published private(set) var held: Status?
    /// Since when no read has worked, in a run. nil while reads work.
    private var failingSince: Date?
    /// Whether this run already told the owner it stopped by accident.
    private var notified = false
    /// The app last read that was an app, for a web page whose own process names none.
    private var host: String?
    /// Apple's processes found in front that are no app (a widget's renderer, a view service).
    /// The launcher is told, so each is read once and not again.
    private var processes: Set<String> = []
    /// What reading asked of the iPhone since `since`, for one line in the log every ten minutes:
    /// what the owner reads when the phone feels slow. No app is named in it.
    private var tally = Tally()

    private struct Tally {
        var since = Date()
        var looks = 0
        var reads = 0
        var leftOut = 0
        var askedMs = 0
        var slowestMs = 0
        /// How many looks each reason brought: an app that came to the front, a screen that moved
        /// again, the pace of a screen that changes, a look to be safe, a look that heard nothing.
        var due: [String: Int] = [:]
    }

    /// What was said in this run about the phone's own notices. They start again at every unlock,
    /// and each thing is said once.
    private var hintsSaid: Set<String> = []

    private static let tallyEvery: TimeInterval = 600
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

    /// Tells the launcher which apps' screens are never kept, so it does not read them: Poki, the
    /// Home Screen, the screens that sit over an app, what the owner left out, and Apple's
    /// processes that are no app. A read is made on the front app's own main thread, and one
    /// thrown away here cost the owner as much as one that is kept.
    private func tellLists() {
        guard !loading else { return }
        var skip: [String] = [Bundle.main.bundleIdentifier ?? "nz.zheha.poki", "com.apple.springboard"]
        skip.append(contentsOf: Self.overlays)
        skip.append(contentsOf: processes)
        if listMode == .exclude { skip.append(contentsOf: excluded) }
        HistoryBridge.policy(skip: skip, only: listMode == .include ? included : nil)
    }

    private func learn(process app: String) {
        guard processes.count < 200, processes.insert(app.lowercased()).inserted else { return }
        tellLists()
    }

    private func sayOnce(_ key: String, _ text: String) {
        guard hintsSaid.count < 40, hintsSaid.insert(key).inserted else { return }
        AppLog.shared.add("history", text)
    }

    /// Counts a look of the launcher's, and says the sum once every ten minutes.
    private func count(_ line: [String: Any]) {
        let number = { (key: String) in (line[key] as? NSNumber)?.intValue ?? 0 }
        tally.looks += 1
        if line["snapshot_ms"] != nil {
            tally.reads += 1
            tally.slowestMs = max(tally.slowestMs, number("snapshot_ms"))
        }
        if line["look"] as? String == "skipped" { tally.leftOut += 1 }
        if let due = line["due"] as? String { tally.due[due, default: 0] += 1 }
        tally.askedMs += number("subscribe_ms") + number("cost_ms")
        if Date().timeIntervalSince(tally.since) >= Self.tallyEvery { sayTally() }
    }

    private func sayTally() {
        let was = tally
        tally = Tally()
        guard was.looks > 0 else { return }
        let ran = max(1, Date().timeIntervalSince(was.since))
        let seconds = String(format: "%.1f", Double(was.askedMs) / 1000)
        let share = String(format: "%.2f", Double(was.askedMs) / 10 / ran)
        // Why the looks were made, most often first. With none named, the iPhone told nothing.
        let due = was.due.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let made = due.isEmpty ? "" : "; made for \(due)"
        AppLog.shared.add("history", "cost in \(Int((ran / 60).rounded())) min: \(was.looks) looks, \(was.reads) screens read (slowest \(was.slowestMs) ms), \(was.leftOut) left out; the iPhone was asked for \(seconds) s in all, \(share)% of the time\(made)")
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

    // MARK: Runs

    /// Called once as Poki starts. Started by iOS in the background (a change of place, a shortcut)
    /// with Screen History on, reading starts without waiting for Poki to be opened.
    func monitor(model: AppModel) {
        self.model = model
        guard Self.isEnabled else { return }
        Task { @MainActor in HistoryCollector.shared.attach(model) }
    }

    /// Called whenever Poki comes to the front: the collector starts the run, or starts it again.
    func appDidBecomeActive() {
        guard let model else { return }
        HistoryCollector.shared.attach(model)
    }

    /// Reads once after `waitSeconds`, or looks every `interval` seconds for `minutes`, or with `always`
    /// until the iPhone locks or the owner stops it (the collector starts it again after a lock).
    func start(minutes: Int? = nil, always: Bool = false, model: AppModel) {
        guard !isRunning else { return }
        if !enabled { enabled = true }
        watchLock()
        // A run with no end waits for the connection or an agent's task like any run under way.
        // A run with no end also starts while the iPhone is locked: held, so it only opens its tunnel.
        if let refused = refusal(model), !always || refused == .notPaired { set(refused); return }
        HistoryLock.shared.readStarting()
        run += 1
        let me = run
        once = minutes == nil && !always
        self.always = always
        prune()
        Task { await self.tidy() }
        interrupted = false
        paused = false
        held = nil
        failingSince = nil
        notified = false
        host = nil
        tally = Tally()
        hintsSaid = []
        tellLists()
        Self.withdrawNotice()
        background = UIApplication.shared.beginBackgroundTask(withName: "poki-screen-history") { [weak self] in
            Task { @MainActor in
                // While something else keeps Poki running (Poki is on), the run does not live on
                // this background time: only the task is given back, and reading goes on.
                if let self, self.run == me, self.isAlways, HistoryCollector.shared.staysUp(model) {
                    AppLog.shared.add("history", "background time given back; Poki stays up and reading goes on")
                    if self.background != .invalid {
                        UIApplication.shared.endBackgroundTask(self.background)
                        self.background = .invalid
                    }
                    return
                }
                AppLog.shared.add("history", "iOS ended the background time; keeper on: \(model.background.isOn), silent audio lost: \(model.background.audioLost)")
                // Not the owner's doing, and not the run's time being up.
                if let self, self.run == me, self.isRunning, !self.once { self.notice() }
                self?.end(me, .stopped)
            }
        }
        let wait = once ? Self.waitSeconds : 0
        set(once ? .waiting : .reading)
        // A run with no end asks the launcher for an hour at a time.
        // A day at a time for an always run: every new launcher call needs a new tunnel.
        let duration = always ? 86_400 : max(10, (minutes ?? 0) * 60)
        let until = always ? Date.distantFuture : Date().addingTimeInterval(Double(wait + (once ? 0 : duration)))
        ends = always ? nil : until
        #if !targetEnvironment(simulator)
        let screen = UIScreen.main.bounds
        let points = [0.5, 0.3, 0.7, 0.15].map { [Double(screen.midX), Double(screen.height) * $0] }
        #endif
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard self.run == me else { return }
            #if targetEnvironment(simulator)
            if let refused = self.refusal(model) { self.end(me, refused); return }
            self.set(.reading)
            await self.runOnSimulator(me: me, duration: duration, model: model)
            #else
            // A single read is one try, as before. A run lasts through what interrupts it (the
            // owner, 2026-11-18): while the local connection is down or an agent's task has the
            // screen it waits and tries again, and a launcher call that fails is started again
            // for the time left. Only the lock, the owner and the run's own time end it.
            var tries = 0
            while self.run == me {
                let left = self.once || self.always ? duration : Int(until.timeIntervalSinceNow.rounded())
                if left < (self.once ? 1 : 5) { break }
                // A run with no end does not wait here for the lock, a task or the connection
                // check: the launcher is asked at once and held (it opens its tunnel and reads
                // nothing), and it tries the connection itself. The check can be stale by seconds,
                // and those are the seconds a shortcut has with Cellular Data off.
                let asksHeld = self.always && (self.lockedOrDark || model.hasOpenInProcessSession)
                if let refused = self.refusal(model), !(self.always && refused != .notPaired) {
                    if self.once || refused == .locked || refused == .notPaired { self.end(me, refused); return }
                    self.hold(refused, model: model)
                    model.loopback.check()
                    tries += 1
                    // 2, 4, 8, 16, then every 30 seconds: on cellular the wait can be long.
                    try? await Task.sleep(for: .seconds(min(30, 1 << min(tries, 5))))
                    continue
                }
                if asksHeld {
                    self.paused = true
                    self.hold(self.lockedOrDark ? .locked : .task, model: model)
                } else {
                    self.resume()
                }
                let request: [String: Any] = [
                    "paused": asksHeld,
                    "op": "run", "device_address": "10.7.0.1", "pairing_file": model.pairingPath ?? "", "host_name": "Poki",
                    // After a restart the image is gone and the audit service with it: the run mounts it again.
                    "ddi_dir": AppFiles.ddiDirectory.path,
                    "direct_points": points, "interval_ms": Self.interval * 1000, "duration_s": max(10, left),
                    "include_text": true, "include_tree": true,
                    // The phone's own notices of the app in front and of the screen moving say
                    // when to read. They ask nothing of the apps.
                    "watch": true,
                ]
                do {
                    _ = try await HistoryBridge.call(request) { [weak self] line in
                        Task { @MainActor [weak self] in self?.took(line, run: me, model: model) }
                    }
                    guard self.run == me else { return }
                    if self.interrupted { self.interrupted = false; continue }
                    if self.always {
                        // The launcher's hour is up, or it answered early: ask again, never in a tight loop.
                        tries = 0
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    break
                } catch {
                    AppLog.shared.add("history", "capture stopped: \(error.localizedDescription)")
                    guard self.run == me, !self.once else { break }
                    self.interrupted = false
                    self.hold(.noConnection, model: model)
                    tries += 1
                    try? await Task.sleep(for: .seconds(min(30, 1 << min(tries, 5))))
                }
            }
            #endif
            self.end(me, .finished)
        }
    }

    /// The run waits: the status stays a running one, and the reason goes to the observing record.
    private func hold(_ why: Status, model: AppModel?) {
        if held != why {
            held = why
            HistoryStore.shared.note(why.rawValue)
            AppLog.shared.add("history", "run waits: \(why.rawValue)")
        }
        if status != .waiting { status = .waiting }
        // An agent's task is no accident, and neither is being on cellular, where iOS refuses the
        // local connection for as long as it lasts: nothing to turn back on.
        if why == .noConnection, let model, !model.loopback.cellularRefused { failing() } else { failingSince = nil }
    }

    /// Reads go on.
    private func resume() {
        if held != nil {
            held = nil
            HistoryStore.shared.note(Status.reading.rawValue)
        }
        if status != .reading { status = .reading }
    }

    // MARK: Dropped by accident

    private static let noticeID = "nz.zheha.poki.history.dropped"
    /// How long reads must have failed before the owner is told. A try to open the local
    /// connection takes up to 20 seconds, so this is about three in a row.
    private static let confirmAfter: TimeInterval = 60

    private func failing() {
        guard !once else { return }
        let since = failingSince ?? Date()
        failingSince = since
        if Date().timeIntervalSince(since) >= Self.confirmAfter { notice() }
    }

    private func working() {
        failingSince = nil
        if notified {
            notified = false
            Self.withdrawNotice()
        }
    }

    /// Tells the owner once per drop, and only while Poki is not the app in front, where the page
    /// itself says it.
    private func notice() {
        guard !notified else { return }
        notified = true
        HistoryStore.shared.note("dropped")
        AppLog.shared.add("history", "reading dropped by accident")
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(LocalizedStringResource("Screen History Stopped Reading"))
        content.body = AppLocalization.text(LocalizedStringResource("Poki lost its connection to this iPhone. Open Poki to turn Screen History back on."))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["poki_link": "poki://chat"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.noticeID, content: content,
                                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    private static func withdrawNotice() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [noticeID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [noticeID])
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
        held = nil
        failingSince = nil
        sayCount()
        sayTally()
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
                guard let self else { return }
                if self.lockedOrDark {
                    self.deviceLockChanged()
                } else {
                    // Let go at once, not at the launcher's next line.
                    if self.paused, self.isRunning, !(HistoryCollector.shared.taskOpen()) {
                        self.paused = false
                        HistoryBridge.pause(false)
                        self.resume()
                    }
                    HistoryCollector.shared.evaluate("the iPhone unlocked")
                }
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
        // A run with no end is held through the lock and keeps its tunnel: unlocked on
        // cellular, a new one could not be opened.
        if isAlways, isRunning {
            if !paused {
                paused = true
                HistoryBridge.pause(true)
            }
            hold(.locked, model: nil)
        } else {
            end(run, .locked)
        }
    }

    /// A line of the launcher's about its tunnel, not about a read: opened, lost, or the answer to
    /// a check.
    private func tunnelSaid(_ event: String, _ line: [String: Any]) {
        let number = { (key: String) in (line[key] as? NSNumber)?.intValue ?? 0 }
        var answer: Tunnel?
        switch event {
        case "open":
            lastOpenedAt = Date()
            lastTunnelAt = lastOpenedAt
            sayCount()
            let tries = number("tries")
            AppLog.shared.add("history", tries > 1
                ? "tunnel open in \(number("ms")) ms, at try \(tries), \(String(format: "%.1f", Double(number("after_ms")) / 1000)) s after the first"
                : "tunnel open in \(number("ms")) ms")
        case "lost":
            say("tunnel lost: \(Self.brief(line["error"] as? String ?? ""))")
        case "alive":
            lastTunnelAt = Date()
            answer = .alive(ms: number("ms"))
        case "dead":
            answer = .dead(Self.brief(line["error"] as? String ?? ""), givenUp: line["given_up"] as? Bool == true)
        case "none":
            answer = .missing
        case "watch":
            // The phone's notices of the app that comes to the front. What it sends is said, so
            // the log shows whether this iOS tells; no app is named.
            if line["notice"] as? Bool == true {
                let fields = (line["fields"] as? [String] ?? []).joined(separator: " ")
                sayOnce("notice", "first app notice, with \(fields.isEmpty ? "no field known" : fields)")
            } else if line["doubted"] != nil {
                if number("doubted") <= 3 { sayOnce("doubted \(number("doubted"))", "app notices found wrong, time \(number("doubted"))") }
            } else if line["on"] as? Bool == true {
                sayOnce("watch on", "app notices on in \(number("ms")) ms")
            } else {
                let why = Self.brief(line["error"] as? String ?? "")
                sayOnce("watch off \(why)", "app notices off: \(why)")
            }
        case "frames":
            // The count of frames the screen draws: a screen that draws nothing is not read again.
            if line["told"] as? Bool == true {
                sayOnce("frames told", "frame counts believed")
            } else if line["on"] as? Bool == true {
                sayOnce("frames on", "frame counts on")
            } else {
                let why = Self.brief(line["error"] as? String ?? "")
                sayOnce("frames off \(why)", "frame counts off: \(why)")
            }
        default:
            return
        }
        if let answer, let check = (line["check"] as? NSNumber)?.uint64Value { answers[check] = answer }
    }

    /// One read from the launcher. Only a screen whose text changed carries text.
    private func took(_ data: Data, run me: Int, model: AppModel) {
        guard me == run, let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let event = line["event"] as? String {
            tunnelSaid(event, line)
            return
        }
        // The tunnel is open: a read came through, or a held run says so.
        if line["ok"] as? Bool == true || line["tunnel"] as? Bool == true { lastTunnelAt = Date() }
        if let error = line["error"] as? String { lastFailure = error }
        if paused {
            // The launcher sends one line a round while it is held: the moment to look again.
            if lockedOrDark || model.hasOpenInProcessSession { return }
            paused = false
            HistoryBridge.pause(false)
            resume()
            return
        }
        guard status == .reading, !lockedOrDark else { return }
        if model.hasOpenInProcessSession {
            // A single read gives way. A run waits for the task to end and reads on. An always run
            // waits inside the launcher, which keeps its tunnel: on cellular a closed one cannot
            // be opened again (phone log, 2026-11-18).
            if once { end(me, .task) } else if always {
                paused = true
                HistoryBridge.pause(true)
                hold(.task, model: model)
            } else if !interrupted { interrupted = true; HistoryBridge.cancel() }
            return
        }
        if line["paused"] as? Bool == true { return }
        // A read the launcher could not make: its tunnel is down and it is opening another.
        let error = line["error"] as? String ?? ""
        if line["ok"] as? Bool == true {
            // A look that read no screen (the same app as a moment ago, or one that is left out)
            // shows the connection open as well as a read does.
            lastReadAt = Date()
            sayCount()
            working()
            count(line)
        } else if error.contains("no point of the screen") {
            // The connection answered and found no app at the points read (a system screen over
            // the app, the Home Screen mid-swipe), or the hit tests got no answer. Neither is a
            // lost connection, and the launcher reopens what it must by itself: no notice for it.
            say("read skipped: \(Self.brief(error))")
        } else {
            // The same reason is said once and counted, whatever the network: a try with no
            // tunnel comes five times a second around a change of network.
            say((line["tunnel"] as? Bool == false ? "no tunnel: " : "read failed: ") + Self.brief(error))
            if !model.loopback.cellularRefused { failing() }
        }
        if keep(line), once { end(me, .finished) }
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
        // No app of the owner's: the launcher leaves its screen unread from now on.
        if !app.isEmpty, !home, HistoryAppNames.isProcess(app) { learn(process: app) }
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
            // The simulator has no phone to spare: it reads at the old pace.
            try? await Task.sleep(for: .seconds(5))
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
