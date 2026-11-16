import SwiftUI

// Poki's own work on the timeline (the owner, 2026-11-16: the Activity Log is part of Screen History, and
// the tape says who did what). Each action Poki ran, for its own chat or for an outside agent, is an
// entry beside the owner's reads. With Screen History off these are all the page shows.

@MainActor
enum BacktapeActivity {
    /// The Activity Log's actions as entries of the tape, newest first. Approvals stay in the log.
    static func entries(from start: Date = .distantPast, to end: Date = .distantFuture) -> [HistoryEntry] {
        let log = ActionLog.shared
        log.load()
        var found: [HistoryEntry] = []
        for (index, entry) in log.entries.enumerated().reversed() where entry.kind == nil && entry.at >= start && entry.at < end {
            let label = ActivityWords.label(entry.text)
            found.append(HistoryEntry(id: -Int64(index) - 1, at: entry.at, app: entry.app ?? "", title: label, text: label, by: entry.caller ?? ""))
        }
        return found
    }

    /// Everything of one span, oldest first, with whole texts: the owner's reads while Screen History is
    /// on, and Poki's steps.
    static func whole(from start: Date, to end: Date) async -> [HistoryEntry] {
        let kept = HistoryCapture.shared.enabled ? await HistoryStore.shared.entries(from: start, to: end) : []
        let steps = entries(from: start, to: end)
        return steps.isEmpty ? kept : (kept + steps).sorted { $0.at < $1.at }
    }

    /// Who worked: Poki for its own chat, or the outside agent by its name.
    static func name(_ by: String) -> String { by.isEmpty ? "Poki" : by }
}

extension HistorySpan {
    /// Who worked on the iPhone in it besides the owner: "" for Poki, or an agent's name.
    var workers: [String] {
        var seen: [String] = []
        for entry in entries { if let by = entry.by, !seen.contains(by) { seen.append(by) } }
        return seen
    }

    /// Whether any of it is the owner's own use, read off the screen.
    var owned: Bool { entries.contains { $0.by == nil } }
}

/// A span in plain words, for where no model wrote a note: who worked in which apps.
@MainActor
enum BacktapeWords {
    static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = AppLocalization.locale
        return formatter.string(from: items) ?? items.joined(separator: " ")
    }

    private static func apps(_ entries: [HistoryEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.app.isEmpty { counts[entry.app, default: 0] += 1 }
        var names: [String] = []
        for app in counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).map(\.key) {
            let name = BacktapeApps.name(app)
            if !names.contains(name) { names.append(name) }
            if names.count == 3 { break }
        }
        return names
    }

    static func plain(_ span: HistorySpan) -> String {
        var parts: [String] = []
        for worker in span.workers {
            let used = apps(span.entries.filter { $0.by == worker })
            let who = BacktapeActivity.name(worker)
            parts.append(used.isEmpty
                ? String(format: AppLocalization.text("%@ worked on this iPhone."), who)
                : String(format: AppLocalization.text("%1$@ worked in %2$@."), who, list(used)))
        }
        let own = apps(span.entries.filter { $0.by == nil })
        if !own.isEmpty { parts.append(String(format: AppLocalization.text("You used %@."), list(own))) }
        return parts.joined(separator: " ")
    }
}

/// The mark of a time Poki or an agent worked: its face, round where the apps' icons are square.
struct BacktapeWorkerBadge: View {
    var by: String
    var size: CGFloat

