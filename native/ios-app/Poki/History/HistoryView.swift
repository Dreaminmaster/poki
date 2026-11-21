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
        // History: the timeline under Senses. Its settings are on the Senses page it opens from, so
        // it has no settings button of its own (one way in to each control).
        .navigationTitle(AppLocalization.text("History"))
        .navigationBarTitleDisplayMode(.inline)
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

/// Senses (Settings, the welcome and Security open it): every sense in one place (the owner, Nov 20
/// 2026). Screen History and its status, what the history is used for (SensesUseSection, which was on
/// Screen History Settings), the history itself, which apps are read, the cellular shortcut and
/// clearing. Retention, the lock and the record are one row further, on Screen History Settings.
/// The ask bar at the foot was the Senses card's panel's (f1a436ae); it stays with the page.
struct ScreenHistorySettingsView: View {
    /// The ask bar at the foot; the welcome's setup step leaves it out.
    var asks = true
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var asking = ""
    @ObservedObject private var lock = HistoryLock.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var clearing = false
    @State private var needsShortcut = false

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
                Toggle(isOn: HistoryReconnect.gated($capture.enabled, refused: $needsShortcut)) {
                    SettingsRow(title: "Screen History", symbol: "rectangle.stack")
                }
                .accessibilityIdentifier("screenHistory.enabled")
                .alert("Set Up the Shortcut First", isPresented: $needsShortcut) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Screen History needs the shortcut that keeps Poki connected on cellular. Add it below, run it once, then turn Screen History on.")
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
                    HistoryPage().settingsPage()
                } label: {
                    SettingsRow(
                        title: "History",
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
                NavigationLink { HistoryGate(whenOff: true) { BacktapeSettingsPage().settingsPage() } } label: {
                    SettingsRow(title: "Screen History Settings", symbol: "slider.horizontal.3")
                }
                .accessibilityIdentifier("screenHistory.settings")
            }

            // Always here: Screen History cannot be turned on before the shortcut ran once.
            CellularShortcutSection()

            Section {
                Button("Clear History", role: .destructive) {
                    clearing = true
                }
                .accessibilityIdentifier("screenHistory.clear")
            }
        }
        .navigationTitle(AppLocalization.text("Senses"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBar(softEdge: true) { if asks { PokiAskBar(text: $asking, scope: .senses) } }
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

/// The shortcut that keeps the loopback on cellular: its link, the same automation by hand, and when
/// it last ran. Shown where the loopback is set up (the owner, 2026-11-19: asked for in the same
/// step) and in Screen History's settings.
struct CellularShortcutSection: View {
    @ObservedObject private var reconnect = HistoryReconnect.shared
    @Environment(\.openURL) private var openURL

    private var lastRun: String {
        guard let at = reconnect.lastAt else { return AppLocalization.text(LocalizedStringResource("Never")) }
        if !reconnect.lastWorked { return AppLocalization.text(LocalizedStringResource("Did Not Connect")) }
        return at.formatted(.relative(presentation: .named))
    }

    var body: some View {
        Section {
            Button {
                openURL(reconnect.take())
            } label: {
                SettingsRow(title: "Get the Shortcut", symbol: "square.2.layers.3d", accessory: .leaves)
            }
            .accessibilityIdentifier("cellularShortcut.get")
            if reconnect.canRun {
                // It asks Poki first and changes nothing while the connection is fine, so it can
                // be run whenever the loopback is off (the owner, 2026-11-20).
                Button {
                    openURL(HistoryReconnect.run)
                } label: {
                    SettingsRow(title: "Run the Shortcut", symbol: "play", accessory: .leaves)
                }
                .accessibilityIdentifier("cellularShortcut.run")
            }
            NavigationLink {
                HistoryShortcutGuide().settingsPage().onAppear { reconnect.asked = true }
            } label: {
                SettingsRow(title: "Set Up by Hand", symbol: "list.number")
            }
            SettingsRow(title: "Last Run", symbol: "clock", value: lastRun, warns: reconnect.lastAt != nil && !reconnect.lastWorked)
                .accessibilityIdentifier("cellularShortcut.lastRun")
        } header: {
            Group {
                SettingsHeader("On Cellular")
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("On cellular, iOS lets Poki keep a connection but not open a new one. This shortcut connects it again. Turn its automation on, turn Confirm Before Run off, and choose your VPN app.")
            }
            .settingsFooter()
        }
    }
}

/// The Wi-Fi automation added by hand, for an iPhone where the shared shortcut arrives without it.
/// The shortcut itself comes from the link there too, so the automation only has to run it.
struct HistoryShortcutGuide: View {
    private let steps: [LocalizedStringKey] = [
        "Add Poki Loopback with Get the Shortcut on the page before, and choose your VPN app when it asks.",
        "Open Shortcuts and go to Automation.",
        "Add an automation for Wi-Fi, choose Disconnects From Network, and choose Run Immediately.",
        "Choose Poki Loopback as the shortcut to run.",
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
                Group {
                    Text("On older versions of iOS, automations are a separate tab in Shortcuts and do not come with a shared shortcut. These steps add the automation that runs it.")
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Set Up by Hand"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Retention, the lock and the observing record. Which apps are read, what the history is used for
/// and clearing it are on the Senses page this opens from, once.
struct BacktapeSettingsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)

    var body: some View {
        List {
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
                Group {
                    Text("Whichever limit is reached first starts erasing the oldest history in layers. Screen structure goes first, then screen text, and the summaries last.")
                }
                .settingsFooter()
            }
            Section {
                // The lock and the Observing Record are on Security, once (the owner, Nov 20 2026).
                LabeledContent("Storage Used") {
                    Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))")
                }
                LabeledContent("Reads Kept") { Text(verbatim: "\(size.entries)").monospacedDigit() }
            }
        }
        .navigationTitle(AppLocalization.text("Screen History Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: capture.changes) { size = await HistoryStore.shared.size() }
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

/// When reading was on, paused, blocked or left an app out.
struct HistoryRecordPage: View {
    @State private var records: [HistoryRecord] = []

    private func detail(_ record: HistoryRecord) -> String {
        switch record.kind {
        case "leftOut": HistoryNames.app(record.detail)
        case "shared", "notShared": record.detail
        default: ""
        }
    }

    var body: some View {
        List {
            ForEach(records) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(HistoryNames.record(record.kind)))
                        if !detail(record).isEmpty { Text(verbatim: detail(record)).font(.allo(.footnote)).foregroundStyle(.secondary) }
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
