import Foundation
import PokiCore

/// The layer between Senses and the home page's pills (the owner, 2026-11-20: "collected senses info
/// isnt used to make the pill recommendations on the user's homepage their own"). First built for
/// Backtape on dev/iphone-history-preview (BacktapeSuggestions, 2026-11-15: only good ones, relevant
/// and not invasive, on the device).
///
/// Two kinds, at most `shown` in all:
/// - Habits for now: an app the owner opens at this time of day, or almost every day
///   (SensesMemories). Its action comes from the insight model (SensesModel) reading the titles of
///   the owner's recent screens in that app, and is plain "Open" without one.
/// - Follow-ups: the insight model reads the last hours of the tape and proposes what clearly
///   continues something the owner was doing.
///
/// A pill is seen without unlocking Screen History, so the layer is strict: better none than a poor
/// or a private one. With the insight model on this iPhone nothing leaves the phone; a pill's words
/// go to Poki's model only when the owner taps it and sends them.
@MainActor
final class SensesSuggestions {
    static let shared = SensesSuggestions()

    static let shown = 3
    private static let every: TimeInterval = 30 * 60
    private static let life: TimeInterval = 4 * 3600
    private static let window: TimeInterval = 3 * 3600
    /// Apps whose pills could say something private from their name alone.
    private static let never: Set<String> = ["com.apple.health", "com.apple.passbook", "com.apple.passwords", "com.apple.mobilephone",
                                             "com.apple.mobileaddressbook", "com.apple.findmy", "com.apple.facetime"]

    private var last = Date.distantPast
    private var running = false
    private var kept: [(pill: HomeShortcut, at: Date)] = []

    /// Called when the home page shows. Looks again at most every half hour, or when the time of day
    /// moved on.
    func refresh() async {
        guard SensesUse.shared.suggesting else {
            clear()
            return
        }
        let part = SensesPartOfDay.of(Date())
        guard !running, Date().timeIntervalSince(last) > Self.every || part != lastPart else {
            publish()
            return
        }
        running = true
        defer { running = false }
        last = Date()
        lastPart = part
        let memories = SensesMemories.shared
        await memories.refresh()
        var pills = await habitPills(memories.habits, part: part)
        pills += await followUps(existing: HomeShortcutStore.shared.shortcuts + pills, room: Self.shown - pills.count)
        AppLog.shared.add("history", "suggestions: \(pills.count) kept")
        kept = pills.prefix(Self.shown).map { ($0, Date()) }
        publish()
    }

    private var lastPart: SensesPartOfDay?

    func clear() {
        kept = []
        HomeShortcutStore.shared.suggest([])
    }

    private func publish() {
        kept.removeAll { Date().timeIntervalSince($0.at) > Self.life }
        HomeShortcutStore.shared.suggest(kept.map(\.pill))
    }

    // MARK: Habits for now

    /// Apps the owner uses at this time of day, then apps used almost every day, up to two.
    private func habitPills(_ habits: [SensesHabit], part: SensesPartOfDay) async -> [HomeShortcut] {
        let capture = HistoryCapture.shared
        let fitting = habits.filter { habit in
            switch habit.kind {
            case .routine(let at): at == part
            case .daily: true
            case .usual: false
            }
        }.filter { habit in
            !Self.never.contains(habit.app.lowercased()) && capture.keeps(habit.app)
                && SensesCategory.of(habit.app).map { $0 == .messaging || $0 == .mail } != true
        }
        var apps: [(id: String, name: String)] = []
        for habit in fitting {
            guard let app = ShortcutApp.named(habit.app), !apps.contains(where: { $0.id == app.id }) else { continue }
            apps.append(app)
            if apps.count == 2 { break }
        }
        guard !apps.isEmpty else { return [] }
        let actions = await habitActions(apps)
        var out: [HomeShortcut] = []
        for app in apps {
            let action = actions[app.id] ?? AppLocalization.text("Open")
            let prompt = actions[app.id].map { CapsuleText.prefill(app: app.name, sentence: $0) }
                ?? String(format: AppLocalization.text("Open %@"), app.name)
            guard !HomeShortcuts.isPrivate(prompt) else { continue }
            let key = HomeShortcuts.normalize(prompt)
            guard !key.isEmpty else { continue }
            out.append(HomeShortcut(key: key, app: app.id, appName: app.name, text: action, prompt: prompt))
        }
        return out
    }

