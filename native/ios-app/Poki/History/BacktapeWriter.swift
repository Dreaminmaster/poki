import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A block of Backtape in words a person can read: a title and a few sentences.
struct BacktapeNote: Hashable, Sendable {
    var title: String
    var body: String
}

/// Writes a block's note with Apple's on-device model (the owner, 2026-11-14: where Apple
/// Intelligence is on the iPhone, use it). The text never leaves the phone. Without it, nothing is
/// written and the page shows the screen titles as before. No model is downloaded.
enum BacktapeWriter {
    /// Apple's own model, where Apple Intelligence is on the iPhone.
    static var apple: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The model picked under Settings › Models › Senses: Apple's first, the downloaded one where
    /// Apple's is missing, unless the owner picked otherwise or turned it off.
    @MainActor
    static var available: Bool { SensesModel.current != nil }

    @MainActor
    static func write(_ entries: [HistoryEntry], period: String = "10 minutes") async -> BacktapeNote? {
        // Reads past the time limit keep no text: there is nothing to describe in them.
        let entries = entries.filter { !$0.text.isEmpty }
        guard available, !entries.isEmpty else { return nil }
        // The models' windows are small: up to 14 reads spread evenly over the time, the start of
        // each, about 3,000 characters in all.
        let take = min(entries.count, 14)
        let room = max(160, 3000 / take - 40)
        let long = entries.count > 1 && (entries.last!.at.timeIntervalSince(entries.first!.at)).magnitude > 20 * 3600
        var text = ""
        for index in 0..<take {
            let entry = entries[index * entries.count / take]
            let time = entry.at.formatted(date: long ? .abbreviated : .omitted, time: .shortened)
            if let by = entry.by {
                // A step Poki took, for the owner or for an outside agent (BacktapeActivity).
                let place = entry.app.isEmpty ? "" : " in \(HistoryNames.app(entry.app))"
                text += "[\(time)] \(BacktapeActivity.name(by)) did: \(entry.text.prefix(room))\(place)\n\n"
            } else {
                text += "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text.prefix(room))\n\n"
            }
        }
        var workers: [String] = []
        for entry in entries { if let by = entry.by, !workers.contains(by) { workers.append(by) } }
        let helpers = workers.map(BacktapeActivity.name).joined(separator: ", ")
        let own = entries.contains { $0.by == nil }
        let who = workers.isEmpty ? "" : """
         Lines that say "\(helpers) did" are steps that assistant took on the iPhone for the person. \
        Say those as what \(helpers) did, such as "\(BacktapeActivity.name(workers[0])) sent the message"\(own ? ", and the rest as what \"you\" did" : ""). \
        Never say the person did an assistant's steps.
        """
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
        let instructions = """
        You describe what a person did on their iPhone during \(period), from the text that was on \
        the screen. Write in \(language). First line: a title of at most 8 words. Then 2 or 3 plain \
        sentences that address the person as "you". Leave out buttons, menus, tab names and status \
        bar items. Say only what the text shows. No lists, no headings, no quotation marks.\(who)
        """
        guard let answer = await answer(to: text, instructions: instructions) else { return nil }
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“” ").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard let title = lines.first else { return nil }
        return BacktapeNote(title: String(title.prefix(90)), body: lines.dropFirst().joined(separator: " "))
    }

    /// One answer from the model on this iPhone, for Senses' other uses (SensesMemories,
    /// SensesSuggestions, SensesContext). Nil without Apple Intelligence: nothing is downloaded and
    /// nothing is sent anywhere.
    @MainActor
    static func ask(_ text: String, instructions: String) async -> String? {
        guard available else { return nil }
        return await answer(to: text, instructions: instructions)
    }

    @MainActor
    private static func answer(to text: String, instructions: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SensesModel.current == .apple {
            do {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(to: text).content
            } catch {
                AppLog.shared.add("history", "summary failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        guard case .downloaded = SensesModel.current else { return nil }
        return await BacktapeModel.shared.respond(to: text, instructions: instructions)
    }
}
