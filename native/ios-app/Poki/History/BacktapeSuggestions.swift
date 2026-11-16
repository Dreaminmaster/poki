import Foundation

/// The handling layer between Backtape and the home page's pills (the owner, 2026-11-15: surface
/// recent suggestions, only good ones, relevant and not invasive, on the device). The on-device model
/// proposes follow-ups from the last hours of the tape; this layer decides which of them, if any, may
/// be shown. A pill is seen without unlocking Backtape, so the layer is strict: better none than a
/// poor or a private one.
@MainActor
final class BacktapeSuggestions {
    static let shared = BacktapeSuggestions()

    /// At most this many join the pills.
    static let shown = 2
    private static let every: TimeInterval = 30 * 60
    private static let life: TimeInterval = 6 * 3600
    private static let window: TimeInterval = 3 * 3600

    private var last = Date.distantPast
    private var running = false
    private var kept: [(pill: HomeShortcut, at: Date)] = []

    /// Called when the home page shows. Looks again at most every half hour.
    func refresh() async {
        let capture = HistoryCapture.shared
        guard capture.enabled, capture.suggests else {
            kept = []
            publish()
            return
        }
        guard !running, BacktapeWriter.available, Date().timeIntervalSince(last) > Self.every else {
            publish()
            return
        }
        running = true
        defer { running = false }
        last = Date()
        let entries = await HistoryStore.shared.entries(from: Date().addingTimeInterval(-Self.window), to: Date())
            .filter { capture.keeps($0.app) && BacktapeApps.service($0.app) == nil }
        // Too little on the tape to know what the owner is in the middle of.
        guard entries.count >= 6 else {
            publish()
            return
        }
        let take = min(entries.count, 14)
        var text = ""
        for index in 0..<take {
            let entry = entries[index * entries.count / take]
            let time = entry.at.formatted(date: .omitted, time: .shortened)
            text += "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text.prefix(170))\n\n"
        }
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
        let instructions = """
        You read what was on a person's iPhone screen in the last hours and propose things an \
        assistant that can operate the iPhone's apps could do next for them. Propose only a follow-up \
        that clearly continues something they were doing and would save them effort. If nothing is \
        clearly useful, answer with the single word NONE. At most 3 lines, each exactly as \
        APP NAME | action, with the app's name as shown and the action in \(language), at most 8 \
        words, starting with a verb. Never propose sending, replying to or calling anyone. Never \
        mention people's names, message text, money, health, passwords, codes or anything personal.
        """
        guard let answer = await BacktapeWriter.ask(text, instructions: instructions) else {
            publish()
            return
        }
        let pills = Self.handle(answer, entries: entries, existing: HomeShortcutStore.shared.shortcuts)
        AppLog.shared.add("history", "suggestions: \(pills.count) kept")
        kept = pills.map { ($0, Date()) }
        publish()
    }

    private func publish() {
        kept.removeAll { Date().timeIntervalSince($0.at) > Self.life }
        HomeShortcutStore.shared.suggest(kept.map(\.pill))
    }

    /// What may be shown of the model's answer. A line passes only when it names an app the owner
    /// really used in the window (and has not left out of Backtape), its action is short and plain,
    /// nothing in it is private by the pills' own rule, and no pill already says the same.
    static func handle(_ answer: String, entries: [HistoryEntry], existing: [HomeShortcut]) -> [HomeShortcut] {
        let used = Set(entries.compactMap { AppIconStore.bundleID($0.app)?.lowercased() })
        var out: [HomeShortcut] = []
        for raw in answer.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. ").union(.whitespaces))
            if line.uppercased() == "NONE" { return [] }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let app = ShortcutApp.named(parts[0]) else { continue }
            guard used.contains(app.id.lowercased()), !HistoryCapture.isPoki(app.id), HistoryCapture.shared.keeps(app.id) else { continue }
            let action = parts[1].trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard (4...48).contains(action.count), !action.contains("\n"), !HomeShortcuts.isPrivate(action) else { continue }
            let prompt = CapsuleText.prefill(app: app.name, sentence: action)
            let key = HomeShortcuts.normalize(prompt)
            guard !key.isEmpty, !(existing + out).contains(where: { HomeShortcuts.similar($0.key, key) }) else { continue }
            out.append(HomeShortcut(key: key, app: app.id, appName: app.name, text: action, prompt: prompt))
            if out.count == shown { break }
        }
        return out
    }
}
