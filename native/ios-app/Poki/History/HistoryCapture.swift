import Foundation
import SwiftUI
import UIKit
import notify

/// iPhone History's capture loop and its privacy controls (issue 356).
///
/// While history is on, the launcher reads the app in front as text every few seconds through the
/// accessibility service over the loopback, with no automation session. Every control is checked
/// before a read is kept: the switch, Pause, access times, the lock and the screen, an agent's task,
/// and the app list. A read that passes goes to `HistoryStore`. Nothing leaves the phone.
@MainActor
final class HistoryCapture: ObservableObject {
    static let shared = HistoryCapture()

    /// Why reading is on or not, as the panel and the observing record say it.
    enum Status: String {
        case off, reading, paused, outsideHours, locked, task, testing, noConnection, notPaired
    }

    enum ListMode: String, CaseIterable, Identifiable {
        case exclude, include
        var id: String { rawValue }
    }

    // MARK: Settings (kept in UserDefaults)

    @Published var enabled: Bool { didSet { save(enabled, "history.enabled"); settingsChanged() } }
    /// Until when reading is paused. The distant future is "until turned on again".
    @Published var pausedUntil: Date? { didSet { save(pausedUntil?.timeIntervalSince1970, "history.pausedUntil"); settingsChanged() } }
    @Published var showIndicator: Bool { didSet { save(showIndicator, "history.showIndicator") } }
    @Published var listMode: ListMode { didSet { save(listMode.rawValue, "history.listMode") } }
    @Published var excluded: [String] { didSet { save(excluded, "history.excluded") } }
    @Published var included: [String] { didSet { save(included, "history.included") } }
    @Published var scheduleOn: Bool { didSet { save(scheduleOn, "history.scheduleOn"); settingsChanged() } }
    /// Minutes after midnight.
    @Published var startMinute: Int { didSet { save(startMinute, "history.startMinute"); settingsChanged() } }
    @Published var endMinute: Int { didSet { save(endMinute, "history.endMinute"); settingsChanged() } }
    /// Calendar weekdays, 1 for Sunday.
    @Published var weekdays: [Int] { didSet { save(weekdays, "history.weekdays"); settingsChanged() } }
    @Published var retentionDays: Int { didSet { save(retentionDays, "history.retentionDays"); HistoryStore.shared.prune(days: retentionDays) } }
    @Published var seconds: Int { didSet { save(seconds, "history.seconds"); restart() } }

    // MARK: State

    @Published private(set) var status: Status = .off
    /// Bumped when a read is kept or history is deleted, so an open panel reloads.
    @Published private(set) var changes = 0
    @Published private(set) var lastKept: Date?

    private weak var model: AppModel?
    private var running = false
    private var timer: Timer?
    private var ticks = 0
    private var lockToken: Int32 = NOTIFY_TOKEN_INVALID
    private var screenToken: Int32 = NOTIFY_TOKEN_INVALID
    private let keepAlive = KeepAlive()
    private var lastLeftOut: String?
    private var loading = true

