import SwiftUI

/// Every action Poki ran on this iPhone and every approval it asked for, for the owner's own record:
/// kept on this device, with no way to delete an entry from the app. Each entry names the session it
/// came from (Poki's chat or an outside agent's), so a tap opens that run. The log keeps its latest
/// `keep` entries: older ones are dropped when the file is trimmed.
@MainActor
@Observable
final class ActionLog {
    static let shared = ActionLog()
    /// How many entries stay. The file is trimmed back to this once it runs `slack` over.
    static let keep = 5000
    static let slack = 500

    struct Entry: Codable, Identifiable, Hashable {
        /// `observing`: a Screen History change from its Observing Record, made for the page and never
        /// written to the log's file. `note`: a line an agent added to its session.
        enum Kind: String, Codable { case approval, observing, note }
        var id = UUID()
        var at: Date
        var text: String
        var app: String?
        var ok: Bool
        var session: String?
        /// The outside agent that asked for it; nil for Poki's own chat.
        var caller: String? = nil
        /// nil for an action; an approval's entry says how it was answered in `detail`.
        var kind: Kind? = nil
        var detail: String? = nil
        /// Why the step needed an answer, from PokiCore's rules.
        var why: String? = nil

        /// One line of text for a copied log.
        var line: String {
            let time = at.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))
            let mark = switch kind {
            case .approval: ok ? "approval allowed" : "approval refused"
            case .observing: "observing"
            case .note: "note"
            case nil: ok ? "ok" : "failed"
            }
            let place = AppName.display(app).map { " in \($0)" } ?? ""
            let more = [detail, why.map(ActivityWords.reason)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
            return "\(time)  [\(mark)] \(ActivityWords.label(text))\(place)\(more.isEmpty ? "" : " (\(more))")"
        }
    }

    /// Entries that follow one another from the same run on the same day, newest first.
    struct Run: Identifiable, Hashable {
        var id: UUID
        var session: String?
        var caller: String?
        var entries: [Entry]
        var failed: Int { entries.filter { !$0.ok && $0.kind == nil }.count }
        var approvals: Int { entries.filter { $0.kind == .approval }.count }
    }

    private(set) var entries: [Entry] = []
    private let file: URL
    private var loaded = false

    private init() {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        file = folder.appendingPathComponent("action-log.jsonl")
    }

    func add(_ text: String, app: String?, ok: Bool, session: String?, caller: String? = nil,
             kind: Entry.Kind? = nil, detail: String? = nil, why: String? = nil) {
        load()
        let entry = Entry(at: Date(), text: text, app: app, ok: ok, session: session, caller: caller, kind: kind, detail: detail, why: why)
        entries.append(entry)
        if entries.count > Self.keep + Self.slack { trim(); return }
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        if entries.count > Self.keep + Self.slack { trim() }
    }

    /// Drops the oldest entries and writes the file again, whole.
    private func trim() {
        entries = Array(entries.suffix(Self.keep))
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line); data.append(0x0A)
        }
        try? data.write(to: file, options: .atomic)
    }

    /// The entries of one run between two moments, oldest first (a chat's task, for its details).
    func entries(session: String?, from: Date, to: Date) -> [Entry] {
        load()
        return entries.filter { $0.at >= from && $0.at <= to && (session == nil || $0.session == session) }
    }

    /// `entries` (newest first) by day, each day's entries gathered into runs.
    static func days(_ entries: [Entry]) -> [(day: Date, runs: [Run])] {
        var days: [(day: Date, runs: [Run])] = []
        let calendar = Calendar.current
        for entry in entries {
            let day = calendar.startOfDay(for: entry.at)
            if days.last?.day != day { days.append((day, [])) }
            let d = days.count - 1
            let observing = entry.kind == .observing
            if let last = days[d].runs.last, (observing && last.entries.last?.kind == .observing)
                || (!observing && last.entries.last?.kind != .observing && last.session == entry.session && last.caller == entry.caller && entry.session != nil) {
                days[d].runs[days[d].runs.count - 1].entries.append(entry)
            } else {
                days[d].runs.append(Run(id: entry.id, session: entry.session, caller: entry.caller, entries: [entry]))
            }
        }
        return days
    }
}

