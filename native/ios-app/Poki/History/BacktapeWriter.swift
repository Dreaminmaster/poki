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
/// Intelligence is on the iPhone, use it). The text never leaves the phone. Where the model is
/// missing, nothing is written and the page shows the screen titles as before.
enum BacktapeWriter {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    @MainActor
    static func write(_ entries: [HistoryEntry]) async -> BacktapeNote? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard available, !entries.isEmpty else { return nil }
            // The model's window is small: the start of each read, up to about 3,000 characters.
            var text = ""
            for entry in entries {
                let time = entry.at.formatted(date: .omitted, time: .shortened)
                let piece = "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text.prefix(400))\n\n"
                if text.count + piece.count > 3000 { break }
                text += piece
            }
            let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
            let instructions = """
            You describe what a person did on their iPhone during 10 minutes, from the text that was on \
            the screen. Write in \(language). First line: a title of at most 8 words. Then 2 or 3 plain \
            sentences that address the person as "you". Leave out buttons, menus, tab names and status \
            bar items. Say only what the text shows. No lists, no headings, no quotation marks.
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let answer = try await session.respond(to: text)
                let lines = answer.content.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“” ").union(.whitespaces)) }
                    .filter { !$0.isEmpty }
                guard let title = lines.first else { return nil }
                return BacktapeNote(title: String(title.prefix(90)), body: lines.dropFirst().joined(separator: " "))
            } catch {
                AppLog.shared.add("history", "summary failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
