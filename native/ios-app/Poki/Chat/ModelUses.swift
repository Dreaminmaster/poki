#if canImport(FoundationModels)
import FoundationModels
#endif
import SwiftUI

// What each model is used for, in one place (the owner, 2026-11-20): the Models page has one picker
// per use (Chat, Voice, Decisions, Senses), each in sections by provider, and every provider has a
// tick list per use of the models those pickers offer. Local models can only decide and write
// Senses' notes; Senses only ever runs on a local model.

/// What a model can be used for.
enum ModelUse: String, CaseIterable, Identifiable, Hashable {
    case chat, voice, decision, senses
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chat: "Chat"
        case .voice: "Voice"
        case .decision: "Decisions"
        case .senses: "Senses"
        }
    }

    var name: String {
        switch self {
        case .chat: AppLocalization.text(LocalizedStringResource("Chat"))
        case .voice: AppLocalization.text(LocalizedStringResource("Voice"))
        case .decision: AppLocalization.text(LocalizedStringResource("Decisions"))
        case .senses: AppLocalization.text(LocalizedStringResource("Senses"))
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .voice: "waveform"
        case .decision: "bolt"
        case .senses: "eye"
        }
    }

    /// Local models only decide and write Senses' notes.
    var local: Bool { self == .decision || self == .senses }
    /// Senses never leaves the phone.
    var accounts: Bool { self != .senses }
}

/// A provider as the Models page lists it: one of the hosted types, one custom provider, or Local.
enum ProviderRef: Hashable, Identifiable {
    case account(ModelProvider)
    case custom(UUID)
    case local

    var id: String {
        switch self {
        case .account(let provider): provider.rawValue
        case .custom(let id): "custom." + id.uuidString
        case .local: "local"
        }
    }

    var name: String {
        switch self {
        case .account(let provider): provider.name
        case .custom(let id): CustomProviders.provider(id)?.displayName ?? ModelProvider.custom.name
        case .local: AppLocalization.text(LocalizedStringResource("Local"))
        }
    }

    /// The uses this provider can serve.
    var uses: [ModelUse] {
        switch self {
        case .local: [.decision, .senses]
        case .custom: [.chat, .voice, .decision]
        case .account(let provider):
            ModelUse.allCases.filter { use in
                switch use {
                case .chat: ModelAccounts.canChat(provider)
                case .voice: provider == .openai
                case .decision: AccountDecisions.canDecide(provider)
                case .senses: false
                }
            }
        }
    }

    /// Every provider on the page: Local first, always there, then the hosted ones set up, then each
    /// custom provider.
    static var all: [ProviderRef] {
        [.local]
            + ModelProvider.allCases.filter { $0 != .custom && ModelAccounts.isSetUp($0) }.map(ProviderRef.account)
            + CustomProviders.all.map { .custom($0.id) }
    }
}

// MARK: Local models

/// A model on this iPhone: Apple's own, or one of the models that can be downloaded.
enum LocalModel: Hashable, Identifiable {
    case apple
    case downloaded(String)

    var id: String {
        switch self {
        case .apple: "apple"
        case .downloaded(let choice): "downloaded." + choice
        }
    }

    @MainActor var name: String {
        switch self {
        case .apple: AppLocalization.text(LocalizedStringResource("Apple Intelligence"))
        case .downloaded(let choice): BacktapeModel.choices.first { $0.id == choice }?.name ?? choice
        }
    }

    /// It is on the phone and can run now.
    @MainActor var onPhone: Bool {
        switch self {
        case .apple: AppleIntelligence.status == .available
        case .downloaded(let choice):
            BacktapeModel.supported && BacktapeModel.shared.ready && BacktapeModel.shared.choice.id == choice
        }
    }
}

/// Whether this iPhone has Apple Intelligence, and if not, why.
enum AppleIntelligence: Equatable {
    case available
    /// The iPhone can run it, but it is turned off in Settings.
    case turnedOff
    /// It is on and its model is still downloading.
    case notReady
    /// The iPhone, or its iOS, has none.
    case unsupported

    static var status: AppleIntelligence {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .unsupported
            }
        }
        #endif
        return .unsupported
    }
}

enum LocalModels {
    /// The local models on the phone now.
    @MainActor static var onPhone: [LocalModel] {
        var out: [LocalModel] = []
        if LocalModel.apple.onPhone { out.append(.apple) }
        if BacktapeModel.supported, BacktapeModel.shared.ready { out.append(.downloaded(BacktapeModel.shared.choice.id)) }
        return out
    }