    /// For each app, what the owner usually does in it, from the titles of their recent screens
    /// there (no screen text), by the model on this iPhone. Missing for an app the model has nothing
    /// clear for, and for all without Apple Intelligence.
    private func habitActions(_ apps: [(id: String, name: String)]) async -> [String: String] {
        guard SensesModel.available else { return [:] }
        let entries = await HistoryStore.shared.entries(from: Date().addingTimeInterval(-SensesHabits.week), to: Date())
        var text = ""
        for app in apps {
            var titles: [String] = []
            for entry in entries.reversed() where entry.app.caseInsensitiveCompare(app.id) == .orderedSame && !entry.title.isEmpty {
                if !titles.contains(entry.title) { titles.append(String(entry.title.prefix(60))) }
                if titles.count == 12 { break }
            }
            guard !titles.isEmpty else { continue }
            text += "\(app.name): \(titles.joined(separator: "; "))\n"
        }
        guard !text.isEmpty else { return [:] }
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
        let instructions = """
        Each line names an app a person opens at this time of day and the titles of screens they \
        recently saw in it. For each app, give the one thing they most often do there, as an action \
        an assistant could do for them in that app, in \(language), at most 6 words, starting with a \
        verb. If the titles do not show one clear thing, leave that app out. Never mention people's \
        names, messages, money, health, passwords, codes or anything personal. One line per app, \
        exactly as APP NAME | action. If none is clear, reply NONE.
        """
        guard let answer = await SensesModel.ask(text, instructions: instructions) else { return [:] }
        var out: [String: String] = [:]
        for raw in answer.split(separator: "\n") {
            let parts = raw.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let app = apps.first(where: { $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame }) else { continue }
            let action = parts[1].trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard (3...40).contains(action.count), !HomeShortcuts.isPrivate(action) else { continue }
            out[app.id] = action
        }
        return out
    }

    // MARK: Follow-ups

    private func followUps(existing: [HomeShortcut], room: Int) async -> [HomeShortcut] {
        guard room > 0, SensesModel.available else { return [] }
        let capture = HistoryCapture.shared
        let entries = await HistoryStore.shared.entries(from: Date().addingTimeInterval(-Self.window), to: Date())
            .filter { capture.keeps($0.app) && BacktapeApps.service($0.app) == nil && !$0.text.isEmpty }
        // Too little on the tape to know what the owner is in the middle of.
        guard entries.count >= 6 else { return [] }
        let model = SensesModel.choice
        let text = Self.followUpPrompt(from: entries, using: model)
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
        guard let answer = await SensesModel.ask(text, instructions: instructions, using: model) else { return [] }
        return Array(Self.handle(answer, entries: entries, existing: existing).prefix(room))
    }

    static func followUpPrompt(from entries: [HistoryEntry], using model: SensesInsightModel) -> String {
        let take = min(entries.count, 14)
        return (0..<take).map { index in
            let entry = entries[index * entries.count / take]
            let time = entry.at.formatted(date: .omitted, time: .shortened)
            let title = "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n"
            return title + (model == .onDevice ? "\(entry.text.prefix(170))\n\n" : "\n")
        }.joined()
    }

    /// What may be shown of the model's answer. A line passes only when it names an app the owner
    /// really used in the window (and has not left out of Screen History), its action is short and
    /// plain, nothing in it is private by the pills' own rule, and no pill already says the same.
    static func handle(_ answer: String, entries: [HistoryEntry], existing: [HomeShortcut]) -> [HomeShortcut] {
        let used = Set(entries.compactMap { AppIconStore.bundleID($0.app)?.lowercased() })
        var out: [HomeShortcut] = []
        for raw in answer.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. ").union(.whitespaces))
            if line.uppercased() == "NONE" { return [] }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let app = ShortcutApp.named(parts[0]) else { continue }
            guard used.contains(app.id.lowercased()), !HistoryCapture.isPoki(app.id), HistoryCapture.shared.keeps(app.id),
                  !never.contains(app.id.lowercased()) else { continue }
            let action = parts[1].trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard (4...48).contains(action.count), !action.contains("\n"), !HomeShortcuts.isPrivate(action) else { continue }
            let prompt = CapsuleText.prefill(app: app.name, sentence: action)
            let key = HomeShortcuts.normalize(prompt)
            guard !key.isEmpty, !(existing + out).contains(where: { HomeShortcuts.similar($0.key, key) }) else { continue }
            out.append(HomeShortcut(key: key, app: app.id, appName: app.name, text: action, prompt: prompt))
            if out.count == 2 { break }
        }
        return out
    }
}
