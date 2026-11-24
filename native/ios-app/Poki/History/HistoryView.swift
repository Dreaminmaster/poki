import SwiftUI

// Backtape's page (issue 356): the library of tiles (BacktapeLibrary.swift) behind the lock, with
// recording and settings in the bar. This file holds the grouping the tiles are built from, the
// page itself and Backtape Settings.

// MARK: Grouping

/// A stretch of the timeline: a part of a day, or a block of 10 minutes.
struct HistorySpan: Identifiable, Hashable {
    let start: Date
    let end: Date
    /// Newest first, with only the start of each text.
    let entries: [HistoryEntry]
    var id: Date { start }

    /// Apps used in it, the most read first.
    var apps: [String] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.app.isEmpty { counts[entry.app, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    @MainActor var title: String {
        let names = apps.prefix(3).map(HistoryNames.app)
        return names.isEmpty ? AppLocalization.text("Screen Text") : names.joined(separator: ", ")
    }

    /// Screen titles seen, oldest first, and when the tree gave none, the first line read.
    var summary: String {
        var seen: [String] = []
        for entry in entries.reversed() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !seen.contains(title) { seen.append(title) }
            if seen.count == 5 { break }
        }
        if !seen.isEmpty { return seen.joined(separator: ", ") }
        return entries.last?.text.split(separator: "\n").prefix(2).joined(separator: " ") ?? ""
    }
}

@MainActor
enum HistoryNames {
    static func app(_ id: String) -> String { HistoryAppNames.name(id) }

    static func status(_ status: HistoryCapture.Status) -> String {
        switch status {
        case .off: "Off"
        case .waiting: "Waiting to Read"
        case .reading: "Reading"
        case .finished: "Finished"
        case .stopped: "Stopped"
        case .locked: "iPhone Locked"
        case .task: "Waiting for an Agent's Task"
        case .noConnection: "No Local Connection"
        case .notPaired: "Not Paired"
        case .paused: "Paused, Waiting to Resume"
        }
    }

    static func record(_ kind: String) -> String {
        if let status = HistoryCapture.Status(rawValue: kind) { return self.status(status) }
        switch kind {
        case "leftOut": return "Left Out an App"
        case "cleared": return "History Cleared"
        case "dropped": return "Reading Dropped"
        case "shared": return "Answer Shared With Poki's Model"
        case "notShared": return "Answer Not Shared"
        default: return kind
        }
    }
}

// MARK: The page

struct HistoryPage: View {
    /// Senses itself (Settings and Security open it): the history first, its settings behind the
    /// toolbar's button and the ask bar under it (the owner, Nov 21 2026: Senses opened on its
    /// settings, with the ask bar on a settings page).
    var asSenses = true
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared
    @State private var layout = BacktapeLayout()
    @State private var loaded = false
    @State private var asking = ""

    /// What was read off the screen is behind the lock. With Screen History off the page holds only
    /// what Poki and agents did, which the Activity Log shows openly.
    private var locked: Bool { capture.enabled && !lock.unlocked && !Self.sample }