    private static func offeredKey(_ use: ModelUse) -> String { "local.offered.\(use.rawValue)" }

    /// The local models a use's picker offers: all of them until the owner unticks one.
    static func offered(_ use: ModelUse) -> Set<String>? {
        UserDefaults.standard.stringArray(forKey: offeredKey(use)).map(Set.init)
    }

    @MainActor static func isOffered(_ model: LocalModel, for use: ModelUse) -> Bool {
        offered(use)?.contains(model.id) ?? true
    }

    @MainActor static func setOffered(_ model: LocalModel, _ on: Bool, for use: ModelUse) {
        var ids = offered(use) ?? Set(onPhone.map(\.id))
        if on { ids.insert(model.id) } else { ids.remove(model.id) }
        UserDefaults.standard.set(Array(ids), forKey: offeredKey(use))
        // A use's model is always one its picker offers.
        if !on, ModelPicks.current(use) == .local(model) { ModelPicks.pick(.off, for: use) }
        ModelKeys.saved += 1
    }

    @MainActor static func available(for use: ModelUse) -> [LocalModel] {
        onPhone.filter { isOffered($0, for: use) }
    }

    /// The model offered first where the iPhone has no Apple Intelligence: the smaller one.
    @MainActor static var recommended: BacktapeModel.Choice { BacktapeModel.choices[0] }

    private static let useWhenReadyKey = "local.useWhenReady"

    /// Downloads the recommended model, to decide and write Senses' notes once it is on the phone.
    @MainActor static func downloadRecommended() {
        let model = BacktapeModel.shared
        if model.choice != recommended {
            if QuickFixes.choice == .downloaded { QuickFixes.choice = .none }
            model.choice = recommended
        }
        UserDefaults.standard.set(true, forKey: useWhenReadyKey)
        model.download()
        if model.ready { downloadFinished() }
    }

    /// Called when a download finishes: a model downloaded from the recommendation takes over the
    /// decisions where none was picked.
    @MainActor static func downloadFinished() {
        guard UserDefaults.standard.bool(forKey: useWhenReadyKey) else { return }
        UserDefaults.standard.removeObject(forKey: useWhenReadyKey)
        if QuickFixes.choice == .none { QuickFixes.choice = .downloaded }
        ModelKeys.saved += 1
    }

    /// The recommendation is shown: no Apple Intelligence, no downloaded model yet, and the iPhone can
    /// run one.
    @MainActor static var recommends: Bool {
        AppleIntelligence.status != .available && BacktapeModel.supported && !BacktapeModel.shared.ready
    }
}

/// The local model that writes Senses' notes: the owner's pick, else Apple Intelligence, else the
/// downloaded model. Nothing it is given leaves the phone.
enum SensesLocalModel {
    private static let key = "senses.model"

    @MainActor static var current: LocalModel? {
        let saved = UserDefaults.standard.string(forKey: key)
        if saved == "off" { return nil }
        let models = LocalModels.available(for: .senses)
        if let saved, let match = models.first(where: { $0.id == saved || (saved == "downloaded" && $0 != .apple) }) { return match }
        return models.first
    }

    @MainActor static func set(_ model: LocalModel?) {
        UserDefaults.standard.set(model.map { $0 == .apple ? "apple" : "downloaded" } ?? "off", forKey: key)
        ModelKeys.saved += 1
    }
}

// MARK: Decisions on an account

/// The models of an account that its Decisions picker offers: Luna and the fast models until the
/// owner ticks others.
enum DecisionOffers {
    private static func key(_ provider: ModelProvider) -> String { "decisions.offered.\(provider.rawValue)" }

    static func offered(_ provider: ModelProvider) -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: key(provider)) { return Set(saved) }
        let models = AccountDecisions.models(provider)
        let picked = models.filter { $0.id == AccountDecisions.luna || ModelCatalog.recommended($0.id) }.map(\.id)
        // Each custom provider's own model.
        let own = provider == .custom ? ModelProvider.customChoices(CustomProviders.all).map(\.id) : []
        return Set(picked + own)
    }

    @MainActor static func set(_ id: String, on: Bool, for provider: ModelProvider) {
        var ids = offered(provider)
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: key(provider))
        if !on, QuickFixes.accountModel(provider) == id { QuickFixes.pickAccount(provider, model: nil) }
        ModelKeys.saved += 1
    }

    static func available(_ provider: ModelProvider) -> [ChatModelChoice] {
        let on = offered(provider)
        return AccountDecisions.models(provider).filter { on.contains($0.id) }
    }
}