/// The Observing Record in the Activity Log (the owner, Nov 21 2026): simplified, so it never floods the
/// log. Only changes show: a state that repeats the one before is dropped, an app left out again within
/// half an hour adds to the line before, and so do Poki's checks before sharing within ten minutes.
enum ObservingDigest {
    static func entries(_ records: [HistoryRecord]) -> [ActionLog.Entry] {
        var out: [ActionLog.Entry] = []
        var counts: [Int] = []
        var lastState: String?
        for record in records.sorted(by: { $0.at < $1.at }) {
            let state = HistoryCapture.Status(rawValue: record.kind) != nil
            if state {
                guard record.kind != lastState else { continue }
                lastState = record.kind
            }
            let window: TimeInterval? = switch record.kind {
            case "leftOut": 1800
            case "shared", "notShared": 600
            default: nil
            }
            if let window, let i = out.lastIndex(where: { $0.text == record.kind }),
               record.at.timeIntervalSince(out[i].at) < window,
               record.kind != "leftOut" || out[i].app == record.detail {
                counts[i] += 1
                out[i].at = record.at
                continue
            }
            out.append(ActionLog.Entry(at: record.at, text: record.kind, app: record.kind == "leftOut" ? record.detail : nil,
                                       ok: record.kind != "dropped", session: nil, kind: .observing))
            counts.append(1)
        }
        for i in out.indices where counts[i] > 1 {
            out[i].detail = AppLocalization.text(LocalizedStringResource("\(counts[i]) times"))
        }
        return out
    }
}

