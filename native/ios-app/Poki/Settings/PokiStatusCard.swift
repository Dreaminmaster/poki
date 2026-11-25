import SwiftUI
import UIKit

// The home avatar, conversation name pill, and voice header open Poki's native status menu.
// On iOS 26 the menu uses Liquid Glass and opens from the control that was tapped. The model that answers
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

/// Where `PokiMenu` opens relative to its control: `.below` anchors a native `UIButton` below the
/// control's bottom edge, so the menu opens downward clear of the bear's face, and its opening is seen
/// (`onOpen`), which a SwiftUI `Menu`'s tap is not on iOS 27. Every call site uses it, the home picture,
/// the conversation's name pill and the voice header.
enum PokiMenuAnchor: Equatable {
    case below(spacing: CGFloat = 10)
}

/// Poki's menu: the status word as its heading, the model that answers (the chat models of every
/// account that is set up, by account, or Add Model with none) and the approval method with the line on
/// what always asks you. The method is `AppModel.approvalMode`, the one setting Settings › Approvals
/// reads. Each choice acts at once.
struct PokiMenu<Face: View>: View {
    @Environment(AppModel.self) private var model
    /// Settings › Models, for Add Model.
    var openModel: () -> Void
    /// The tap that opens the menu, for the bear to answer.
    var tapped: () -> Void = {}
    var openCustomization: (() -> Void)? = nil
    var anchor: PokiMenuAnchor = .below()
    var accessibilityLabel: String? = nil
    var accessibilityIdentifier: String? = nil
    @ViewBuilder var face: () -> Face
    /// Bumped when the chosen model changes (ModelKeys is not observable).
    @State private var modelVersion = 0
    @State private var showsAutoUnlock = false
    @State private var showsAutoUnlockPasscode = false

    private var providers: [ModelProvider] {
        ModelProvider.allCases.filter { ModelAccounts.isSetUp($0, storage: model.storage) && ModelAccounts.canChat($0) }
    }

    var body: some View {
        menuTrigger
            .sensoryFeedback(.selection, trigger: model.approvalMode)
            .sensoryFeedback(.selection, trigger: modelVersion)
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
            .sheet(isPresented: $showsAutoUnlock) {
                NavigationStack {
                    Form {
                        AutoUnlockSection(setting: model.autoUnlock, canEnable: model.supportsAutoUnlock,
                                          showsPasscode: $showsAutoUnlockPasscode)
                    }
                    .navigationTitle("Automatic Unlock")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAutoUnlock = false } }
                    }
                    .sheet(isPresented: $showsAutoUnlockPasscode) {
                        AutoUnlockPasscodeForm(setting: model.autoUnlock)
                    }
                }
            }
    }

    /// The menu opens: the bear answers the tap, and the hint that Poki has a menu is done.
    private func opened() {
        PokiMenuTip.menuOpened()
        tapped()
    }

    @ViewBuilder private var menuTrigger: some View {
        switch anchor {
        case .below(let spacing):
            face()
                .accessibilityHidden(true)
                .overlay {
                    AnchoredPokiMenuButton(
                        menu: nativeMenu,
                        attachmentSpacing: spacing,
                        accessibilityLabel: accessibilityLabel,
                        accessibilityIdentifier: accessibilityIdentifier,
                        onOpen: opened
                    )
                }
        }
    }

    private var nativeMenu: UIMenu {
        _ = AppLocalization.language
        _ = modelVersion

        var primaryItems: [UIMenuElement] = []
        if ModelKeys.hasUsableKey(in: model.storage) {
            var providerMenus: [UIMenu] = []
            for provider in providers {
                let choices = ModelCatalog.available(provider, storage: model.storage)
                if provider == .custom {
                    for custom in CustomProviders.all(in: model.storage) {
                        let models = choices.compactMap { choice -> ChatModelChoice? in
                            guard let selection = CustomProviders.parse(choice.id),
                                  selection.provider == custom.id else { return nil }
                            return ChatModelChoice(id: choice.id, name: selection.model)
                        }
                        if !models.isEmpty {
                            providerMenus.append(nativeModelGroup(custom.displayName, provider: provider, choices: models))
                        }
                    }
                } else {
                    providerMenus.append(nativeModelGroup(provider.name, provider: provider, choices: choices))
                }
            }
            let modelMenu = UIMenu(
                title: AppLocalization.text("Model"),
                subtitle: ModelKeys.selectedModelName(in: model.storage),
                image: UIImage(systemName: "sparkles"),
                children: providerMenus
            )
            modelMenu.accessibilityIdentifier = "status.model"
            primaryItems.append(modelMenu)
        } else {
            let addModel = UIAction(
                title: AppLocalization.text("Add Model"),
                image: UIImage(systemName: "plus")
            ) { _ in openModel() }
            addModel.accessibilityIdentifier = "status.addModel"
            primaryItems.append(addModel)
        }

        let approvalActions = ApprovalClassifier.Mode.allCases.map { mode in
            UIAction(title: mode.title, state: model.approvalMode == mode ? .on : .off) { _ in
                model.approvalMode = mode
            }
        }
        let approvalSection = UIMenu(
            title: AppLocalization.text(ApprovalCopy.alwaysConfirm),
            options: .displayInline,
            children: approvalActions
        )
        let approvalsMenu = UIMenu(
            title: AppLocalization.text("Approval"),
            subtitle: model.approvalMode.title,
            image: UIImage(systemName: "checkmark.shield"),
            children: [approvalSection]
        )
        approvalsMenu.accessibilityIdentifier = "status.approvals"
        primaryItems.append(approvalsMenu)

        if let openCustomization {
            let outfits = UIAction(
                title: AppLocalization.text("Outfits"),
                subtitle: outfitName,
                image: UIImage(systemName: "hanger")
            ) { _ in openCustomization() }
            outfits.accessibilityIdentifier = "status.customizePoki"
            primaryItems.append(outfits)
        }

        var topLevel: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: primaryItems)]
        if model.supportsAutoUnlock {
            let autoUnlock = UIAction(
                title: AppLocalization.text("Automatic Unlock"),
                image: UIImage(systemName: "lock.open")
            ) { _ in showsAutoUnlock = true }
            autoUnlock.accessibilityIdentifier = "status.autoUnlock"
            topLevel.append(autoUnlock)
        }
        return UIMenu(title: "", children: topLevel)
    }

    private func nativeModelGroup(_ title: String, provider: ModelProvider, choices: [ChatModelChoice]) -> UIMenu {
        let actions = choices.map { choice in
            let chosen = ModelKeys.selectedProvider(in: model.storage) == provider && ModelKeys.selectedModel(in: model.storage) == choice.id
            return UIAction(title: choice.name, state: chosen ? .on : .off) { _ in
                pick(provider, choice.id)
            }
        }
        return UIMenu(title: title, options: .displayInline, children: actions)
    }

    private var outfitName: String {
        let worn = BearWardrobe.shared.selection
        if let clothes = worn.clothes, worn.headwear == clothes {
            return AppLocalization.text(clothes.name)
        }
        let pieces = BearOutfitSlot.allCases.compactMap { slot in
            worn[slot].map { AppLocalization.text($0.piece(slot).name) }
        }
        return pieces.isEmpty ? AppLocalization.text("None") : ListFormatter.localizedString(byJoining: pieces)
    }

    private func pick(_ provider: ModelProvider, _ id: String) {
        ModelKeys.setSelectedProvider(provider, in: model.storage)
        ModelKeys.setSelectedModel(id, in: model.storage)
        ModelKeys.saved += 1
    }
}

