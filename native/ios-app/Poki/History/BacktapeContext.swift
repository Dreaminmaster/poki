import Foundation
import PokiCore

/// Poki's own agent asking Backtape about the owner (the owner, 2026-11-15: first support for the
/// main agent to request personal context from the local model, and an approval run by the model on
/// this iPhone decides whether the owner must be asked before a summary goes to the remote model).
///
/// The agent sends a question. The model on this iPhone answers it from the tape in a few sentences,
/// then judges its own answer: plainly harmless and needed for the task, or the owner's to decide.
/// Only that answer can leave the phone, never the screen text, and only after one of the two said
/// yes. Anything unclear goes to the owner.
enum BacktapeContext {
    static let name = "personal_context"

    static let spec = ToolSpec(
        name: name,
        description: "Ask what the owner recently did on this iPhone, when the task depends on it (\"the restaurant I was looking at\", \"the article I read this morning\"). A model on the iPhone answers from the owner's private screen history in a few sentences, and the owner may be asked before the answer is given to you. Ask one narrow question that names what the task needs; do not ask for everything, and do not ask again for something that was not shared. Works only when the instructions say the owner turned it on.",
        schema: [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "One narrow question about what the owner did or saw, in the owner's language."],
                "hours": ["type": "integer", "minimum": 1, "maximum": 168, "description": "How far back to look. 24 when left out."],
            ],
            "required": ["question"],
            "additionalProperties": false,
        ])

    /// Whether the agent is told about the tool: Backtape is on and the owner let Poki ask it.
    @MainActor static var offered: Bool { HistoryCapture.shared.enabled && HistoryCapture.shared.agentAsks }

    static let brief = "The owner let you ask about what they recently did on this iPhone: personal_context {question, hours}. Use it only when the request points at something they did or saw and you cannot go on without it. The answer is private to this task: use it for the task and do not repeat more of it than the reply needs."

    enum Draft {
        /// Why there is no answer, in words for the agent.
        case unavailable(String)
        /// The tape has nothing on it.
        case nothing
        /// The local model's answer and whether it may go without asking, with the reason.
        case summary(String, share: Bool, reason: String)
    }

    static let notShared = "The owner did not allow sharing this. Do not ask for it again in this task. Go on without it, or ask the owner in plain words for what you need."
    static let nothingFound = "Nothing in the owner's recent history answers this. Ask the owner in plain words if the task needs it."

    /// The local model's answer to the agent's question, and its verdict on that answer.
    @MainActor static func draft(question: String, hours: Int, task: String) async -> Draft {
        let capture = HistoryCapture.shared
        guard offered else {
            return .unavailable("The owner has not turned this on (Settings, Backtape, Poki Can Ask Backtape). Go on without it.")
        }
        guard BacktapeWriter.available else {
            return .unavailable("No model on this iPhone can read the history yet. Go on without it.")
        }
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard question.count >= 3 else { return .unavailable("Send one clear question.") }
        let span = TimeInterval(min(168, max(1, hours)) * 3600)
        let entries = await HistoryStore.shared.entries(from: Date().addingTimeInterval(-span), to: Date())
            .filter { capture.keeps($0.app) && BacktapeApps.service($0.app) == nil }
        guard !entries.isEmpty else { return .nothing }

        // The summaries are the map: the model picks the moments that may hold the answer, and only
        // those moments' screen text is read in full (the owner, 2026-11-15). With no summaries yet,
        // or none picked, the reads that share words with the question stand in.
        let words = terms(question)
        var text = ""
        let spots = await moments(for: question, from: Date().addingTimeInterval(-span), to: Date())
        if !spots.isEmpty {
            let inside = entries.filter { entry in spots.contains { $0.start <= entry.at && entry.at < $0.end } }
            text = passages(inside, words: words, long: span > 20 * 3600)
            AppLog.shared.add("history", "personal context: \(spots.count) moments, \(inside.count) reads")
        }
        if text.isEmpty {
            text = passages(pick(entries, for: question), words: words, long: span > 20 * 3600)
        }
        let instructions = """
        You answer one question about what a person did on their iPhone, from text that was on the \
        screen. Answer in the language of the question, in at most 4 plain sentences, with only what \
        the question asks for and only what the text shows. Never give message text, passwords, \
        codes, card or account numbers. If the text does not answer the question, reply with the \
        single word NONE.
        """
        guard let raw = await BacktapeWriter.ask("Question: \(question)\n\n\(text)", instructions: instructions) else {
            return .unavailable("The model on this iPhone could not answer. Go on without it.")
        }
        let answer = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(700))
        if answer.isEmpty || answer.uppercased().hasPrefix("NONE") { return .nothing }

        // The pills' own rule first: money, codes, passwords, messages and quoted words are never
        // the model's to wave through.
        if HomeShortcuts.isPrivate(answer) {
            return .summary(answer, share: false, reason: "It may hold something private.")
        }
        // Ask for Everything means what it says.
        if ApprovalClassifier.Level.saved == .everything {
            return .summary(answer, share: false, reason: "")
        }
        let verdict = await judge(answer, question: question, task: task)
        return .summary(answer, share: verdict.share, reason: verdict.reason)
    }

    /// The model on this iPhone decides whether its answer may go to the remote model without the
    /// owner. Only a clear SHARE passes; no answer, or any other, is the owner's.
    @MainActor private static func judge(_ answer: String, question: String, task: String) async -> (share: Bool, reason: String) {
        let instructions = """
        You guard a person's privacy. A summary of what they did on their iPhone is about to be sent \
        to an online AI service, to help with a task they asked for. Reply on one line: SHARE or ASK, \
        then " | " and a reason of at most 12 words. Reply ASK when the summary touches health, \
        money or banking, passwords or codes, exact addresses or where the person is, other people \
        by name or what they wrote, private conversations, relationships, sex, religion, politics, \
        work secrets or legal matters; when it holds more than the task needs; or when you are not \
        sure. Reply SHARE only when the summary is plainly harmless and the task needs it.
        """
        let input = "Task: \(task.prefix(300))\nQuestion: \(question)\nSummary: \(answer)"
        guard let raw = await BacktapeWriter.ask(input, instructions: instructions) else { return (false, "") }
        let line = raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let word = (parts.first ?? "").trimmingCharacters(in: CharacterSet.letters.inverted).uppercased()
        let reason = parts.count > 1 ? String(parts[1].prefix(120)) : ""
        return (word == "SHARE", reason)
    }

    /// The blocks of the tape the model on this iPhone picks from their summaries, up to 3.
    @MainActor private static func moments(for question: String, from start: Date, to end: Date) async -> [(start: Date, end: Date)] {
        // Ten-minute and hour notes; a note's key carries its zoom in its fraction (BacktapeZoom.key).
        let kept = await HistoryStore.shared.notes(from: start.addingTimeInterval(-3600), to: end).compactMap { row -> (start: Date, end: Date, note: BacktapeNote)? in
            let whole = row.start.rounded(.down)
            let zoom: BacktapeZoom? = row.start - whole < 0.1 ? .all : abs(row.start - whole - 0.25) < 0.1 ? .hours : nil
            guard let zoom else { return nil }
            let from = Date(timeIntervalSince1970: whole)
            return (from, zoom.end(from), row.note)
        }
        guard !kept.isEmpty else { return [] }
        // The newest 40, in about 3,000 characters.
        let listed = Array(kept.suffix(40))
        let room = max(60, 3000 / listed.count - 50)
        var index = ""
        for (number, item) in listed.enumerated() {
            let time = item.start.formatted(date: .abbreviated, time: .shortened)
            let minutes = Int(item.end.timeIntervalSince(item.start) / 60)
            index += "\(number + 1). [\(time), \(minutes) min] \(item.note.title). \(item.note.body.prefix(room))\n"
        }
        let instructions = """
        Below is a numbered list of summaries of what a person did on their iPhone, each with its \
        time. Pick the entries most likely to hold the answer to the question. Reply with up to 3 \
        numbers separated by commas and nothing else. If none fits, reply NONE.
        """
        guard let raw = await BacktapeWriter.ask("Question: \(question)\n\n\(index)", instructions: instructions) else { return [] }
        let numbers = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        var out: [(start: Date, end: Date)] = []
        for number in numbers where (1...listed.count).contains(number) {
            let item = listed[number - 1]
            if !out.contains(where: { $0.start == item.start && $0.end == item.end }) { out.append((item.start, item.end)) }
            if out.count == 3 { break }
        }
        return out
    }

    /// The screen text of some reads for the model's window, about 3,000 characters: of each read,
    /// the part around the question's words when it has them, else its start. Reads that hold the
    /// words come first when there are too many.
    @MainActor private static func passages(_ entries: [HistoryEntry], words: [String], long: Bool) -> String {
        guard !entries.isEmpty else { return "" }
        var chosen = entries
        if chosen.count > 14 { chosen = pick(chosen, words: words) }
        let room = max(160, 3000 / chosen.count - 40)
        var text = ""
        for entry in chosen {
            let time = entry.at.formatted(date: long ? .abbreviated : .omitted, time: .shortened)
            text += "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(excerpt(entry.text, words: words, room: room))\n\n"
        }
        return text
    }

    /// `room` characters of a read: from a little before the first of the question's words in it.
    private static func excerpt(_ text: String, words: [String], room: Int) -> String {
        guard text.count > room else { return text }
        let low = text.lowercased()
        var first: String.Index?
        for word in words {
            if let found = low.range(of: word)?.lowerBound, first.map({ found < $0 }) ?? true { first = found }
        }
        guard let first else { return String(text.prefix(room)) }
        let offset = max(0, low.distance(from: low.startIndex, to: first) - room / 4)
        return String(text.dropFirst(min(offset, max(0, text.count - room))).prefix(room))
    }

    /// Up to 14 reads for the model's small window: those that share words with the question first,
    /// the rest spread evenly over the time, in the order they happened.
    @MainActor private static func pick(_ entries: [HistoryEntry], for question: String) -> [HistoryEntry] {
        pick(entries, words: terms(question))
    }

    @MainActor private static func pick(_ entries: [HistoryEntry], words: [String]) -> [HistoryEntry] {
        let room = 14
        guard entries.count > room else { return entries }
        var scored: [(index: Int, score: Int)] = []
        for (index, entry) in entries.enumerated() {
            let hay = "\(HistoryNames.app(entry.app)) \(entry.title) \(entry.text.prefix(4000))".lowercased()
            let score = words.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        var chosen = Set(scored.prefix(10).map(\.index))
        var step = 0
        while chosen.count < room, step < room {
            chosen.insert(step * entries.count / room)
            step += 1
        }
        return chosen.sorted().map { entries[$0] }
    }

    /// The question's words, and for Chinese and Japanese its pairs of characters.
    private static func terms(_ question: String) -> [String] {
        var out = Set<String>()
        for word in question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where !word.isEmpty {
            let wide = word.unicodeScalars.contains { $0.value >= 0x2E80 }
            if wide {
                let c = Array(word)
                if c.count >= 2 { for i in 0..<(c.count - 1) { out.insert(String(c[i...(i + 1)])) } }
            } else if word.count >= 3, !stop.contains(word) {
                out.insert(word)
            }
        }
        return Array(out)
    }

    private static let stop: Set<String> = ["the", "what", "which", "who", "was", "were", "did", "does", "that", "this", "with", "for",
                                            "and", "from", "have", "has", "had", "you", "they", "owner", "user", "about", "recently", "today"]

    /// One line in Backtape's observing record for each answer that left or did not leave the phone.
    @MainActor static func record(shared: Bool, question: String) {
        HistoryStore.shared.note(shared ? "shared" : "notShared", String(question.prefix(120)))
        AppLog.shared.add("history", "personal context: \(shared ? "shared" : "not shared")")
    }
}