/// Agents › Activity Log: every action and approval, newest first, by day and by run. A run opens to
/// its steps; the filters narrow it to approvals, failures or one agent; a tap opens the run's chat.
struct ActionLogView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var openSession: (String) -> Void
    private var log: ActionLog { ActionLog.shared }

    enum Show: String, CaseIterable, Identifiable {
        case all, approvals, failed, observing
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .approvals: "Approvals"
            case .failed: "Failed"
            case .observing: "Observing"
            }
        }
    }

    @State private var show = Show.all
    /// nil: everyone. "": Poki's own chat. Otherwise an outside agent's name.
    @State private var who: String?
    @State private var search = ""
    @State private var shownDays = 7
    @State private var open: Set<UUID> = []
    /// Screen History's changes, read only while it is unlocked: they name apps and questions.
    @State private var observing: [ActionLog.Entry] = []
    @ObservedObject private var lock = HistoryLock.shared
    @ObservedObject private var capture = HistoryCapture.shared

    private var filtering: Bool { show != .all || who != nil || !search.isEmpty }

    private var matching: [ActionLog.Entry] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return (log.entries + observing).sorted { $0.at > $1.at }.filter { entry in
            switch show {
            case .all: break
            case .approvals: if entry.kind != .approval { return false }
            case .failed: if entry.ok || entry.kind == .observing { return false }
            case .observing: if entry.kind != .observing { return false }
            }
            if let who, entry.kind == .observing || (entry.caller ?? "") != who { return false }
            if words.isEmpty { return true }
            return [entry.text, label(entry), entry.app, entry.detail, entry.caller].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    private var agents: [String] {
        var seen: Set<String> = []
        return log.entries.reversed().compactMap { $0.caller }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let days = ActionLog.days(matching)
        List {
            if !log.entries.isEmpty {
                Section {
                    Picker("Show", selection: $show) {
                        ForEach(Show.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            // The Observing Record's changes join the log once Screen History is open (they name apps).
            if capture.enabled || !observing.isEmpty, !lock.unlocked {
                Section {
                    Button { Task { await lock.open() } } label: {
                        SettingsRow(title: "Show Observing Changes", symbol: "eye")
                    }
                    .disabled(lock.asking || lock.unavailable)
                    .accessibilityIdentifier("activity.showObserving")
                }
            }
            if log.entries.isEmpty && observing.isEmpty {
                ContentUnavailableView("No Actions Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Every tap, swipe and keystroke Poki makes on this iPhone is listed here, whoever asked for it."))
                    .listRowBackground(Color.clear)
            } else if days.isEmpty {
                ContentUnavailableView("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No entry fits these filters."))
                    .listRowBackground(Color.clear)
            }
            ForEach(days.prefix(shownDays), id: \.day) { day, runs in
                Section(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(AppLocalization.locale))) {
                    ForEach(runs) { run in
                        // A filtered log is a plain list; otherwise a run of several steps folds into one row.
                        if filtering || run.entries.count == 1 {
                            ForEach(run.entries) { entry in line(entry, in: run) }
                        } else {
                            DisclosureGroup(isExpanded: Binding(get: { open.contains(run.id) },
                                                                set: { if $0 { open.insert(run.id) } else { open.remove(run.id) } })) {
                                ForEach(run.entries) { entry in line(entry, in: run) }
                            } label: {
                                header(run)
                            }
                            .contextMenu { menu(run) }
                        }
                    }
                }
            }
            if days.count > shownDays {
                Section {
                    Button("Show Earlier", systemImage: "clock.arrow.circlepath") { shownDays += 14 }
                }
            }
            if !log.entries.isEmpty {
                Section {} footer: {
                    Group {
                        Text("Poki keeps its latest \(ActionLog.keep) entries on this iPhone. Entries can’t be deleted by hand.")
                    }
                    .settingsFooter()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("Activity Log"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Search"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Asked By", selection: $who) {
                        Text("Everyone").tag(String?.none)
                        Text("Poki").tag(String?.some(""))
                        ForEach(agents, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filter", systemImage: who == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .onAppear { log.load() }
        .task(id: lock.unlocked) {
            observing = lock.unlocked ? ObservingDigest.entries(await HistoryStore.shared.records(limit: 2000)) : []
        }
    }

    private func title(_ run: ActionLog.Run) -> String {
        if run.entries.first?.kind == .observing { return AppLocalization.text("Screen History") }
        return run.session.flatMap { SessionStore.shared.session($0)?.name } ?? run.caller ?? "Poki"
    }

    /// The words of an entry: a step's own, or an observing change's name.
    private func label(_ entry: ActionLog.Entry) -> String {
        switch entry.kind {
        case .observing: AppLocalization.bundle.localizedString(forKey: HistoryNames.record(entry.text), value: nil, table: nil)
        case .note: entry.text
        default: ActivityWords.label(entry.text)
        }
    }

    @ViewBuilder private func menu(_ run: ActionLog.Run) -> some View {
        if let id = run.session, SessionStore.shared.session(id) != nil {
            Button("Open Chat", systemImage: "bubble.left") { openSession(id) }
        }
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = run.entries.reversed().map(\.line).joined(separator: "\n")
        }
    }

    @ViewBuilder private func line(_ entry: ActionLog.Entry, in run: ActionLog.Run) -> some View {
        // A row whose run is gone is plain text, not a disabled button: iOS fades a disabled
        // button's whole label, which left most of the log close to invisible.
        Group {
            if let id = entry.session, SessionStore.shared.session(id) != nil {
                Button { openSession(id) } label: { row(entry) }.foregroundStyle(Color(.label))
            } else {
                row(entry)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.line }
        }
    }

    @ViewBuilder private func badge(_ caller: String?, ok: Bool, approval: Bool, observing: Bool = false) -> some View {
        if observing {
            Image(systemName: "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tint.blueText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Tint.blue.opacity(0.14)))
        } else {
            plainBadge(caller, ok: ok, approval: approval)
        }
    }

    private func plainBadge(_ caller: String?, ok: Bool, approval: Bool) -> some View {
        // Who asked for it: the agent's badge, or Poki's own.
        Group {
            if let caller { CallerBadge(name: caller, size: 28) } else { PokiAvatar(size: 28) }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: approval ? (ok ? "checkmark.shield.fill" : "xmark.shield.fill") : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ok ? Color.green : Color.red)
                .background(Circle().fill(Color(.systemBackground)).padding(-1))
                .offset(x: 3, y: 3)
        }
    }

    private func header(_ run: ActionLog.Run) -> some View {
        let count = run.entries.count
        var parts = [AppLocalization.text(LocalizedStringResource("\(count) entries"))]
        if run.failed > 0 { parts.append(AppLocalization.text(LocalizedStringResource("\(run.failed) failed"))) }
        if run.approvals > 0 { parts.append(AppLocalization.text(LocalizedStringResource("\(run.approvals) approvals"))) }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            badge(run.caller, ok: run.failed == 0, approval: false, observing: run.entries.first?.kind == .observing)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title(run)).foregroundStyle(Color(.label)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Text(verbatim: parts.joined(separator: ", ")).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 4)
            if let first = run.entries.first {
                Text(first.at, style: .time).font(.allo(.footnote)).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    private func row(_ entry: ActionLog.Entry) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            badge(entry.caller, ok: entry.ok, approval: entry.kind == .approval, observing: entry.kind == .observing)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label(entry)).foregroundStyle(Color(.label)).lineLimit(typeSize.isAccessibilitySize || !entry.ok ? nil : 2)
                if let detail = entry.detail {
                    Text(verbatim: detail).font(.allo(.footnote)).foregroundStyle(entry.ok ? Color(.secondaryLabel) : Color.orange).lineLimit(typeSize.isAccessibilitySize || !entry.ok ? nil : 2)
                }
                let place = entry.kind == .observing ? entry.app.map(HistoryNames.app) : AppName.display(entry.app)
                let context = [place, entry.session.flatMap { SessionStore.shared.session($0)?.name }].compactMap { $0 }.joined(separator: ", ")
                if !context.isEmpty {
                    Text(context).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
            Spacer(minLength: 4)
            Text(entry.at, style: .time).font(.allo(.footnote)).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
        }
    }
}
