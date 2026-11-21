import SwiftUI

// Tapping Poki, on the home page, in the conversation or on the voice page, opens Poki's menu in place
// (the owner, 2026-11-15: a native menu, not a drawn card; it grows out of Poki's picture before a chat
// has begun and out of the glass pill with Poki's name after). It is the system's own menu, so on
// iOS 26 it is Liquid Glass and opens from the control that was tapped. The model that answers
// and how Poki asks before a sensitive step each show their choice and open to change it. These
// live only here: Settings keeps the accounts. Settings opens from the bottom of the conversations
// (SettingsEntryButton). Pause is not on it (the owner, 2026-11-13): it only stopped the task, which the
// message field's Stop does, and the next task woke Poki again.

/// The one place the settings card and the status card take Poki's status words from. They are the
/// bear's own (PokiMood.word, from `StatusWord`), the same words the Live Activity says ("Ready",
/// "Paused"), never a second set.
enum PokiStatusCopy {
    @MainActor static func current(model: AppModel, chat: ChatModel) -> PokiStatus {
        PokiStatus.current(model: model, chat: chat)
    }

    /// The words beside the dot. They have no subject, so beside Poki's name they read as they are.
    static func word(_ status: PokiStatus) -> String { status.word }

    /// The status a card shows beside its button: off and paused come from the switch itself, so the
    /// words never say otherwise than the button (Turn On under "Off", Resume under "Paused").
    @MainActor static func card(_ status: PokiStatus, power: PowerTile) -> PokiStatus {
        switch power {
        case .turnOn: PokiStatus(.paused, word: StatusWord.off.text)
        case .resume: status.mood == .paused ? status : PokiStatus(.paused)
        case .pause: status.mood == .paused ? PokiStatus(.ready) : status
        }
    }

    /// The plain line under the status (ESP-467: only the status words are in Poki's voice): what Poki
    /// can do now and what starts it.
    static func line(_ power: PowerTile) -> String {
        switch power {
        case .turnOn: AppLocalization.text(LocalizedStringResource("Poki is off. Agents can’t connect to this iPhone until you turn it on."))
        case .resume: AppLocalization.text(LocalizedStringResource("Poki is paused. It resumes automatically upon a new task or agent request."))
        case .pause: AppLocalization.text(LocalizedStringResource("Poki can tap and type on this iPhone when you send a task or an agent requests it."))
        }
    }
}

extension PowerTile {
    /// Where Poki stands for the settings card's status words: off, paused by you, or on. The card has no
    /// button for it; Connection's Automation switch turns Poki on and pauses it.
    @MainActor static func card(model: AppModel) -> PowerTile {
        if !(model.sessionOn || model.wantsOn) { return .turnOn }
        return model.ownerPaused ? .resume : .pause
    }
}

/// Poki's menu: the status word as its heading, the model that answers (the chat models of every
/// account that is set up, by account, or Add Model with none) and the approval method with the line on
/// what always asks you. The method is `AppModel.approvalMode`, the one setting Settings › Approvals
/// reads. Each choice acts at once.
struct PokiMenu<Face: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    /// Settings › Models, for Add Model.
    var openModel: () -> Void
    /// The tap that opens the menu, for the bear to answer.
    var tapped: () -> Void = {}
    var openOutfits: (() -> Void)? = nil
    @ViewBuilder var face: () -> Face
    /// Bumped when the chosen model changes (ModelKeys is not observable).
    @State private var modelVersion = 0

    private var providers: [ModelProvider] {
        ModelProvider.allCases.filter { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }
    }

    var body: some View {
        Menu {
            Section {
                if ModelKeys.hasUsableKey {
                    Menu {
                        ForEach(providers) { provider in
                            let choices = ModelCatalog.available(provider)
                            if provider == .custom {
                                ForEach(CustomProviders.all) { custom in
                                    let models = choices.compactMap { choice -> ChatModelChoice? in
                                        guard let selection = CustomProviders.parse(choice.id),
                                              selection.provider == custom.id else { return nil }
                                        return ChatModelChoice(id: choice.id, name: selection.model)
                                    }
                                    if !models.isEmpty {
                                        modelGroup(custom.displayName, provider: provider, choices: models)
                                    }
                                }
                            } else {
                                modelGroup(provider.name, provider: provider, choices: choices)
                            }
                        }
                    } label: {
                        Label("Model", systemImage: "sparkles")
                        Text(verbatim: ModelKeys.selectedModelName)
                    }
                    .accessibilityIdentifier("status.model")
                } else {
                    Button(action: openModel) { Label("Add Model", systemImage: "plus") }
                        .accessibilityIdentifier("status.addModel")
                }
                Menu {
                    Section {
                        ForEach(ApprovalClassifier.Mode.allCases) { mode in
                            Toggle(isOn: Binding(
                                get: { model.approvalMode == mode },
                                set: { on in if on { model.approvalMode = mode } }
                            )) {
                                Text(verbatim: mode.title)
                            }
                        }
                    } header: {
                        Text("Payments, deletions and actions in Wallet always need your confirmation.")
                    }
                } label: {
                    Label("Approval Method", systemImage: "checkmark.shield")
                    Text(verbatim: model.approvalMode.title)
                }
                .accessibilityIdentifier("status.approvals")
            } header: {
                // Where Poki stands, which the top bar no longer says in words: its face shows it there.
                Text(verbatim: PokiStatusCopy.word(PokiStatus.current(model: model, chat: chat)))
            }
            .id(modelVersion)
            if let openOutfits {
                Button("Outfits", systemImage: "tshirt", action: openOutfits)
            }
        } label: {
            face()
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { tapped() })
        .sensoryFeedback(.selection, trigger: model.approvalMode)
        .sensoryFeedback(.selection, trigger: modelVersion)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
    }

    private func modelGroup(_ title: String, provider: ModelProvider, choices: [ChatModelChoice]) -> some View {
        Section {
            ForEach(choices) { choice in
                let chosen = ModelKeys.selectedProvider == provider && ModelKeys.selectedModel == choice.id
                Toggle(isOn: Binding(get: { chosen }, set: { on in if on { pick(provider, choice.id) } })) {
                    Text(verbatim: choice.name)
                }
            }
        } header: {
            Text(verbatim: title)
        }
    }

    private func pick(_ provider: ModelProvider, _ id: String) {
        ModelKeys.selectedProvider = provider
        ModelKeys.selectedModel = id
        ModelKeys.saved += 1
    }
}