// MARK: The pickers

/// One choice in a use's picker.
enum ModelPick: Hashable {
    case off
    case local(LocalModel)
    case account(ModelProvider, String)
    case voice(VoiceAccount, String)
}

/// A provider's section in a picker.
struct ModelGroup: Identifiable {
    struct Item: Identifiable {
        var name: String
        var pick: ModelPick
        var id: ModelPick { pick }
    }
    var id: String
    var name: String
    var items: [Item]
}

enum ModelPicks {
    /// A custom provider's models among the chat's custom ones, named by their own id.
    private static func split(_ choices: [ChatModelChoice], _ custom: CustomProvider, as pick: (String) -> ModelPick) -> [ModelGroup.Item] {
        choices.compactMap { choice in
            guard let parsed = CustomProviders.parse(choice.id), parsed.provider == custom.id else { return nil }
            return ModelGroup.Item(name: parsed.model, pick: pick(choice.id))
        }
    }

    /// A use's sections, one per provider, each with the models ticked under it.
    @MainActor static func groups(_ use: ModelUse) -> [ModelGroup] {
        var groups: [ModelGroup] = []
        if use.local {
            let items = LocalModels.available(for: use).map { ModelGroup.Item(name: $0.name, pick: .local($0)) }
            if !items.isEmpty { groups.append(ModelGroup(id: "local", name: ProviderRef.local.name, items: items)) }
        }
        guard use.accounts else { return groups }
        for ref in ProviderRef.all {
            switch ref {
            case .local: continue
            case .account(let provider):
                guard ref.uses.contains(use) else { continue }
                let items: [ModelGroup.Item]
                switch use {
                case .chat: items = ModelCatalog.available(provider).map { .init(name: $0.name, pick: .account(provider, $0.id)) }
                case .voice: items = ModelCatalog.voiceOffered(for: .openai).map { .init(name: $0.name, pick: .voice(.openai, $0.id)) }
                case .decision: items = DecisionOffers.available(provider).map { .init(name: $0.name, pick: .account(provider, $0.id)) }
                case .senses: items = []
                }
                if !items.isEmpty { groups.append(ModelGroup(id: ref.id, name: ref.name, items: items)) }
            case .custom(let id):
                guard let custom = CustomProviders.provider(id) else { continue }
                let items: [ModelGroup.Item]
                switch use {
                case .chat: items = split(ModelCatalog.available(.custom), custom) { .account(.custom, $0) }
                case .voice:
                    // Only a service whose list has Realtime models, or that already runs live voice.
                    let listed = !(UserDefaults.standard.stringArray(forKey: "models.listed.voice.custom.\(id.uuidString)") ?? []).isEmpty
                    items = listed || VoiceDirect.isOn(.custom(id))
                        ? ModelCatalog.voiceOffered(for: .custom(id)).map { .init(name: $0.name, pick: .voice(.custom(id), $0.id)) } : []
                case .decision: items = split(DecisionOffers.available(.custom), custom) { .account(.custom, $0) }
                case .senses: items = []
                }
                if !items.isEmpty { groups.append(ModelGroup(id: ref.id, name: ref.name, items: items)) }
            }
        }
        return groups
    }

    /// What a use runs on now.
    @MainActor static func current(_ use: ModelUse) -> ModelPick {
        switch use {
        case .chat:
            return ModelKeys.hasUsableKey ? .account(ModelKeys.selectedProvider, ModelKeys.selectedModel) : .off
        case .voice:
            guard let account = VoiceDirect.account else { return .off }
            return .voice(account, ModelCatalog.voiceModelID(for: account))
        case .decision:
            switch QuickFixes.choice {
            case .none: return .off
            case .apple: return .local(.apple)
            case .downloaded: return .local(.downloaded(BacktapeModel.shared.choice.id))
            case .account: return QuickFixes.accountPick.map { .account($0.provider, $0.model) } ?? .off
            }
        case .senses:
            return SensesLocalModel.current.map(ModelPick.local) ?? .off
        }
    }

