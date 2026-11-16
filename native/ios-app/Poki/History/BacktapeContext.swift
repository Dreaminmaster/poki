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

        let picked = pick(entries, for: question)
        let long = span > 20 * 3600
        let room = max(160, 3000 / picked.count - 40)
        var text = ""
        for entry in picked {
            let time = entry.at.formatted(date: long ? .abbreviated : .omitted, time: .shortened)
            text += "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text.prefix(room))\n\n"
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

    /// Up to 14 reads for the model's small window: those that share words with the question first,
    /// the rest spread evenly over the time, in the order they happened.
    @MainActor private static func pick(_ entries: [HistoryEntry], for question: String) -> [HistoryEntry] {
        let room = 14
        guard entries.count > room else { return entries }
        let words = terms(question)
        var scored: [(index: Int, score: Int)] = []
        for (index, entry) in entries.enumerated() {
            let hay = "\(HistoryNames.app(entry.app)) \(entry.title) \(entry.text.prefix(600))".lowercased()
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
