import SwiftUI

// Tapping Poki's picture, on the home page, in the conversation or on the voice page, opens Poki's card
// under it (the owner's home of 2026-11-12, boards 定稿 08 and 01c): two rows, the model that answers and
// how Poki asks before a sensitive step, each showing its choice and opening in place to change it. These
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
        case .turnOn: String(localized: "Poki is off. Agents can’t connect to this iPhone until you turn it on.")
        case .resume: String(localized: "Poki is paused. It resumes automatically upon a new task or agent request.")
        case .pause: String(localized: "Poki can tap and type on this iPhone when you send a task or an agent requests it.")
        }
    }
}

extension PowerTile {
    /// The cards' button by what Poki is: off, Turn On; paused by you, Resume; otherwise Pause.
    @MainActor static func card(model: AppModel) -> PowerTile {
        if !(model.sessionOn || model.wantsOn) { return .turnOn }
        return model.ownerPaused ? .resume : .pause
    }

    var title: LocalizedStringKey {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .turnOn: "Turn On"
        }
    }

    var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .turnOn: "power"
        }
    }

    /// The accessibility identifier's last part, as the profile's tiles had them.
    var name: String {
        switch self {
        case .pause: "pause"
        case .resume: "resume"
        case .turnOn: "turnOn"
        }
    }

    @MainActor func act(model: AppModel, chat: ChatModel) {
        switch self {
        // Your pause, also while the runner stands by: Poki shows asleep until you or an agent wakes it.
        case .pause: chat.stop(); model.pauseByOwner()
        case .resume: model.wakeRunner()
        case .turnOn: model.startSession()
        }
    }
}

