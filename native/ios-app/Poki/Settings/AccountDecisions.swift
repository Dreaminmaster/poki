import Foundation
import PiSwiftAI
import PokiCore
import SwiftUI

/// A model account as the decision model. Any account the chat can run on can decide: its model is
/// asked in one prompt and its JSON answer is read strictly (PokiCore's `PromptDecider`). An OpenAI
/// API key also offers Luna on OpenAI's Decisions API, which is made for this. The request goes from
/// the iPhone straight to the account's provider, as text only.
enum AccountDecisions {
    /// OpenAI's decision model, on its Decisions API.
    static let luna = "gpt-6-luna"

    /// Custom providers have their own pages now and are not offered here yet: a pick left from when
    /// the one custom account could decide reads as Off.
    static func canDecide(_ provider: ModelProvider) -> Bool { provider != .custom && ModelAccounts.canChat(provider) }

    /// The account's models that can decide: Luna first for an OpenAI API key, then its chat models,
    /// the fast ones first.
    static func models(_ provider: ModelProvider) -> [ChatModelChoice] {
        let own = provider == .openai ? [ChatModelChoice(id: luna, name: "GPT-6 Luna")] : []
        return own + ModelCatalog.all(provider).filter { $0.id != luna }
    }

    static func name(_ provider: ModelProvider, _ model: String) -> String {
        models(provider).first { $0.id == model }?.name ?? model
    }

    /// The decider for an account's model. An account that is gone gives no answer when asked, which
    /// is an error for the run and never a guess.
    static func decider(_ provider: ModelProvider, model: String) -> Decider? {
        guard canDecide(provider), !model.isEmpty else { return nil }
        if provider == .openai, model == luna {
            return DeciderSettings(provider: .openai, model: luna).decider(token: ModelKeys.key(.openai) ?? "")
        }
        return PromptDecider(name: model, maxState: 6000, patience: 8) { prompt, instructions in
            await ask(provider, model: model, prompt: prompt, instructions: instructions)
        }
    }

    /// One prompt to the account's model through pi, the code the chat runs on. nil when there is no
    /// answer, which is an error for the decider and never a guess. The key is never logged.
    @MainActor
    static func ask(_ provider: ModelProvider, model id: String, prompt: String, instructions: String) async -> String? {
        guard let model = provider.piModel(id), let key = await ModelCredential.apiKey(for: provider) else { return nil }
        var options = SimpleStreamOptions()
        options.apiKey = key
        options.headers = openCodeSessionHeaders(model: model, sessionId: UUID().uuidString, headers: options.headers)
        options.maxTokens = 400
        options.maxRetries = 0
        options.timeoutMs = 10_000
        let context = Context(messages: [.user(UserMessage(content: .text(instructions + "\n\n" + prompt)))])
        func failed(_ why: String) {
            AppLog.shared.add("decisions", "\(provider.name) gave no decision: \(why.replacingOccurrences(of: key, with: "…").prefix(160))")
        }
        do {
            let reply = try await completeSimple(model: model, context: context, options: options)
            guard reply.stopReason != .error, reply.stopReason != .aborted else {
                failed(reply.errorMessage ?? "")
                return nil
            }
            let text = reply.content.compactMap { block -> String? in
                guard case .text(let content) = block else { return nil }
                return content.text
            }.joined()
            return text.isEmpty ? nil : text
        } catch {
            failed(error.localizedDescription)
            return nil
        }
    }
}

/// Account › Decisions: which of the account's models is the decision model, or none of them.
struct DecisionFeature: View {
    var provider: ModelProvider
    @State private var picked: String

    init(provider: ModelProvider) {
        self.provider = provider
        _picked = State(initialValue: QuickFixes.accountModel(provider) ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $picked) {
                    Text("Off").tag("")
                    ForEach(AccountDecisions.models(provider)) { choice in
                        Text(verbatim: choice.name).tag(choice.id)
                    }
                } label: {
                    Text("Decision Model")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("account.decisions.model")
            } header: {
                Text("Decision Model")
            } footer: {
                Text("A small, fast model works best. It helps a skill go on when a prompt is in the way or a button was renamed, acts only when the answer is clear and never taps anything that needs your approval. It gets the goal of the task and the names of the elements on screen, with no screenshot. Only one decision model is in use at a time.")
            }
        }
        .settingsPage()
        .navigationTitle(AppLocalization.text("Decisions"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: picked) { _, new in QuickFixes.pickAccount(provider, model: new.isEmpty ? nil : new) }
    }
}