private struct AnchoredPokiMenuButton: UIViewRepresentable {
    var menu: UIMenu
    var attachmentSpacing: CGFloat
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    var onOpen: () -> Void

    func makeUIView(context: Context) -> BelowAnchoredMenuContainer {
        let container = BelowAnchoredMenuContainer()
        update(container)
        return container
    }

    func updateUIView(_ container: BelowAnchoredMenuContainer, context: Context) {
        update(container)
    }

    private func update(_ container: BelowAnchoredMenuContainer) {
        container.attachmentSpacing = attachmentSpacing
        container.menuButton.onOpen = onOpen
        container.menuButton.menu = menu
        container.menuButton.accessibilityLabel = accessibilityLabel
        container.menuButton.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// Hosts a native `UIButton` whose own frame sits directly below the bear avatar while routing taps
/// and accessibility bounds from the avatar's frame. On iOS 26/27 Liquid Glass, `UIButton` aligns
/// a downward primary-action menu's top edge with the button's own frame top edge (while
/// `menuAttachmentPoint(for:)` controls downward vs upward direction).
private final class BelowAnchoredMenuContainer: UIView {
    let menuButton = BelowAnchoredMenuButton(type: .custom)
    var attachmentSpacing: CGFloat = 10 {
        didSet {
            if oldValue != attachmentSpacing { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        isAccessibilityElement = false
        menuButton.backgroundColor = .clear
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.preferredMenuElementOrder = .fixed
        menuButton.isAccessibilityElement = true
        addSubview(menuButton)
        accessibilityElements = [menuButton]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        menuButton.frame = CGRect(x: 0, y: bounds.maxY + attachmentSpacing, width: bounds.width, height: 2)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha >= 0.01, bounds.contains(point) else { return nil }
        return menuButton
    }
}

private final class BelowAnchoredMenuButton: UIButton {
    var onOpen: (() -> Void)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let container = superview else { return super.point(inside: point, with: event) }
        return container.bounds.contains(convert(point, to: container))
    }

    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY)
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let container = superview else { return super.accessibilityFrame }
            return UIAccessibility.convertToScreenCoordinates(container.bounds, in: container)
        }
        set { super.accessibilityFrame = newValue }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onOpen?()
    }
}
