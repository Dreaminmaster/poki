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
        }
    }

    static func record(_ kind: String) -> String {
        if let status = HistoryCapture.Status(rawValue: kind) { return self.status(status) }
        switch kind {
        case "leftOut": return "Left Out an App"
        case "cleared": return "History Cleared"
        case "dropped": return "Reading Dropped"
        default: return kind
        }
    }
}

// MARK: The page

struct HistoryPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared
    @State private var layout = BacktapeLayout()
    @State private var loaded = false

    /// What was read off the screen is behind the lock. With Screen History off the page holds only
    /// what Poki and agents did, which the Activity Log shows openly.
    private var locked: Bool { capture.enabled && !lock.unlocked }

    var body: some View {
        Group {
            // With Screen History on, the whole page opens only after Face ID, Touch ID or Poki's PIN.
            if locked {
                BacktapeLockScreen()
            } else if layout.isEmpty {
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
        .navigationTitle(AppLocalization.text("Screen History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !locked {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { HistoryGate(whenOff: true) { BacktapeSettingsPage().settingsPage() } } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Screen History Settings"))
                }
            }
        }
        .task(id: "\(capture.changes) \(capture.enabled)") { await load() }
    }

    /// The owner's reads while Screen History is on, and what Poki did either way, newest first.
    private func load() async {
        await capture.tidy()
        let kept = capture.enabled ? await HistoryStore.shared.recent() : []
        let steps = BacktapeActivity.entries()
        let entries = steps.isEmpty ? kept : (kept + steps).sorted { $0.at > $1.at }
        layout = BacktapeLayout.build(entries)
        loaded = true
    }
}

// MARK: Settings

