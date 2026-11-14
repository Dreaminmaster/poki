import SwiftUI

// iPhone History's page (issue 356): the settings card with the privacy controls on top, and under
// it the timeline. Days hold the parts of the day, each with a title, a description and the icons of
// the apps used. A part opens into blocks of 10 minutes, and a block into the reads kept in it.
// Titles and descriptions are made on the phone without a model: app names, screen titles and the
// first lines read.

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
    static func app(_ id: String) -> String { AppIconStore.name(id) ?? id }

    static func part(_ hour: Int) -> String {
        switch hour {
        case 6..<12: "Morning"
        case 12..<18: "Afternoon"
        case 18..<24: "Evening"
        default: "Night"
        }
    }

    static func status(_ status: HistoryCapture.Status) -> String {
        switch status {
        case .off: "Off"
        case .reading: "Reading"
        case .paused: "Paused"
        case .outsideHours: "Outside Access Times"
        case .locked: "iPhone Locked"
        case .task: "Waiting for an Agent's Task"
        case .testing: "Waiting for a Test"
        case .noConnection: "No Local Connection"
        case .notPaired: "Not Paired"
        }
    }

    static func record(_ kind: String) -> String {
        if let status = HistoryCapture.Status(rawValue: kind) { return self.status(status) }
        switch kind {
        case "leftOut": return "Left Out an App"
        case "cleared": return "History Cleared"
        case "clearedApp": return "App History Cleared"
        case "clearedAll": return "All History Cleared"
        default: return kind
        }
    }

    /// Days, newest first, each with its parts, newest first.
    static func days(_ entries: [HistoryEntry]) -> [(day: Date, parts: [HistorySpan])] {
        let calendar = Calendar.current
        var parts: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let hour = calendar.component(.hour, from: entry.at)
            let first = hour < 6 ? 0 : hour < 12 ? 6 : hour < 18 ? 12 : 18
            guard let start = calendar.date(bySettingHour: first, minute: 0, second: 0, of: entry.at) else { continue }
            parts[start, default: []].append(entry)
        }
        var days: [Date: [HistorySpan]] = [:]
        for (start, entries) in parts {
            let span = HistorySpan(start: start, end: start.addingTimeInterval(6 * 3600), entries: entries.sorted { $0.at > $1.at })
            days[calendar.startOfDay(for: start), default: []].append(span)
        }
        return days.map { (day: $0.key, parts: $0.value.sorted { $0.start > $1.start }) }.sorted { $0.day > $1.day }
    }

    /// A part's blocks of 10 minutes, newest first.
    static func blocks(_ part: HistorySpan) -> [HistorySpan] {
        var blocks: [Int: [HistoryEntry]] = [:]
        for entry in part.entries { blocks[Int(entry.at.timeIntervalSince1970) / 600, default: []].append(entry) }
        return blocks.map { key, entries in
            let start = Date(timeIntervalSince1970: Double(key) * 600)
            return HistorySpan(start: start, end: start.addingTimeInterval(600), entries: entries.sorted { $0.at > $1.at })
        }
        .sorted { $0.start > $1.start }
    }
}

// MARK: Rows

/// The icons of a span's apps. Pressing and holding one offers to leave that app out from now on.
private struct HistoryIcons: View {
    var apps: [String]
    @ObservedObject private var capture = HistoryCapture.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(apps.prefix(10), id: \.self) { app in
                AppIconView(app: app, size: 24)
                    .contextMenu {
                        Text(verbatim: HistoryNames.app(app))
                        Button("Exclude from History") { capture.exclude(app) }
                        Button("Delete This App's History", role: .destructive) { Task { await capture.clear(app: app) } }
                    }
            }
        }
    }
}

private struct HistorySpanRow: View {
    var heading: String
    var span: HistorySpan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: heading).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: span.title).font(.body.weight(.semibold)).lineLimit(2)
            if !span.summary.isEmpty {
                Text(verbatim: span.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            HistoryIcons(apps: span.apps)
        }
        .padding(.vertical, 4)
    }
}

// MARK: The page