    /// Makes `pick` the model of `use`.
    @MainActor static func pick(_ pick: ModelPick, for use: ModelUse) {
        switch (use, pick) {
        case (.chat, .account(let provider, let id)):
            ModelKeys.selectedProvider = provider
            ModelKeys.selectedModel = id
        case (.voice, .voice(let account, let id)):
            ModelCatalog.setVoiceModelID(id, for: account)
            VoiceDirect.set(account, on: true)
        case (.voice, .off):
            if let account = VoiceDirect.account { VoiceDirect.set(account, on: false) }
        case (.decision, .local(.apple)): QuickFixes.choice = .apple
        case (.decision, .local(.downloaded)): QuickFixes.choice = .downloaded
        case (.decision, .account(let provider, let id)): QuickFixes.pickAccount(provider, model: id)
        case (.decision, .off): QuickFixes.choice = .none
        case (.senses, .local(let model)): SensesLocalModel.set(model)
        case (.senses, .off): SensesLocalModel.set(nil)
        default: return
        }
        ModelKeys.saved += 1
    }

    /// The name of what a use runs on, for a provider's row.
    @MainActor static func name(_ use: ModelUse) -> String? {
        let pick = current(use)
        return groups(use).flatMap(\.items).first { $0.pick == pick }?.name
    }
}

/// A use's picker on the Models page: Off (where a use can be off) and each provider's ticked models
/// in a section of its own.
struct ModelUsePicker: View {
    var use: ModelUse
    /// The page's count of changes: a new pick or tick redraws the picker.
    var version: Int

    var body: some View {
        let groups = ModelPicks.groups(use)
        Picker(selection: Binding(get: { ModelPicks.current(use) }, set: { ModelPicks.pick($0, for: use) })) {
            if use != .chat || groups.isEmpty {
                Text(use == .chat ? LocalizedStringKey("No Model") : LocalizedStringKey("Off")).tag(ModelPick.off)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { Text(verbatim: $0.name).tag($0.pick) }
                } header: {
                    Group {
                        Text(verbatim: group.name)
                    }
                    .settingsHeader()
                }
            }
        } label: {
            SettingsLabel(use.title, systemImage: use.symbol)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("models.use.\(use.rawValue)")
    }
}

// MARK: A provider's tick lists

/// Provider › a use: the provider's models that the use's picker offers, ticked or not. Which one runs
/// is chosen on the Models page.
struct ModelTickList: View {
    var use: ModelUse
    var provider: ProviderRef
    @State private var version = ModelKeys.saved
    @State private var loading = false
    @State private var problem: String?
    @State private var adding = false
    @State private var typed = ""

    struct Row: Identifiable {
        var id: String
        var name: String
        var fast: Bool
        var on: Bool
    }

