import Foundation
import PokiCore

/// Which model writes Senses insights: interests from the summaries, the pills' actions, and answers
/// to the owner's own questions in the Memory and Senses panels (the owner, 2026-11-20: "the memory
/// creation/senses insight agent can be chosen by the user to be either their first choice online
/// model or local model").
///
/// On This iPhone is Apple's on-device model, and the default. Chat Model is the model the owner
/// picked for Poki's chat, with their own key: what it reads (summaries, screen titles) then goes to
/// that provider. Counting habits needs no model at all, and the check before anything goes to Poki's
/// chat (SensesContext) always runs on this iPhone, whichever is chosen.
enum SensesInsightModel: String, CaseIterable, Identifiable {
    case onDevice, chat
    var id: String { rawValue }
}

@MainActor
enum SensesModel {
    static var choice: SensesInsightModel { SensesUse.shared.insightModel }

    /// Whether the chosen model can answer now.
    static var available: Bool {
        switch choice {
        case .onDevice: BacktapeWriter.available
        case .chat: ModelKeys.hasUsableKey && ModelKeys.selectedProvider.piModel(ModelKeys.selectedModel) != nil
        }
    }

    /// One answer from the chosen model, or nil.
    static func ask(_ text: String, instructions: String) async -> String? {
        switch choice {
        case .onDevice:
            return await BacktapeWriter.ask(text, instructions: instructions)
        case .chat:
            let provider = ModelKeys.selectedProvider
            guard ModelKeys.hasUsableKey, let model = provider.piModel(ModelKeys.selectedModel) else { return nil }
            let loop = PiLoop(provider: provider, model: model, tools: []) { _ in .init(text: "No tools.", jpeg: nil, isError: true) }
            let reply = Reply()
            let outcome = await loop.run(text, instructions: instructions, maxTurns: 1) { said in
                if reply.text == nil { reply.text = said }
            }
            guard outcome == .done, let said = reply.text else {
                AppLog.shared.add("history", "senses insight: the chat model did not answer")
                return nil
            }
            return said
        }
    }

    @MainActor private final class Reply { var text: String? }
}

/// The owner's own question from the Memory or Senses panel's ask bar, answered from the provisional
/// memories, the saved notes and the Senses summaries by the chosen insight model. The answer is shown
/// to the owner only, in the panel, so no check runs before it is shown.
@MainActor
enum SensesAsk {
    enum Scope { case memory, senses }

    static func answer(_ question: String, scope: Scope) async -> String? {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard question.count >= 2, SensesModel.available else { return nil }
        let memories = SensesMemories.shared
        await memories.refresh()
        var text = ""
        let notes = RoutineStore.shared.notes.map(\.text)
        if !notes.isEmpty { text += "The person's own notes:\n" + notes.prefix(40).map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        let lines = memories.contextLines
        if !lines.isEmpty { text += "Habits and interests inferred from their iPhone use (not their words):\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if scope == .senses, HistoryCapture.shared.enabled {
            let rows = await HistoryStore.shared.notes(from: Date().addingTimeInterval(-7 * 86_400), to: Date())
            let listed = rows.suffix(40)
            if !listed.isEmpty {
                let room = max(60, 2400 / listed.count - 30)
                text += "Summaries of what they did on the iPhone:\n"
                for row in listed {
                    let time = Date(timeIntervalSince1970: row.start.rounded(.down)).formatted(date: .abbreviated, time: .shortened)
                    text += "[\(time)] \(row.note.title). \(row.note.body.prefix(room))\n"
                }
            }
        }
        guard !text.isEmpty else { return nil }
        let instructions = """
        You answer a person's own question about what their assistant Poki knows about them, from \
        their notes, the habits Poki inferred, and summaries of their iPhone use. Answer in the \
        language of the question, in at most 5 plain sentences, addressing them as "you". Say when \
        something is inferred rather than something they said. If nothing below answers it, say so \
        in one sentence.
        """
        return await SensesModel.ask("Question: \(question)\n\n\(text)", instructions: instructions)
    }
}