    var body: some View {
        Group {
            if by.isEmpty {
                PokiAvatar(size: size)
            } else {
                CallerBadge(name: by, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(Text(verbatim: BacktapeActivity.name(by)))
    }
}

/// A summary that may still change: grey, breathing slowly.
struct BacktapePending: ViewModifier {
    var on: Bool
    @State private var low = false
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .opacity(on && low ? 0.5 : 1)
            .onAppear { start() }
            .onChange(of: on) { _, _ in start() }
    }

    private func start() {
        guard on, !still, !low else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { low = true }
    }
}

// MARK: An opened block of 10 minutes

/// What an opened row shows under its line: the whole summary, the 10 minutes as one strip, and the
/// stretches in order, each with its app, what was on screen and how long it lasted. Times are said
/// once, at the ends of the strip (the owner, 2026-11-16: not a list of times).
struct BacktapeDetail: View {
    var tile: BacktapeTile
    var note: BacktapeNote?
    var pending: Bool

    struct Part: Identifiable {
        let id: Int
        let app: String
        let by: String?
        let start: Date
        var end: Date
        var titles: [String]
        var more = 0
    }

    /// Reads that follow one another in the same app, by the same hand, as one stretch.
    static func parts(_ tile: BacktapeTile) -> [Part] {
        var parts: [Part] = []
        for entry in tile.span.entries.reversed() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = parts.last, last.by == entry.by, last.app.caseInsensitiveCompare(entry.app) == .orderedSame {
                let index = parts.count - 1
                parts[index].end = entry.at
                if !title.isEmpty, !parts[index].titles.contains(title) {
                    if parts[index].titles.count < 3 { parts[index].titles.append(title) } else { parts[index].more += 1 }
                }
            } else {
                if !parts.isEmpty { parts[parts.count - 1].end = entry.at }
                parts.append(Part(id: parts.count, app: entry.app, by: entry.by, start: entry.at, end: entry.at, titles: title.isEmpty ? [] : [title]))
            }
        }
        // The last stretch runs a few seconds past its last read, never past the block or now.
        if !parts.isEmpty {
            let index = parts.count - 1
            parts[index].end = min(tile.end, Date(), parts[index].end.addingTimeInterval(8))
        }
        return parts
    }

    private func length(_ part: Part) -> String {
        let seconds = max(1, Int(part.end.timeIntervalSince(part.start).rounded()))
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }

    private func name(_ part: Part) -> String {
        guard let by = part.by else { return BacktapeApps.name(part.app) }
        let who = BacktapeActivity.name(by)
        return part.app.isEmpty ? who : String(format: AppLocalization.text("%1$@ in %2$@"), who, BacktapeApps.name(part.app))
    }

    var body: some View {
        let parts = Self.parts(tile)
        let style = Date.FormatStyle().hour().minute().locale(AppLocalization.locale)
        VStack(alignment: .leading, spacing: 12) {
            if let note, !note.body.isEmpty {
                Text(verbatim: note.body.prefix(1).uppercased() + note.body.dropFirst())
                    .font(.footnote)
                    .foregroundStyle(pending ? Color.secondary : Color.primary)
                    .modifier(BacktapePending(on: pending))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    let total = max(1, tile.end.timeIntervalSince(tile.start))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        ForEach(parts) { part in
                            let x = part.start.timeIntervalSince(tile.start) / total * geometry.size.width
                            let width = max(3, part.end.timeIntervalSince(part.start) / total * geometry.size.width)
                            // Poki's time is the one colour on the strip.
                            Capsule()
                                .fill(part.by == nil ? Color.primary.opacity(0.34) : Color.accentColor)
                                .frame(width: min(width, max(3, geometry.size.width - x)))
                                .offset(x: x)
                        }
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(verbatim: tile.start.formatted(style))
                    Spacer()
                    Text(verbatim: tile.end.formatted(style))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            ForEach(parts) { part in
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if part.app.isEmpty, let by = part.by {
                            BacktapeWorkerBadge(by: by, size: 28)
                        } else {
                            BacktapeAppIcon(app: part.app, size: 28, order: part.id)
                                .overlay(alignment: .bottomTrailing) {
                                    if let by = part.by { BacktapeWorkerBadge(by: by, size: 15).offset(x: 4, y: 4) }
                                }
                        }
                    }
                    .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name(part)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        ForEach(part.titles, id: \.self) { title in
                            Text(verbatim: title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if part.more > 0 {
                            Text("\(part.more) more").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: length(part)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