    var body: some View {
        Form {
            Section {
                let rows = self.rows
                if rows.isEmpty {
                    Text(emptyText).foregroundStyle(Color(.secondaryLabel))
                }
                ForEach(rows) { row in
                    Button { toggle(row) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: row.name).foregroundStyle(Color(.label))
                                if row.fast { Text("Fast").font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel)) }
                            }
                            Spacer()
                            if row.on { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(row.on ? .isSelected : [])
                }
                if refreshes {
                    Button(loading ? "Reading the Model List…" : "Refresh Model List") { refresh() }.disabled(loading)
                }
                if case .custom = provider, use == .chat {
                    Button("Add Model", systemImage: "plus") { typed = ""; adding = true }
                }
            } header: {
                Group {
                    Text("Models to Choose From")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text(problem ?? footer)
                }
                .settingsFooter()
            }
        }
        // Reads the version so the page redraws with the new ticks, without rebuilding it.
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(Text(use.title))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .task {
            // A list that is missing or a day old is read again, so the provider's new models show up.
            if refreshes, listEmpty || stale { refresh() }
        }
        .alert("Add Model", isPresented: $adding) {
            TextField("Model ID", text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { addTyped() }
        } message: {
            Text("Enter the model’s ID as the service names it.")
        }
    }

    private var rows: [Row] {
        switch (provider, use) {
        case (.local, _):
            return LocalModels.onPhone.map { Row(id: $0.id, name: $0.name, fast: false, on: LocalModels.isOffered($0, for: use)) }
        case (.account(let p), .chat):
            let on = ModelCatalog.enabled(p)
            return ModelCatalog.all(p).map { Row(id: $0.id, name: $0.name, fast: ModelCatalog.fast($0.id), on: on.contains($0.id)) }
        case (.custom(let id), .chat):
            let on = ModelCatalog.enabled(.custom)
            return ModelCatalog.all(custom: id).map { Row(id: $0.id, name: CustomProviders.parse($0.id)?.model ?? $0.name, fast: ModelCatalog.fast($0.id), on: on.contains($0.id)) }
        case (.account, .voice), (.custom, .voice):
            let account = voiceAccount
            let on = ModelCatalog.voiceOn(for: account)
            return ModelCatalog.voiceChoices(for: account).map { Row(id: $0.id, name: $0.name, fast: false, on: on.contains($0.id)) }
        case (.account(let p), .decision):
            let on = DecisionOffers.offered(p)
            return AccountDecisions.models(p).map { Row(id: $0.id, name: $0.name, fast: ModelCatalog.fast($0.id), on: on.contains($0.id)) }
        case (.custom(let id), .decision):
            let on = DecisionOffers.offered(.custom)
            return AccountDecisions.models(.custom).compactMap { choice in
                guard let parsed = CustomProviders.parse(choice.id), parsed.provider == id else { return nil }
                return Row(id: choice.id, name: parsed.model, fast: ModelCatalog.fast(parsed.model), on: on.contains(choice.id))
            }
        default:
            return []
        }
    }

    private var voiceAccount: VoiceAccount {
        if case .custom(let id) = provider { return .custom(id) }
        return .openai
    }

    private func toggle(_ row: Row) {
        let on = !row.on
        switch (provider, use) {
        case (.local, _):
            if let model = LocalModels.onPhone.first(where: { $0.id == row.id }) { LocalModels.setOffered(model, on, for: use) }
        case (.account(let p), .chat): ModelCatalog.set(row.id, on: on, for: p)
        case (.custom, .chat): ModelCatalog.set(row.id, on: on, for: .custom)
        case (_, .voice):
            ModelCatalog.setVoice(row.id, on: on, for: voiceAccount)
            // The last voice model unticked turns this account's live voice off.
            if !on, ModelCatalog.voiceOn(for: voiceAccount).isEmpty, VoiceDirect.isOn(voiceAccount) { VoiceDirect.set(voiceAccount, on: false) }
        case (.account(let p), .decision): DecisionOffers.set(row.id, on: on, for: p)
        case (.custom, .decision): DecisionOffers.set(row.id, on: on, for: .custom)
        default: break
        }
    }

    private var refreshes: Bool {
        switch provider {
        case .local: false
        // A ChatGPT sign-in has a model list only through Codex.
        case .account(let p): (p != .chatgpt || ModelCatalog.listable().contains(.chatgpt)) && use != .decision
        case .custom: use != .decision
        }
    }

    private var stale: Bool {
        guard case .account(let p) = provider else { return false }
        return ModelCatalog.isStale(p) && !ModelCatalog.isBackingOff(p)
    }

    private var listEmpty: Bool {
        switch provider {
        case .local: false
        case .account(let p): ModelCatalog.listed(p).isEmpty
        case .custom(let id): ModelCatalog.listedCustom(id).isEmpty
        }
    }

    private var emptyText: LocalizedStringKey {
        if case .local = provider { return "No model is on this iPhone yet. Download one under Models." }
        return "No models yet."
    }

    private var footer: String {
        switch use {
        case .chat: AppLocalization.text(LocalizedStringResource("Ticked models are offered under Chat on the Models page and on Poki’s card. Fast models without long thinking answer quickest on the phone."))
        case .voice: AppLocalization.text(LocalizedStringResource("Ticked models are offered under Voice on the Models page. Live voice needs the Realtime API."))
        case .decision: AppLocalization.text(LocalizedStringResource("Ticked models are offered under Decisions on the Models page. A small, fast model works best."))
        case .senses: AppLocalization.text(LocalizedStringResource("Ticked models are offered under Senses on the Models page. Senses only runs on this iPhone."))
        }
    }

    private func refresh() {
        loading = true
        problem = nil
        let name = provider.name
        Task {
            do {
                switch provider {
                case .account(let p): _ = try await ModelCatalog.refresh(p)
                case .custom(let id): _ = try await ModelCatalog.refresh(custom: id)
                case .local: break
                }
            }
            catch is CancellationError { /* The provider changed while loading. */ }
            catch let error as ModelCatalog.DiscoveryError { problem = error.message }
            catch { problem = AppLocalization.text(LocalizedStringResource("\(name) didn’t return its model list. The built-in models still work.")) }
            loading = false
        }
    }

    private func addTyped() {
        let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .custom(let id) = provider, !model.isEmpty, var custom = CustomProviders.provider(id) else { return }
        if custom.model.isEmpty { custom.model = model } else if custom.model != model, !(custom.added ?? []).contains(model) {
            custom.added = (custom.added ?? []) + [model]
        }
        CustomProviders.upsert(custom)
        ModelCatalog.set(CustomProviders.choiceID(id, model), on: true, for: .custom)
    }
}
