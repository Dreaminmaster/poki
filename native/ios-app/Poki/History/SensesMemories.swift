import Combine
import Foundation
import PokiCore

/// What Senses (Screen History) may be used for, beyond the page itself (the owner, 2026-11-20:
/// collected senses should make provisional memories, personal home pills, and context for the Poki
/// the owner chats with). All three are on while Screen History is on; each can be turned off. None
/// of them sends anything off the iPhone by itself.
@MainActor
final class SensesUse: ObservableObject {
    static let shared = SensesUse()

    /// Provisional memories about the owner's habits and interests (SensesMemories).
    @Published var learnHabits: Bool {
        didSet {
            UserDefaults.standard.set(learnHabits, forKey: "senses.learnHabits")
            if !learnHabits { SensesMemories.shared.forgetAll() }
        }
    }
    /// Pills on the home page from habits and the recent tape (SensesSuggestions).
    @Published var suggests: Bool {
        didSet {
            UserDefaults.standard.set(suggests, forKey: "senses.suggests")
            if !suggests { SensesSuggestions.shared.clear() }
        }
    }
    /// Poki's chat may ask Senses about the owner (SensesContext).
    @Published var agentAsks: Bool { didSet { UserDefaults.standard.set(agentAsks, forKey: "senses.agentAsks") } }
    /// Which model writes insights (SensesModel). On this iPhone unless the owner picks their chat model.
    @Published var insightModel: SensesInsightModel { didSet { UserDefaults.standard.set(insightModel.rawValue, forKey: "senses.insightModel") } }

    private init() {
        let defaults = UserDefaults.standard
        learnHabits = defaults.object(forKey: "senses.learnHabits") as? Bool ?? true
        suggests = defaults.object(forKey: "senses.suggests") as? Bool ?? true
        agentAsks = defaults.object(forKey: "senses.agentAsks") as? Bool ?? true
        insightModel = defaults.string(forKey: "senses.insightModel").flatMap(SensesInsightModel.init(rawValue:)) ?? .onDevice
    }

    var learning: Bool { HistoryCapture.shared.enabled && learnHabits }
    var suggesting: Bool { HistoryCapture.shared.enabled && suggests }
    var asking: Bool { HistoryCapture.shared.enabled && agentAsks }
}

/// An interest or something ongoing the model on this iPhone read from the Senses summaries
/// ("planning a trip to Tokyo"). Never sent anywhere without the gate in SensesContext.
struct SensesTopic: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var evidence: String
    var learnedAt: Date
}

/// One provisional memory as the Memory page lists it.
struct SensesMemory: Identifiable, Equatable {
    enum Source: Equatable { case habit(SensesHabit), topic(SensesTopic) }
    var id: String
    var text: String
    var detail: String
    var app: String?
    var source: Source
}

/// Provisional memories from Senses, made on this iPhone (the owner, 2026-11-20: "collected senses
/// shall generate provisional memories for usage and habits on device, such as our previous work on
/// user's default app preferences").
///
/// Habits are counted from which app was in front and when (PokiCore `SensesHabits`), with no model
/// and no screen text: the usual app for each kind of thing, apps used at one time of day, apps used
/// almost every day. Interests come from the Senses summaries, read at most twice a day by the
/// insight model the owner chose (SensesModel: Apple's on-device model unless they picked their chat
/// model); with neither available there are none. Everything is kept in Screen
/// History's own folder (complete file protection, no backup), never exported, and is not a note:
/// the owner can forget each one, or save one as a note in their own name.
///
/// Work happens only while Poki is open (the home page, the Memory page, a chat question), never in
/// the background, so it adds nothing to the cost of collecting.
@MainActor
final class SensesMemories: ObservableObject {
    static let shared = SensesMemories()

    @Published private(set) var habits: [SensesHabit] = []
    @Published private(set) var topics: [SensesTopic] = []

    private struct Saved: Codable {
        var topics: [SensesTopic] = []
        var topicsAt: Date?
        /// Forgotten memories, by id, and when: they stay away for `forgetFor`.
        var forgotten: [String: Date] = [:]
        /// Reads before this never count again (Clear History, Everything, or learning turned off).
        var floor: Date?
    }

    private var saved = Saved()
    private var countedAt = Date.distantPast
    private var learningTopics = false
    private static let countEvery: TimeInterval = 15 * 60
    private static let topicsEvery: TimeInterval = 12 * 3600
    private static let forgetFor: TimeInterval = 30 * 86_400
    private let file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("History", isDirectory: true).appendingPathComponent("senses-memories.json")

    private init() { load() }

    // MARK: Keeping

    private func load() {
        guard let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        saved = read
        topics = read.topics.filter { !isForgotten($0.id) }
    }

    private func store() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    private func isForgotten(_ id: String, now: Date = Date()) -> Bool {
        saved.forgotten[id].map { now.timeIntervalSince($0) < Self.forgetFor } ?? false
    }