struct HistoryPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var days: [(day: Date, parts: [HistorySpan])] = []
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var asking = false
    @State private var clearing = false
    @ObservedObject private var lock = HistoryLock.shared

    var body: some View {
        List {
            Section {
                Toggle("iPhone History", isOn: Binding(get: { capture.enabled }, set: { on in
                    if on { asking = true } else { capture.enabled = false }
                }))
                if capture.enabled {
                    LabeledContent("Status") { Text(LocalizedStringKey(HistoryNames.status(capture.status))) }
                    if capture.isPaused {
                        Button("Resume") { capture.resume() }
                    } else {
                        Menu("Pause") {
                            Button("For an Hour") { capture.pause(until: Date().addingTimeInterval(3600)) }
                            Button("Until Tomorrow") {
                                capture.pause(until: Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)))
                            }
                            Button("Until I Turn It On") { capture.pause(until: .distantFuture) }
                        }
                    }
                    Toggle("Show Indicator", isOn: $capture.showIndicator)
                }
            } footer: {
                Text("Poki reads the text of the app in front every few seconds and keeps it on this iPhone. It takes no screenshots, and password fields are left out. Nothing is sent anywhere. Turning the local connection off stops it completely.")
            }
            if capture.enabled {
                Section {
                    NavigationLink { HistoryPermissionsPage().settingsPage() } label: {
                        LabeledContent("Permissions") {
                            Text(LocalizedStringKey(capture.listMode == .exclude ? "Exclude These Apps" : "Include Only These Apps"))
                        }
                    }
                    NavigationLink { HistoryTimesPage().settingsPage() } label: {
                        LabeledContent("Access Times") { Text(LocalizedStringKey(capture.scheduleOn ? "On" : "Always")) }
                    }
                    Picker("Keep History For", selection: $capture.retentionDays) {
                        Text("1 Day").tag(1)
                        Text("3 Days").tag(3)
                        Text("1 Week").tag(7)
                    }
                    Stepper(value: $capture.seconds, in: 2...60) {
                        LabeledContent("Seconds Between Reads") { Text(verbatim: "\(capture.seconds)").monospacedDigit() }
                    }
                    NavigationLink { HistoryGate { HistoryRecordPage().settingsPage() } } label: { Text("Observing Record") }
                    LabeledContent("Storage Used") {
                        Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))")
                    }
                    LabeledContent("Reads Kept") { Text(verbatim: "\(size.entries)").monospacedDigit() }
                }
            }
            if !days.isEmpty || capture.enabled {
                Section {
                    Button("Clear History", role: .destructive) { clearing = true }.disabled(days.isEmpty)
                }
            }
            // The timeline and the reads in it open only after Face ID, Touch ID or Poki's PIN.
            if !lock.unlocked {
                if !days.isEmpty || capture.enabled { HistoryUnlockSections() }
            } else {
                Section {
                    NavigationLink { HistoryGate { HistoryLockSettings().settingsPage() } } label: { Text("History Lock") }
                }
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.parts) { part in
                            NavigationLink { HistoryGate { HistoryPartPage(part: part).settingsPage() } } label: {
                                HistorySpanRow(heading: AppLocalization.bundle.localizedString(forKey: HistoryNames.part(Calendar.current.component(.hour, from: part.start)), value: nil, table: nil), span: part)
                            }
                        }
                    } header: {
                        Text(verbatim: day.day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(AppLocalization.locale)))
                    }
                }
                if days.isEmpty, capture.enabled {
                    Section {
                        Text("Nothing is kept yet. Use the iPhone as usual and come back.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.text("iPhone History"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: capture.changes) { await load() }
        .alert("Turn On iPhone History", isPresented: $asking) {
            Button("Turn On") { capture.enabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Poki will read the text on screen in the apps you use and keep it on this iPhone only. You can pause it, leave apps out, set access times and clear the history at any time.")
        }
        .confirmationDialog("Clear History", isPresented: $clearing, titleVisibility: .visible) {
            Button("Last 10 Minutes", role: .destructive) { Task { await capture.clear(last: 600) } }
            Button("Last Hour", role: .destructive) { Task { await capture.clear(last: 3600) } }
            Button("Last Day", role: .destructive) { Task { await capture.clear(last: 86_400) } }
            Button("Everything", role: .destructive) { Task { await capture.clearEverything() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        let entries = await HistoryStore.shared.recent()
        days = HistoryNames.days(entries)
        size = await HistoryStore.shared.size()
    }
}

/// A part of a day: its blocks of 10 minutes.
private struct HistoryPartPage: View {
    var part: HistorySpan

    var body: some View {
        let blocks = HistoryNames.blocks(part)
        List {
            ForEach(blocks) { block in
                NavigationLink { HistoryGate { HistoryBlockPage(start: block.start, end: block.end).settingsPage() } } label: {
                    HistorySpanRow(heading: block.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)), span: block)
                }
            }
        }
        .navigationTitle(part.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLocalization.locale)))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A block of 10 minutes: the reads kept in it, by app, with delete on each.
private struct HistoryBlockPage: View {
    var start: Date
    var end: Date
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var entries: [HistoryEntry] = []
    @Environment(\.dismiss) private var dismiss

    private var apps: [String] {
        var order: [String] = []
        for entry in entries where !order.contains(entry.app) { order.append(entry.app) }
        return order
    }

    var body: some View {
        List {
            ForEach(apps, id: \.self) { app in
                Section {
                    ForEach(entries.filter { $0.app == app }) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: entry.at.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if !entry.title.isEmpty { Text(verbatim: entry.title).font(.caption.weight(.semibold)).lineLimit(1) }
                            }
                            Text(verbatim: entry.text).font(.footnote).lineLimit(12).textSelection(.enabled)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                entries.removeAll { $0.id == entry.id }
                                Task { await capture.delete(entry) }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        AppIconView(app: app, size: 20)
                        Text(verbatim: HistoryNames.app(app))
                    }
                }
            }
            Section {
                Button("Delete These 10 Minutes", role: .destructive) {
                    Task {
                        await capture.delete(from: start, to: end)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)))
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = await HistoryStore.shared.entries(from: start, to: end) }
    }
}

// MARK: Privacy controls

/// Which apps are read: every app but the ones listed, or only the ones listed.
private struct HistoryPermissionsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var seen: [String] = []
    @State private var search = ""

    private var chosen: [String] { capture.listMode == .exclude ? capture.excluded : capture.included }

    /// Apps that can be added: the ones read so far, the suggested ones, then every app Poki knows.
    private var candidates: [String] {
        var all: [String] = []
        let suggested = capture.listMode == .exclude ? HistoryCapture.suggested : []
        for app in suggested + seen + KnownApps.all.map(\.id) where !all.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            all.append(app)
        }
        let open = all.filter { app in !chosen.contains { $0.caseInsensitiveCompare(app) == .orderedSame } }
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return open }
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
                        Text(verbatim: HistoryNames.app(app))
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
                            Text(verbatim: HistoryNames.app(app)).foregroundStyle(Color(.label))
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