    /// Suggested for the excluded list: passwords, banking, payments and messages.
    static let suggested = [
        "com.apple.Passwords", "com.agilebits.onepassword-ios", "com.apple.Passbook", "com.alipay.iphoneclient",
        "com.paypal.PPClient", "com.apple.MobileSMS", "com.tencent.xin", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph",
    ]

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "history.enabled")
        pausedUntil = (defaults.object(forKey: "history.pausedUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        showIndicator = defaults.object(forKey: "history.showIndicator") as? Bool ?? true
        listMode = ListMode(rawValue: defaults.string(forKey: "history.listMode") ?? "") ?? .exclude
        // Poki's own screens are left out from the start.
        excluded = defaults.stringArray(forKey: "history.excluded") ?? [Bundle.main.bundleIdentifier ?? "nz.zheha.poki"]
        included = defaults.stringArray(forKey: "history.included") ?? []
        scheduleOn = defaults.bool(forKey: "history.scheduleOn")
        startMinute = defaults.object(forKey: "history.startMinute") as? Int ?? 8 * 60
        endMinute = defaults.object(forKey: "history.endMinute") as? Int ?? 22 * 60
        weekdays = defaults.array(forKey: "history.weekdays") as? [Int] ?? Array(1...7)
        retentionDays = defaults.object(forKey: "history.retentionDays") as? Int ?? 3
        seconds = defaults.object(forKey: "history.seconds") as? Int ?? 5
        loading = false
    }

    private func save(_ value: Any?, _ key: String) {
        guard !loading else { return }
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: Starting

    /// Called once when Poki starts.
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let changed: @Sendable (Int32) -> Void = { [weak self] _ in Task { @MainActor in self?.evaluate() } }
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, DispatchQueue.main, changed)
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &screenToken, DispatchQueue.main, changed)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        HistoryStore.shared.prune(days: retentionDays)
        evaluate()
    }

    private func tick() {
        ticks += 1
        // Retention and the storage cap, once an hour.
        if ticks % 360 == 0, enabled { HistoryStore.shared.prune(days: retentionDays) }
        evaluate()
    }

    private func settingsChanged() {
        guard !loading else { return }
        evaluate()
    }

    // MARK: The controls

    private func state(_ token: Int32) -> Bool {
        var value: UInt64 = 0
        return token != NOTIFY_TOKEN_INVALID && notify_get_state(token, &value) == NOTIFY_STATUS_OK && value != 0
    }

    private var lockedOrDark: Bool { state(lockToken) || state(screenToken) }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    func insideHours(_ date: Date = Date()) -> Bool {
        guard scheduleOn else { return true }
        let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: date)
        guard weekdays.contains(parts.weekday ?? 0) else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return true }
        return startMinute < endMinute ? (startMinute..<endMinute).contains(minute) : (minute >= startMinute || minute < endMinute)
    }

    /// Whether reads of this app are kept, by the list the owner chose.
    func keeps(_ app: String) -> Bool {
        switch listMode {
        case .exclude: !excluded.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        case .include: included.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        }
    }

    func exclude(_ app: String) {
        included.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        guard !excluded.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) else { return }
        excluded.append(app)
    }

    func pause(until date: Date) { pausedUntil = date }
    func resume() { pausedUntil = nil }

    private func wanted() -> Status {
        guard enabled else { return .off }
        if isPaused { return .paused }
        if !insideHours() { return .outsideHours }
        if lockedOrDark { return .locked }
        guard let model else { return .off }
        if HistoryProbe.shared.running || HistoryProbe.shared.reading { return .testing }
        // Reading stays out of the way of an agent's task.
        if model.hasOpenInProcessSession { return .task }
        if model.pairingPath == nil { return .notPaired }
        if !model.loopback.isWorking { return .noConnection }
        return .reading
    }

    /// Checks every control and starts or stops reading to match.
    func evaluate() {
        if let until = pausedUntil, until <= Date() { pausedUntil = nil; return }
        let next = wanted()
        if next != status {
            status = next
            HistoryStore.shared.note(next.rawValue)
            // The file is closed while the phone is locked, so iOS's file protection holds.
            if next == .locked { HistoryStore.shared.close() }
        }
        if enabled {
            if !keepAlive.isOn { try? keepAlive.start() }
        } else if keepAlive.isOn {
            keepAlive.stop()
        }
        if next == .reading { start() } else { stop() }
    }

    // MARK: Reading

    private func start() {
        guard !running, let model, let path = model.pairingPath else { return }
        running = true
        lastLeftOut = nil
        let screen = UIScreen.main.bounds
        let points = [0.5, 0.3, 0.7, 0.15].map { [Double(screen.midX), Double(screen.height) * $0] }
        let request: [String: Any] = [
            "op": "run", "device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki", "direct_points": points,
            "interval_ms": max(1, seconds) * 1000, "duration_s": 86_400, "include_text": true,
        ]
        Task {
            do {
                _ = try await HistoryBridge.call(request) { [weak self] line in
                    Task { @MainActor in self?.took(line) }
                }
            } catch {
                AppLog.shared.add("history", "capture stopped: \(error.localizedDescription)")
            }
            self.running = false
            // Reading that ended by itself (a dropped connection, a day's run) starts again here.
            self.evaluate()
        }
    }

    private func stop() {
        guard running else { return }
        HistoryBridge.cancel()
    }

    private func restart() {
        guard !loading, running else { return }
        HistoryBridge.cancel()
    }

    /// One read from the launcher. Only a screen whose text changed carries text.
    private func took(_ data: Data) {
        guard status == .reading, !lockedOrDark,
              let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              line["ok"] as? Bool == true,
              let lines = line["text"] as? [String], !lines.isEmpty else { return }
        let app = line["app"] as? String ?? ""
        guard keeps(app) else {
            // The observing record names an app left out once each time it comes to the front.
            if lastLeftOut != app {
                lastLeftOut = app
                HistoryStore.shared.note("leftOut", app)
            }
            return
        }
        lastLeftOut = nil
        let now = Date()
        HistoryStore.shared.add(at: now, app: app, title: line["title"] as? String ?? "", text: lines.joined(separator: "\n"))
        lastKept = now
        changes += 1
    }

    // MARK: Deleting

    func clear(last seconds: TimeInterval) async {
        await HistoryStore.shared.delete(from: Date().addingTimeInterval(-seconds), to: Date().addingTimeInterval(60))
        HistoryStore.shared.note("cleared", "\(Int(seconds))")
        changes += 1
    }

    func clear(app: String) async {
        await HistoryStore.shared.delete(app: app)
        HistoryStore.shared.note("clearedApp", app)
        changes += 1
    }

    func clearEverything() async {
        await HistoryStore.shared.deleteEverything()
        HistoryStore.shared.note("clearedAll")
        changes += 1
    }

    func delete(_ entry: HistoryEntry) async {
        await HistoryStore.shared.delete(entry: entry.id)
        changes += 1
    }

    func delete(from start: Date, to end: Date) async {
        await HistoryStore.shared.delete(from: start, to: end)
        changes += 1
    }
}