/// Poki's card under its picture (board 定稿 08): a system-style menu card of two rows. The model that
/// answers, which opens in place to the chat models of every account that is set up (07b), or Add
/// Model with none; and the approval method, which opens in place the same way to the three methods,
/// the one in use ticked, and the line on what always asks you. The method is `AppModel.approvalMode`,
/// the one setting Settings › Approvals reads. Each acts at once; one row is open at a time.
struct PokiStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.colorScheme) private var scheme
    /// Settings › Models, for Add Model.
    var openModel: () -> Void
    @State private var open: Row?
    private enum Row { case model, approvals }
    /// Bumped when the chosen model changes (ModelKeys is not observable).
    @State private var modelVersion = 0

    private var dark: Bool { scheme == .dark }
    private var soft: Color { Color(.secondaryLabel) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Where Poki stands, which the top bar no longer says in words: its face shows it there.
            Text(verbatim: PokiStatusCopy.word(PokiStatus.current(model: model, chat: chat)))
                .font(.footnote).foregroundStyle(soft)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
                .accessibilityIdentifier("status.word")
            modelRow
            if open == .model { modelChoices }
            rule
            approvalRow
            if open == .approvals { approvalChoices }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 330, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .background(Color(dark ? .secondarySystemBackground : .systemBackground).opacity(0.6), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.95), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.4 : 0.16), radius: 24, y: 16)
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
        .animation(.snappy(duration: 0.28), value: open)
        // A container, so each row keeps its own identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.card")
    }

    private var rule: some View {
        Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 20)
    }

    private var providers: [ModelProvider] {
        ModelProvider.allCases.filter { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }
    }

    // MARK: Model

    @ViewBuilder private var modelRow: some View {
        if ModelKeys.hasUsableKey {
            Button { toggle(.model) } label: {
                choiceRow("Model", value: ModelKeys.selectedModelName, open: open == .model)
            }
            .buttonStyle(CardRowStyle())
            .id(modelVersion)
            .accessibilityValue(Text(verbatim: ModelKeys.selectedModelName))
            .accessibilityIdentifier("status.model")
        } else {
            Button(action: openModel) {
                HStack(spacing: 8) {
                    Text("Add Model").foregroundStyle(Tint.blue).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(.horizontal, 20).frame(minHeight: 52).contentShape(.rect)
            }
            .buttonStyle(CardRowStyle())
            .accessibilityIdentifier("status.addModel")
        }
    }

    /// The chat models of every account that is set up, by account, the one that answers ticked.
    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(providers) { provider in
                Text(verbatim: provider.name).font(.footnote).foregroundStyle(soft)
                    .padding(.horizontal, 36).padding(.top, 8).padding(.bottom, 2)
                ForEach(ModelCatalog.available(provider)) { choice in
                    let chosen = ModelKeys.selectedProvider == provider && ModelKeys.selectedModel == choice.id
                    Button {
                        ModelKeys.selectedProvider = provider
                        ModelKeys.selectedModel = choice.id
                        ModelKeys.saved += 1
                        modelVersion += 1
                        open = nil
                    } label: {
                        tickRow(choice.name, ticked: chosen, inset: 36)
                    }
                    .buttonStyle(CardRowStyle())
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
        .padding(.bottom, 4)
        .id(modelVersion)
        .transition(.opacity)
    }

    // MARK: Approvals

    private var approvalRow: some View {
        Button { toggle(.approvals) } label: {
            choiceRow("Approval Method", value: model.approvalMode.title, open: open == .approvals)
        }
        .buttonStyle(CardRowStyle())
        .accessibilityValue(Text(verbatim: model.approvalMode.title))
        .accessibilityIdentifier("status.approvals")
    }

    /// The three methods, the one in use ticked, and under them what always asks you whatever the method.
    private var approvalChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ApprovalClassifier.Mode.allCases) { mode in
                let chosen = model.approvalMode == mode
                Button {
                    if !chosen { model.approvalMode = mode }
                    open = nil
                } label: {
                    tickRow(mode.title, ticked: chosen, inset: 36)
                }
                .buttonStyle(CardRowStyle())
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("status.approvals.\(mode.rawValue)")
            }
            Text("Payments, deletions and actions in Wallet always need your confirmation.")
                .font(.footnote).foregroundStyle(soft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36).padding(.trailing, 20).padding(.top, 4).padding(.bottom, 10)
        }
        .sensoryFeedback(.selection, trigger: model.approvalMode)
        .transition(.opacity)
    }

    private func toggle(_ row: Row) { open = open == row ? nil : row }

    /// A row of the card: its name, what is chosen, and the arrow that opens the choices under it.
    private func choiceRow(_ title: LocalizedStringKey, value: String, open: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Color(.label)).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value).foregroundStyle(soft).lineLimit(1)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 20).frame(minHeight: 52).contentShape(.rect)
    }

    private func tickRow(_ title: String, ticked: Bool, inset: CGFloat, height: CGFloat = 44) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).foregroundStyle(Color(.label)).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blue)
                .opacity(ticked ? 1 : 0).frame(width: 20)
        }
        .padding(.leading, inset).padding(.trailing, 20).frame(minHeight: height).contentShape(.rect)
    }
}

/// A row of the card: a light press highlight, as a system menu's.
private struct CardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
    }
}

extension View {
    /// Poki's card over the page; a tap outside closes it. Add Model closes it and opens Settings › Models.
    /// It opens under `under`, the bottom of Poki's picture over the home page's greeting in global
    /// points, and under the top bar where that is nil. `leading` is where the chat begins: beside the
    /// conversations on iPad.
    func pokiStatusCard(isPresented: Binding<Bool>, under: CGFloat? = nil, leading: CGFloat = 0, openModel: @escaping () -> Void) -> some View {
        modifier(PokiStatusCardOverlay(isPresented: isPresented, under: under, leading: leading, openModel: openModel))
    }
}

private struct PokiStatusCardOverlay: ViewModifier {
    @Binding var isPresented: Bool
    var under: CGFloat?
    var leading: CGFloat
    var openModel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The top of the overlay in global points, to place the card under the picture on the home page.
    @State private var origin: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if isPresented {
                    // The page stays as it is behind the card (the board); a tap anywhere else closes it.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { isPresented = false }
                        .accessibilityLabel(Text("Close"))
                        .accessibilityAddTraits(.isButton)
                    PokiStatusCard(openModel: {
                        isPresented = false
                        openModel()
                    })
                    .padding(.horizontal, 16)
                    // Under Poki's picture: over the greeting on the home page, clear of it; in the chat,
                    // under the picture and its name.
                    .padding(.top, under.map { max(0, $0 - origin + 12) } ?? 84)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { isPresented = false }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, leading)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { origin = $0 }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.18), value: isPresented)
        }
    }
}