    /// `-pokiHistorySample 1` (Debug): three weeks of made-up reads, to look at the zoom.
    private static var sample: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "pokiHistorySample")
        #else
        false
        #endif
    }

    var body: some View {
        // With Screen History on, the whole page shows only after the system prompt (the row that opens
        // it asks first; the gate asks again after Poki was in the background).
        HistoryGate(whenOff: true) {
            if layout.isEmpty {
                List {
                    if loaded {
                        Section {
                            if capture.enabled {
                                Text("Nothing is kept yet. Start a read in Testing Options, use another app, then come back.").foregroundStyle(.secondary)
                            } else {
                                Text("Nothing here yet. What Poki and agents do on this iPhone shows up here.").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                BacktapeLibrary(layout: layout)
            }
        }
        // History: the timeline. As Senses, its settings are one button away; from the settings
        // page's own History row it has none (one way in to each control).
        // The history is the Senses page (the owner, Nov 21 2026): one title, wherever it opens from.
        .navigationTitle(AppLocalization.text("Senses"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if asSenses {
                ToolbarItem(placement: .primaryAction) {
                    // The same page as Settings › Screen History, not a copy (the owner, Nov 21 2026).
                    // History is already open here, or off, so it opens at once.
                    NavigationLink {
                        HistoryGate(whenOff: true) { ScreenHistorySettingsView().settingsPage() }
                    } label: {
                        Label("Screen History Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("senses.settings")
                }
            }
        }
        // No Ask Poki bar on Senses (the owner, Nov 21 2026): the timeline is the whole page, with the
        // zoom bar BacktapeLibrary puts at its foot.
        .task(id: "\(capture.changes) \(capture.enabled)") { await load() }
    }

    /// The owner's reads while Screen History is on, and what Poki did either way, newest first.
    private func load() async {
        #if DEBUG
        if Self.sample {
            layout = BacktapeLayout.build(Self.sampleEntries())
            loaded = true
            return
        }
        #endif
        await capture.tidy()
        let kept = capture.enabled ? await HistoryStore.shared.recent() : []
        let steps = BacktapeActivity.entries()
        let entries = steps.isEmpty ? kept : (kept + steps).sorted { $0.at > $1.at }
        layout = BacktapeLayout.build(entries)
        loaded = true
    }

    #if DEBUG
    private static func sampleEntries() -> [HistoryEntry] {
        let apps = ["com.apple.mobilesafari", "com.tencent.xin", "com.xingin.discover", "com.apple.MobileSMS", "com.apple.mobilenotes", "com.apple.Maps"]
        let words = ["Hotel options for the trip", "Group chat about dinner", "A video about coffee", "Notes for the meeting", "Directions to the station", "Reading the news"]
        var entries: [HistoryEntry] = []
        var id: Int64 = 1
        let now = Date()
        for hour in stride(from: 0, to: 21 * 24, by: 3) {
            for minute in stride(from: 0, to: 60, by: 12) {
                let at = now.addingTimeInterval(-Double(hour * 3600 + minute * 60))
                let k = Int(id) % apps.count
                entries.append(HistoryEntry(id: id, at: at, app: apps[k], title: words[k], text: words[k]))
                id += 1
            }
        }
        return entries
    }
    #endif
}

// MARK: Settings

/// Screen History's one settings page (the owner, Nov 21 2026): Settings › Screen History and the gear
/// on Senses open this same view, so both show and change one set of settings. Its switch and status,
/// what the history is used for, which apps are read, how long it is kept (on the page, not one row
/// further), the loopback shortcut it needs, and Clear History, which asks twice: which part, then the
/// system prompt. Callers put it behind `HistoryGate(whenOff: true)`.
struct ScreenHistorySettingsView: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var clearing = false
    @State private var cleared = 0
    @State private var needsShortcut = false
    @State private var warnsRisk = false

    /// The switch, with the shortcut's check, and the warning first on an iPhone without Face ID or
    /// Touch ID (the owner, Nov 21 2026: Senses is not available there until it is acknowledged).
    private var enabled: Binding<Bool> {
        let gated = HistoryReconnect.gated($capture.enabled, refused: $needsShortcut)
        return Binding(get: { gated.wrappedValue }, set: { on in
            if on, lock.needsRiskAcknowledgement { warnsRisk = true } else { gated.wrappedValue = on }
        })
    }

    private var permissionsValue: String? {
        if capture.listMode == .include {
            return AppLocalization.text(LocalizedStringResource("Include Only These Apps"))
        }
        let count = capture.excluded.filter { !HistoryCapture.isPoki($0) }.count
        return count > 0 ? "\(count)" : nil
    }

    /// Only while Screen History is on: off, the switch above already says so.
    private var recordingStatus: String {
        if capture.status == .reading { return AppLocalization.text(LocalizedStringResource("Recording")) }
        // A run that waits says why: the iPhone is locked, an agent's task, or no local connection.
        if capture.isRunning, let held = capture.held { return AppLocalization.text(LocalizedStringResource(String.LocalizationValue(HistoryNames.status(held)))) }
        return AppLocalization.text(LocalizedStringResource("Paused, Waiting to Resume"))
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: enabled) {
                    SettingsRow(title: "Screen History", symbol: "rectangle.stack")
                }
                .accessibilityIdentifier("screenHistory.enabled")
                .alert("Set Up the Shortcut First", isPresented: $needsShortcut) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Screen History needs the Poki Loopback shortcut. Add it below, run it once, then turn Screen History on.")
                }
                if capture.enabled {
                    SettingsRow(title: "Status", symbol: "dot.radiowaves.left.and.right", value: recordingStatus)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("screenHistory.status")
                }
            } footer: {
                Group {
                    Text("Poki saves screen text on this iPhone, except password fields and apps you exclude. It pauses while the iPhone is locked. When Poki or an agent searches your history, the matching text goes to your AI provider or that agent.")
                }
                .settingsFooter()
            }

            SensesUseSection()

            Section {
                NavigationLink {
                    HistoryGate(whenOff: true) { HistoryPermissionsPage().settingsPage() }
                } label: {
                    SettingsRow(title: "Excluded Apps", symbol: "eye.slash", value: permissionsValue)
                }
                .accessibilityIdentifier("screenHistory.excludedApps")
            }

            // Retention on the page itself (the owner, Nov 21 2026: a "Screen History Settings" row
            // inside Screen History's settings made no sense).
            Section {
                Picker(selection: $capture.retentionDays) {
                    Text("3 Days").tag(3)
                    Text("1 Week").tag(7)
                    Text("2 Weeks").tag(14)
                    Text("1 Month").tag(30)
                } label: {
                    SettingsRow(title: "Keep History For", symbol: "calendar")
                }
                Picker(selection: $capture.summaryDays) {
                    Text("As Long as History").tag(0)
                    Text("1 Month").tag(30)
                    Text("3 Months").tag(90)
                    Text("1 Year").tag(365)
                } label: {
                    SettingsRow(title: "Keep Summaries For", symbol: "text.append")
                }
                Picker(selection: $capture.storageMegabytes) {
                    Text(verbatim: "100 MB").tag(100)
                    Text(verbatim: "200 MB").tag(200)
                    Text(verbatim: "500 MB").tag(500)
                    Text(verbatim: "1 GB").tag(1024)
                    Text(verbatim: "2 GB").tag(2048)
                } label: {
                    SettingsRow(title: "Storage Limit", symbol: "internaldrive")
                }
                SettingsRow(title: "Storage Used", symbol: "chart.bar",
                            value: ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))
                    .accessibilityIdentifier("screenHistory.storage")
                SettingsRow(title: "Reads Kept", symbol: "square.stack", value: "\(size.entries)")
            } header: {
                Group {
                    SettingsHeader("Keeping")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Whichever limit is reached first starts erasing the oldest history in layers. Screen structure goes first, then screen text, and the summaries last.")
                }
                .settingsFooter()
            }

            // Always here: Screen History cannot be turned on before the shortcut ran once.
            CellularShortcutSection()

            Section {
                Button(role: .destructive) {
                    clearing = true
                } label: {
                    Text("Clear History").frame(maxWidth: .infinity)
                }
                .disabled(size.entries == 0 || lock.asking)
                .accessibilityIdentifier("screenHistory.clear")
            }
        }
        .navigationTitle(AppLocalization.text("Screen History"))
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: cleared)
        .task(id: capture.changes) { size = await HistoryStore.shared.size() }
        .alert(isPresented: $warnsRisk) {
            Alert(title: HistoryRiskText.title, message: HistoryRiskText.body,
                  primaryButton: .destructive(Text("Turn On Anyway")) {
                      lock.acceptRisk()
                      HistoryReconnect.gated($capture.enabled, refused: $needsShortcut).wrappedValue = true
                  },
                  secondaryButton: .cancel())
        }
        .confirmationDialog("Clear History", isPresented: $clearing, titleVisibility: .visible) {
            Button("Last 10 Minutes", role: .destructive) { clear { await capture.clear(last: 600) } }
            Button("Last Hour", role: .destructive) { clear { await capture.clear(last: 3600) } }
            Button("Last Day", role: .destructive) { clear { await capture.clear(last: 86_400) } }
            Button("Everything", role: .destructive) { clear { await capture.clearEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What is cleared cannot be brought back.")
        }
    }

    /// The second ask: the system prompt, then the clearing.
    private func clear(_ work: @escaping () async -> Void) {
        Task {
            guard await lock.confirm(AppLocalization.text("Clear Screen History")) else { return }
            await work()
            cleared += 1
        }
    }
}

// MARK: Privacy controls

/// Which apps are read: every app but the ones listed, or only the ones listed.
private struct HistoryPermissionsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var seen: [String] = []
    @State private var search = ""

    /// Poki's own screens are always left out, so Poki is never listed.
    private var chosen: [String] { (capture.listMode == .exclude ? capture.excluded : capture.included).filter { !HistoryCapture.isPoki($0) } }

    /// Apps that can be added: the ones read so far, the suggested ones, then every app Poki knows.
    private var candidates: [String] {
        var all: [String] = []
        let suggested = capture.listMode == .exclude ? HistoryCapture.suggested : []
        for app in suggested + seen + KnownApps.all.map(\.id) where !all.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            all.append(app)
        }
        let open = all.filter { app in
            !HistoryCapture.isPoki(app) && !HistoryAppNames.isProcess(app) && !HistoryCapture.isWeb(app) && !chosen.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        }
        let wanted = search.trimmingCharacters(in: .whitespaces)
        // Unsearched, only what Poki can show properly: an app it knows or has an icon for. Anything
        // else is still found by searching its name or bundle ID.
        guard !wanted.isEmpty else {
            return open.filter { KnownApps.byID[$0.lowercased()] != nil || AppIconStore.shared.icon($0) != nil || HistoryAppNames.isNamed($0) }
        }
        return open.filter { $0.localizedCaseInsensitiveContains(wanted) || HistoryNames.app($0).localizedCaseInsensitiveContains(wanted) }
    }

    private func add(_ app: String) {
        if capture.listMode == .exclude { capture.excluded.append(app) } else { capture.included.append(app) }
    }

    private func remove(_ app: String) {
        if capture.listMode == .exclude { capture.excluded.removeAll { $0 == app } } else { capture.included.removeAll { $0 == app } }
    }

    var body: some View {
        List {
            Section {
                Picker("Apps", selection: $capture.listMode) {
                    Text("Exclude These Apps").tag(HistoryCapture.ListMode.exclude)
                    Text("Include Only These Apps").tag(HistoryCapture.ListMode.include)
                }
                .pickerStyle(.segmented)
            } footer: {
                Group {
                    Text(LocalizedStringKey(capture.listMode == .exclude
                        ? "Poki never keeps what these apps show. A read of one is dropped before anything is stored."
                        : "Poki keeps only what these apps show. Every other app is left out."))
                }
                .settingsFooter()
            }
            Section {
                ForEach(chosen, id: \.self) { app in
                    HStack(spacing: 12) {
                        AppIconView(app: app, size: 28)
                        HistoryAppName(app: app)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { remove(app) } }
                }
                if chosen.isEmpty { Text("No Apps").foregroundStyle(.secondary) }
            } header: {
                Group {
                    Text(LocalizedStringKey(capture.listMode == .exclude ? "Excluded" : "Included"))
                }
                .settingsHeader()
            }
            Section {
                ForEach(candidates.prefix(60), id: \.self) { app in
                    Button { add(app) } label: {
                        HStack(spacing: 12) {
                            AppIconView(app: app, size: 28)
                            HistoryAppName(app: app).foregroundStyle(Color(.label))
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Group {
                    Text("Add App")
                }
                .settingsHeader()
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(AppLocalization.text("Permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .task { seen = await HistoryStore.shared.apps() }
    }
}