    // MARK: Working them out

    /// Counts habits again when it has been a while (or `force`), and asks the model about interests
    /// when it is due. Learning off or Screen History off: everything is forgotten.
    func refresh(force: Bool = false) async {
        guard SensesUse.shared.learning else {
            if !habits.isEmpty || !topics.isEmpty { forgetAll() }
            return
        }
        // The file is unreadable while the iPhone is locked; nothing is counted then.
        let now = Date()
        if force || now.timeIntervalSince(countedAt) > Self.countEvery {
            countedAt = now
            await count(now: now)
        }
        if SensesModel.available, !learningTopics, now.timeIntervalSince(saved.topicsAt ?? .distantPast) > Self.topicsEvery {
            await learnTopics(now: now)
        }
    }

    private func count(now: Date) async {
        let capture = HistoryCapture.shared
        let since = max(now.addingTimeInterval(-SensesHabits.twoWeeks), saved.floor ?? .distantPast)
        let sightings = await HistoryStore.shared.sightings(since: since)
        // Poki's own steps and outside agents' steps, from the Activity Log: an app an agent worked in
        // is not the owner's use of it.
        let log = ActionLog.shared
        log.load()
        let spans = log.entries.compactMap { entry -> SensesAgentSpan? in
            guard entry.kind == nil, entry.at >= since, let app = entry.app, !app.isEmpty else { return nil }
            return SensesAgentSpan(app: app, from: entry.at.addingTimeInterval(-5), to: entry.at)
        }
        let uses = SensesHabits.uses(sightings, agentSpans: spans, floor: saved.floor ?? .distantPast, now: now) { app in
            capture.keeps(app) && !HistoryCapture.isPoki(app) && !HistoryAppNames.isProcess(app) && !HistoryCapture.isWeb(app)
        }
        guard SensesUse.shared.learning else { return }
        habits = SensesHabits.habits(from: uses, now: now).filter { !isForgotten($0.id, now: now) }
    }