/// A weekly schedule. Outside it nothing is read.
private struct HistoryTimesPage: View {
    @ObservedObject private var capture = HistoryCapture.shared

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        List {
            Section {
                Toggle("Read Only at Set Times", isOn: $capture.scheduleOn)
            } footer: {
                Text("Outside these times nothing is read.")
            }
            if capture.scheduleOn {
                Section {
                    DatePicker("From", selection: time($capture.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: time($capture.endMinute), displayedComponents: .hourAndMinute)
                }
                Section {
                    let symbols = Calendar.current.weekdaySymbols
                    ForEach(1...7, id: \.self) { day in
                        Toggle(isOn: Binding(get: { capture.weekdays.contains(day) }, set: { on in
                            if on { capture.weekdays = (capture.weekdays + [day]).sorted() } else { capture.weekdays.removeAll { $0 == day } }
                        })) {
                            Text(verbatim: symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)")
                        }
                    }
                } header: {
                    Text("Days")
                }
            }
        }
        .navigationTitle(AppLocalization.text("Access Times"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// When reading was on, paused, blocked or left an app out.
private struct HistoryRecordPage: View {
    @State private var records: [HistoryRecord] = []

    private func detail(_ record: HistoryRecord) -> String {
        switch record.kind {
        case "leftOut", "clearedApp": HistoryNames.app(record.detail)
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