struct ScreenHistorySettingsView: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var reconnect = HistoryReconnect.shared
    @Environment(\.openURL) private var openURL

    private var lastRun: String {
        guard let at = reconnect.lastAt else { return AppLocalization.text(LocalizedStringResource("Never")) }
        if !reconnect.lastWorked { return AppLocalization.text(LocalizedStringResource("Did Not Connect")) }
        return at.formatted(.relative(presentation: .named))
    }
    @ObservedObject private var lock = HistoryLock.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var clearing = false

    private var permissionsValue: String? {
        if capture.listMode == .include {
            return AppLocalization.text(LocalizedStringResource("Include Only These Apps"))
        }
        let count = capture.excluded.filter { !HistoryCapture.isPoki($0) }.count
        return count > 0 ? "\(count)" : nil
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $capture.enabled) {
                    SettingsRow(title: "Screen History", symbol: "rectangle.stack")
                }
                .accessibilityIdentifier("screenHistory.enabled")
            } footer: {
                Text("When on, Poki can answer questions from text kept on this iPhone. Excluded apps and password fields are left out, and nothing leaves this iPhone.")
            }

            Section {
                NavigationLink {
                    HistoryPage().settingsPage()
                } label: {
                    SettingsRow(
                        title: "View History",
                        symbol: "clock.arrow.circlepath",
                        value: size.entries > 0 ? "\(size.entries)" : nil
                    )
                }
                .accessibilityIdentifier("screenHistory.records")

                NavigationLink {
                    if lock.needsSetup {
                        HistoryPermissionsPage().settingsPage()
                    } else {
                        HistoryGate { HistoryPermissionsPage().settingsPage() }
                    }
                } label: {
                    SettingsRow(
                        title: "Excluded Apps",
                        symbol: "eye.slash",
                        value: permissionsValue
                    )
                }
                .accessibilityIdentifier("screenHistory.excludedApps")
            }

            if capture.enabled {
                Section {
                    Button {
                        openURL(HistoryReconnect.shortcut)
                    } label: {
                        SettingsRow(title: "Get the Shortcut", symbol: "square.2.layers.3d", accessory: .leaves)
                    }
                    .accessibilityIdentifier("screenHistory.shortcut")
                    NavigationLink {
                        HistoryShortcutGuide().settingsPage()
                    } label: {
                        SettingsRow(title: "Set Up by Hand", symbol: "list.number")
                    }
                    SettingsRow(title: "Last Run", symbol: "arrow.triangle.2.circlepath", value: lastRun, warns: reconnect.lastAt != nil && !reconnect.lastWorked)
                        .accessibilityIdentifier("screenHistory.shortcutLastRun")
                } header: {
                    SettingsHeader("On Cellular")
                } footer: {
                    Text("On cellular, iOS lets Poki keep its connection but not open a new one. The shortcut runs when Wi-Fi disconnects. It turns Cellular Data off for a moment, lets Poki connect, and turns it back on. When you add it, turn its automation on, turn Confirm Before Run off, and choose your VPN app.")
                }
            }

            Section {
                Button("Clear History", role: .destructive) {
                    clearing = true
                }
                .accessibilityIdentifier("screenHistory.clear")
            } footer: {
                if size.entries > 0 {
                    Text(verbatim: String(
                        format: AppLocalization.text("Storage used: %@"),
                        ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
                    ))
                }
            }
        }
        .navigationTitle(AppLocalization.text("Screen History"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: capture.changes) { size = await HistoryStore.shared.size() }
        .confirmationDialog("Clear History", isPresented: $clearing, titleVisibility: .visible) {
            Button("Last 10 Minutes", role: .destructive) { Task { await capture.clear(last: 600) } }
            Button("Last Hour", role: .destructive) { Task { await capture.clear(last: 3600) } }
            Button("Last Day", role: .destructive) { Task { await capture.clear(last: 86_400) } }
            Button("Everything", role: .destructive) { Task { await capture.clearEverything() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The Wi-Fi automation built by hand, for an iPhone where the shared shortcut arrives without it
/// or without Poki's action.
struct HistoryShortcutGuide: View {
    private let steps: [LocalizedStringKey] = [
        "Open Shortcuts and go to Automation.",
        "Add an automation for Wi-Fi, choose Disconnects From Network, and choose Run Immediately.",
        "Add Set Cellular Data and set it to Off.",
        "If your VPN or proxy app is not always on, add its action that turns it on.",
        "Add Reconnect Poki from the actions of Poki.",
        "Add Set Cellular Data and set it to On.",
    ]

    var body: some View {
        List {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "\(index + 1)").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                        Text(step)
                    }
                }
            } footer: {
                Text("On older versions of iOS, automations are a separate tab in Shortcuts and do not come with a shared shortcut. These steps make the same one.")
            }
        }
        .navigationTitle(AppLocalization.text("Set Up by Hand"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Everything that sets Backtape up, on a page of its own: the switch, pause, access times, apps,
/// how long tape is kept, the reminder, the lock and the record.
struct BacktapeSettingsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                Toggle("Screen History", isOn: $capture.enabled)
                NavigationLink { HistoryGate { HistoryPermissionsPage().settingsPage() } } label: {
                    LabeledContent("Permissions") {
                        Text(LocalizedStringKey(capture.listMode == .exclude ? "Exclude These Apps" : "Include Only These Apps"))
                    }
                }
            }
            Section {
                Picker("Keep History For", selection: $capture.retentionDays) {
                    Text("3 Days").tag(3)
                    Text("1 Week").tag(7)
                    Text("2 Weeks").tag(14)
                    Text("1 Month").tag(30)
                }
                Picker("Keep Summaries For", selection: $capture.summaryDays) {
                    Text("As Long as History").tag(0)
                    Text("1 Month").tag(30)
                    Text("3 Months").tag(90)
                    Text("1 Year").tag(365)
                }
                Picker("Storage Limit", selection: $capture.storageMegabytes) {
                    Text(verbatim: "100 MB").tag(100)
                    Text(verbatim: "200 MB").tag(200)
                    Text(verbatim: "500 MB").tag(500)
                    Text(verbatim: "1 GB").tag(1024)
                    Text(verbatim: "2 GB").tag(2048)
                }
            } footer: {
                Text("Whichever limit is reached first starts erasing the oldest history in layers. Screen structure goes first, then screen text, and the summaries last.")
            }
            Section {
                NavigationLink { HistoryGate { HistoryLockSettings().settingsPage() } } label: { Text("Screen History Lock") }
                NavigationLink { HistoryGate { HistoryRecordPage().settingsPage() } } label: { Text("Observing Record") }
                LabeledContent("Storage Used") {
                    Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))")
                }
                LabeledContent("Reads Kept") { Text(verbatim: "\(size.entries)").monospacedDigit() }
            }
            Section {
                Button("Clear History", role: .destructive) { clearing = true }
            }
        }
        .navigationTitle(AppLocalization.text("Screen History Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: capture.changes) { size = await HistoryStore.shared.size() }
        .confirmationDialog("Clear History", isPresented: $clearing, titleVisibility: .visible) {
            Button("Last 10 Minutes", role: .destructive) { Task { await capture.clear(last: 600) } }
            Button("Last Hour", role: .destructive) { Task { await capture.clear(last: 3600) } }
            Button("Last Day", role: .destructive) { Task { await capture.clear(last: 86_400) } }
            Button("Everything", role: .destructive) { Task { await capture.clearEverything() } }
            Button("Cancel", role: .cancel) {}
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
                Text(LocalizedStringKey(capture.listMode == .exclude
                    ? "Poki never keeps what these apps show. A read of one is dropped before anything is stored."
                    : "Poki keeps only what these apps show. Every other app is left out."))
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
                Text(LocalizedStringKey(capture.listMode == .exclude ? "Excluded" : "Included"))
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
                Text("Add App")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(AppLocalization.text("Permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .task { seen = await HistoryStore.shared.apps() }
    }
}

/// When reading was on, paused, blocked or left an app out.
private struct HistoryRecordPage: View {
    @State private var records: [HistoryRecord] = []

    private func detail(_ record: HistoryRecord) -> String {
        switch record.kind {
        case "leftOut": HistoryNames.app(record.detail)
        default: ""
        }
    }

    var body: some View {
        List {
            ForEach(records) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(HistoryNames.record(record.kind)))
                        if !detail(record).isEmpty { Text(verbatim: detail(record)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(verbatim: record.at.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(AppLocalization.locale)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if records.isEmpty { Text("Nothing Yet").foregroundStyle(.secondary) }
        }
        .navigationTitle(AppLocalization.text("Observing Record"))
        .navigationBarTitleDisplayMode(.inline)
        .task { records = await HistoryStore.shared.records() }
    }
}

// MARK: Testing Options

/// General › Testing Options › Screen History: a single read, a short run, and Stop for the
/// collector's run (`HistoryCollector`), which starts by itself while Screen History is on.
struct HistoryTestingSection: View {
    @ObservedObject var capture = HistoryCapture.shared
    @Environment(AppModel.self) private var model
    @State private var minutes = HistoryCapture.runMinutes[0]

    var body: some View {
        Section {
            LabeledContent("Status") {
                if let held = capture.held, capture.isRunning {
                    // A run that waits says why: no local connection, or an agent's task.
                    Text(LocalizedStringKey(HistoryNames.status(held)))
                } else if let ends = capture.ends, capture.isRunning {
                    Text(timerInterval: Date()...max(Date(), ends), countsDown: true).monospacedDigit()
                } else {
                    Text(LocalizedStringKey(HistoryNames.status(capture.status)))
                }
            }
            Button("Read in 10 Seconds") { capture.start(model: model) }
                .disabled(capture.isRunning)
            Picker("Short Run", selection: $minutes) {
                ForEach(HistoryCapture.runMinutes, id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(capture.isRunning)
            Button("Start Short Run") { capture.start(minutes: minutes, model: model) }
                .disabled(capture.isRunning)
            Button("Stop", role: .destructive) { HistoryCollector.shared.ownerStop() }
                .disabled(!capture.isRunning)
        } header: {
            Text("Screen History")
        } footer: {
            Text("An experiment. While Screen History is on, Poki reads the text of the app in front and keeps it on this iPhone. Reading waits while the iPhone is locked or an agent works, then goes on by itself. Stop holds it until you open Poki again. Password fields are left out, and nothing is sent anywhere.")
        }
    }
}