    /// Interests and ongoing things, from the summaries of the past three days, by the model on this
    /// iPhone. Anything private by the pills' own rule is dropped.
    private func learnTopics(now: Date) async {
        learningTopics = true
        defer { learningTopics = false }
        let notes = await HistoryStore.shared.notes(from: now.addingTimeInterval(-3 * 86_400), to: now)
        saved.topicsAt = now
        guard notes.count >= 4 else {
            store()
            return
        }
        let listed = Array(notes.suffix(40))
        let room = max(60, 3000 / listed.count - 30)
        var text = ""
        for row in listed {
            let time = Date(timeIntervalSince1970: row.start.rounded(.down)).formatted(date: .abbreviated, time: .shortened)
            text += "[\(time)] \(row.note.title). \(row.note.body.prefix(room))\n"
        }
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
        let instructions = """
        Below are summaries of what a person did on their iPhone over the past days. Name up to 3 \
        lasting interests or ongoing things they keep coming back to, such as a trip they are \
        planning, a hobby, or a subject they keep reading about. Only what shows up on more than one \
        day. Leave out health, money, other people, messages, relationships, religion, politics and \
        anything private. Write in \(language). Each line exactly as: what it is, at most 8 words, \
        addressing the person as "you" | what you saw, at most 12 words. If nothing clearly recurs, \
        reply with the single word NONE.
        """
        guard let answer = await SensesModel.ask(text, instructions: instructions) else {
            store()
            return
        }
        // Switched off while the model answered: nothing is kept.
        guard SensesUse.shared.learning else { return }
        var found: [SensesTopic] = []
        for raw in answer.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. ").union(.whitespaces))
            if line.uppercased() == "NONE" { break }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let what = parts.first, (4...80).contains(what.count), !HomeShortcuts.isPrivate(line) else { continue }
            let id = "topic." + HomeShortcuts.normalize(what)
            guard id.count > 6, !isForgotten(id, now: now), !found.contains(where: { $0.id == id }) else { continue }
            let kept = topics.first { HomeShortcuts.similar($0.id, id) }
            found.append(SensesTopic(id: kept?.id ?? id, text: what, evidence: parts.count > 1 ? String(parts[1].prefix(120)) : "",
                                     learnedAt: kept?.learnedAt ?? now))
            if found.count == 3 { break }
        }
        topics = found
        saved.topics = found
        store()
        AppLog.shared.add("history", "senses memories: \(found.count) interests")
    }

    // MARK: The owner's controls

    /// Gone, and not made again for a month.
    func forget(_ id: String) {
        saved.forgotten[id] = Date()
        saved.forgotten = saved.forgotten.filter { Date().timeIntervalSince($0.value) < Self.forgetFor }
        habits.removeAll { $0.id == id }
        topics.removeAll { $0.id == id }
        saved.topics = topics
        store()
    }

    /// The owner keeps one as their own note, which every agent then sees like their other notes.
    func saveAsNote(_ memory: SensesMemory) {
        _ = RoutineStore.shared.remember(memory.text, by: AppLocalization.text("Screen History"))
        forget(memory.id)
    }

    /// Everything learned so far is forgotten, and what is kept now never counts again.
    func forgetAll() {
        habits = []
        topics = []
        saved = Saved(floor: Date())
        countedAt = .distantPast
        store()
    }

    /// History was deleted: interests go (they may rest on it), and habits are counted again from
    /// what is left. Everything deleted: as forgetAll.
    func historyCleared(everything: Bool) {
        if everything { forgetAll(); return }
        topics = []
        saved.topics = []
        saved.topicsAt = Date()
        countedAt = .distantPast
        store()
        Task { await refresh(force: true) }
    }

    // MARK: Words

    /// Every provisional memory, habits first, in the owner's language.
    var memories: [SensesMemory] {
        habits.map { habit in
            SensesMemory(id: habit.id, text: Self.text(habit), detail: Self.detail(habit), app: habit.app, source: .habit(habit))
        } + topics.map { SensesMemory(id: $0.id, text: $0.text, detail: $0.evidence, app: nil, source: .topic($0)) }
    }

    static func text(_ habit: SensesHabit) -> String {
        let name = HistoryNames.app(habit.app)
        switch habit.kind {
        case .usual(let category):
            return String(format: usualFormat(category), name)
        case .routine(let part):
            switch part {
            case .morning: return String(format: AppLocalization.text("You often use %@ in the morning."), name)
            case .afternoon: return String(format: AppLocalization.text("You often use %@ in the afternoon."), name)
            case .evening: return String(format: AppLocalization.text("You often use %@ in the evening."), name)
            case .night: return String(format: AppLocalization.text("You often use %@ at night."), name)
            }
        case .daily:
            return String(format: AppLocalization.text("You use %@ almost every day."), name)
        }
    }

    private static func usualFormat(_ category: SensesCategory) -> String {
        switch category {
        case .music: AppLocalization.text("Your usual music app is %@.")
        case .maps: AppLocalization.text("Your usual maps app is %@.")
        case .browser: AppLocalization.text("Your usual browser is %@.")
        case .video: AppLocalization.text("Your usual video app is %@.")
        case .ride: AppLocalization.text("Your usual ride app is %@.")
        case .food: AppLocalization.text("Your usual food delivery app is %@.")
        case .shopping: AppLocalization.text("Your usual shopping app is %@.")
        case .mail: AppLocalization.text("Your usual mail app is %@.")
        case .messaging: AppLocalization.text("Your usual messaging app is %@.")
        case .notes: AppLocalization.text("Your usual notes app is %@.")
        case .podcasts: AppLocalization.text("Your usual podcast app is %@.")
        }
    }

    static func detail(_ habit: SensesHabit) -> String {
        String(format: AppLocalization.text("%1$lld uses on %2$lld days"), habit.uses, habit.days)
    }

    // MARK: For the chat

    /// The line a task's instructions carry about the usual app for what it asks, or nil. The owner's
    /// own words come first: an app of that kind named in the request, or a note that chooses one.
    /// Only the app's name goes, and only for a task that needs it (as the usual music app did).
    func usualAppLine(for task: String) -> String? {
        guard SensesUse.shared.learning else { return nil }
        let notes = RoutineStore.shared.notes.map(\.text)
        guard let habit = SensesHabits.usualApp(for: task, habits: habits, names: { Self.names($0, $1) }, notes: notes),
              case .usual(let category) = habit.kind else { return nil }
        let names = KnownApps.find(habit.app).map { $0.names.joined(separator: " / ") } ?? HistoryNames.app(habit.app)
        return """
        The owner's usual \(category.rawValue) app, inferred on this iPhone from Screen History: \(names), bundle id \(habit.app) (\(habit.uses) uses on \(habit.days) days in the past week). \
        When this request needs a \(category.rawValue) app and names none, use this one: start with do {launch: "\(habit.app)"}. \
        An app the owner names in this conversation comes first, for this time only. If it is not installed, needs sign-in or cannot do it, say so and ask which app to use; do not switch on your own. \
        This is inferred, not something the owner said: do not save it as a note or a routine. When the owner says which app to use from now on, save their words with routines remember.
        """
    }

    /// Whether `text` names the app `bundleID`.
    private static func names(_ text: String, _ bundleID: String) -> Bool {
        AppIconStore.bundleIDs(namedIn: text).contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// The memories as lines the model on this iPhone reads to answer a question (SensesContext).
    var contextLines: [String] {
        habits.map { $0.line(name: HistoryNames.app($0.app)) } + topics.map { "Interest or ongoing thing: \($0.text) (\($0.evidence))" }
    }
}
