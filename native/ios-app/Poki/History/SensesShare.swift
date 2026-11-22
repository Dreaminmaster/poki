import Foundation

/// What one answer from Screen History holds, in the shape the chat's card shows it (the owner,
/// 2026-11-21: the card should show useful structured info, with the apps' icons, not a paragraph):
/// the answer of the model on this iPhone, the apps it came from with when and how long, and the
/// post, video or page the question was about when it found one. `text` is what goes to Poki's
/// model, so the card shows exactly what was shared.
struct SensesShare: Codable, Equatable {
    struct Use: Codable, Equatable {
        var app: String
        var from: Date
        var to: Date
        var minutes: Int
    }

    struct Item: Codable, Equatable {
        var app: String
        var title: String
    }

    var answer: String
    var apps: [Use]
    var item: Item?

    static let maxApps = 4
    /// Reads of one app further apart than this are two visits, and the time between is not counted.
    private static let visitGap: TimeInterval = 5 * 60

    /// The answer, then one line for the apps and one for the item, in plain English for the model.
    var text: String {
        var lines = [answer]
        if !apps.isEmpty {
            lines.append("Apps: " + apps.map { use in
                let when = use.to.timeIntervalSince(use.from) < 60 ? "at \(Self.english(use.from))" : "\(Self.english(use.from)) to \(Self.english(use.to))"
                return "\(HistoryAppNames.name(use.app)) \(when), about \(use.minutes) min"
            }
                .joined(separator: "; "))
        }
        if let item { lines.append("Item: \(HistoryAppNames.name(item.app)) | \(item.title)") }
        return lines.joined(separator: "\n")
    }

    private static func english(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
            .locale(Locale(identifier: "en_US")))
    }

    /// The model's reply read into an answer, an item, and the apps of `entries` the answer is
    /// about. Nil when nothing is left of it: the model said NONE, or only that. A NONE on its own
    /// line, or ending the answer after a sentence (the model saying there is nothing more), is taken
    /// out; a NONE inside a title or a sentence ("NONE left to lose") stays.
    static func parse(_ raw: String, entries: [HistoryEntry]) -> SensesShare? {
        var kept: [String] = []
        var itemLine: String?
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ").union(.whitespaces))
            if trimmed.uppercased().hasPrefix("ITEM:") || trimmed.uppercased().hasPrefix("ITEM：") {
                itemLine = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if !trimmed.isEmpty, !isSentinel(trimmed) {
                kept.append(trimmed)
            }
        }
        let answer = String(clean(kept.joined(separator: " ")).prefix(700))
        guard !answer.isEmpty else { return nil }
        let found = itemLine.flatMap { item($0, entries: entries) }
        return SensesShare(answer: answer, apps: uses(entries, about: answer, item: found), item: found)
    }

    /// A line that is only the sentinel.
    static func isSentinel(_ line: String) -> Bool {
        line.range(of: #"^NONE[.。!！]?$"#, options: .regularExpression) != nil
    }

    /// Without a trailing sentinel NONE (after the answer's last sentence) and the space it leaves.
    static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: #"(?<=[.!?。！？])\s*NONE[.。!！]?$"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The apps the answer's evidence came from, in the order they were first used: the item's app
    /// and the apps the answer names. When neither names one, the apps whose own screen text shares
    /// the most words with the answer. Never apps that were merely used around the same time (review
    /// of #627: a Reddit answer listed Spotify and Notes because they were used longest).
    static func uses(_ entries: [HistoryEntry], about answer: String, item: Item? = nil) -> [Use] {
        var byApp: [String: [HistoryEntry]] = [:]
        var order: [String] = []
        for entry in entries.sorted(by: { $0.at < $1.at }) where !entry.app.isEmpty && !HistoryCapture.isPoki(entry.app) {
            let key = entry.app.lowercased()
            if byApp[key] == nil { order.append(entry.app) }
            byApp[key, default: []].append(entry)
        }
        func use(_ app: String) -> Use? {
            let times = (byApp[app.lowercased()] ?? []).map(\.at)
            guard let first = times.first, let last = times.last else { return nil }
            var seconds: TimeInterval = 0
            for (a, b) in zip(times, times.dropFirst()) where b.timeIntervalSince(a) < visitGap { seconds += b.timeIntervalSince(a) }
            return Use(app: app, from: first, to: last, minutes: max(1, Int((seconds / 60).rounded())))
        }
        let low = answer.lowercased()
        var chosen = order.filter { app in
            app.lowercased() == item?.app.lowercased() || names(app).contains { mentions(low, $0) }
        }
        if chosen.isEmpty {
            let words = Set(SensesContext.terms(answer))
            let scores = order.map { app -> (String, Int) in
                let seen = (byApp[app.lowercased()] ?? []).map { ($0.title + " " + $0.text).lowercased() }.joined(separator: " ")
                return (app, words.filter { seen.contains($0) }.count)
            }
            if let best = scores.map(\.1).max(), best > 0 {
                chosen = scores.filter { $0.1 == best }.map(\.0)
            }
        }
        return Array(chosen.compactMap(use).sorted { $0.from < $1.from }.prefix(maxApps))
    }

    /// An app's display name and the last part of its id, lowercased, as an answer may name it.
    private static func names(_ app: String) -> [String] {
        var out = [HistoryAppNames.name(app).lowercased()]
        if let last = app.split(separator: ".").last, last.count >= 3 { out.append(last.lowercased()) }
        return out.filter { $0.count >= 1 }
    }

    /// Whether `text` names `name`: as a whole word for a Latin name ("X" is not every x), anywhere for
    /// a Chinese or Japanese one.
    static func mentions(_ text: String, _ name: String) -> Bool {
        guard name.unicodeScalars.allSatisfy(\.isASCII) else { return text.contains(name) }
        let pattern = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: name) + "(?![a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// "APP NAME | title" when the app is one the owner used in these reads and the title is a title.
    private static func item(_ line: String, entries: [HistoryEntry]) -> Item? {
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let title = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」《》").union(.whitespaces))
        guard (2...120).contains(title.count), !isSentinel(title) else { return nil }
        let name = parts[0].lowercased()
        let candidates = entries.map(\.app)
        guard let app = candidates.first(where: { names($0).contains(name) }) else { return nil }
        return Item(app: app, title: title)
    }
}
