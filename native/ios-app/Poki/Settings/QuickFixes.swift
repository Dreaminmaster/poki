#if canImport(FoundationModels)
import FoundationModels
#endif
import PokiCore
import SwiftUI

/// The decision model: a small, fast model which a routine or a path asks how to go on where it would
/// otherwise stop (a prompt in the way, a button renamed or moved). It is a model on this iPhone
/// (Apple Intelligence), or the owner's own provider (Cloudflare's Clef, TypeSafe's Jev, OpenAI's
/// Decisions API, or one they host). There is no switch: it is picked on Settings › Models beside the
/// other models and in use from then, until the pick is set back to Off. A provider's call goes from
/// this iPhone straight to that provider, never through Poki's relay, and holds the task's goal and
/// the screen's elements as text: no screenshot, and nothing a password field holds.
///
/// The settings are in the app's defaults; the token is in the keychain and is never printed or logged.
enum QuickFixes {
    private static let settingsKey = "quickFixes.settings"
    private static let tokenAccount = "quick-fixes.token"

    static var settings: DeciderSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsKey), let saved = try? JSONDecoder().decode(DeciderSettings.self, from: data) else { return DeciderSettings() }
            return saved
        }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: settingsKey) } }
    }

    static var token: String {
        get { (try? Keychain.read(tokenAccount)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(tokenAccount) } else { try? Keychain.write(Data(trimmed.utf8), account: tokenAccount) }
        }
    }

    /// Which model decides. A model on this iPhone needs no provider; a provider's model is the one
    /// picked on its page (`settings.model`).
    enum Choice: Hashable {
        case none
        /// Apple's own model, where Apple Intelligence is on the iPhone.
        case apple
        /// The model downloaded to this iPhone (BacktapeModel).
        case downloaded
        /// The provider's model named in the settings.
        case provider
        /// A model of one of the owner's model accounts (`accountPick`).
        case account

        var raw: String {
            switch self {
            case .none: "none"
            case .apple: "apple"
            case .downloaded: "downloaded"
            case .provider: "provider"
            case .account: "account"
            }
        }

        init?(raw: String) {
            switch raw {
            case "none": self = .none
            case "apple": self = .apple
            case "downloaded": self = .downloaded
            case "provider": self = .provider
            case "account": self = .account
            default: return nil
            }
        }
    }

    private static let choiceKey = "quickFixes.choice"

    /// The pick. Before one was ever made, a provider with a model picked counts as picked.
    static var choice: Choice {
        get {
            if let raw = UserDefaults.standard.string(forKey: choiceKey), let kept = Choice(raw: raw) { return kept }
            return settings.hasModel && providerDecider != nil ? .provider : .none
        }
        set { UserDefaults.standard.set(newValue.raw, forKey: choiceKey) }
    }

    private static let accountProviderKey = "quickFixes.account.provider"
    private static let accountModelKey = "quickFixes.account.model"

    /// The account and its model that decide while the pick is an account's (set on the account's
    /// own page, Settings › Models › the account › Decisions).
    static var accountPick: (provider: ModelProvider, model: String)? {
        guard let raw = UserDefaults.standard.string(forKey: accountProviderKey), let provider = ModelProvider(rawValue: raw),
              let model = UserDefaults.standard.string(forKey: accountModelKey), !model.isEmpty else { return nil }
        return (provider, model)
    }

    /// The model of `provider` that is the decision model now, if one of its models is.
    static func accountModel(_ provider: ModelProvider) -> String? {
        guard choice == .account, let pick = accountPick, pick.provider == provider else { return nil }
        return pick.model
    }

    /// Picks an account's model as the decision model; nil turns it off when this account's was.
    static func pickAccount(_ provider: ModelProvider, model: String?) {
        if let model {
            UserDefaults.standard.set(provider.rawValue, forKey: accountProviderKey)
            UserDefaults.standard.set(model, forKey: accountModelKey)
            choice = .account
        } else if accountModel(provider) != nil {
            choice = .none
        }
        ModelKeys.saved += 1
    }

    /// One row of the Decision Model menu.
    struct Option: Hashable, Identifiable {
        var choice: Choice
        /// The provider's model this row stands for; empty for the others.
        var model = ""
        var name: String
        var id: String { choice.raw + ":" + model }
    }

    /// What can be picked now: off, the model on this iPhone where there is one, and the models of
    /// the provider that has been added.
    @MainActor
    static var options: [Option] {
        var out = [Option(choice: .none, name: AppLocalization.text("Off"))]
        if OnDeviceDecisions.appleAvailable { out.append(Option(choice: .apple, name: AppLocalization.text("Apple Intelligence"))) }
        if let name = OnDeviceDecisions.downloadedName { out.append(Option(choice: .downloaded, name: name)) }
        if choice == .account, let account = accountOption { out.append(account) }
        let settings = settings
        if providerDecider != nil {
            var models = DeciderSettings.models(settings.provider)
            if settings.hasModel, !models.contains(settings.modelInUse) { models.append(settings.modelInUse) }
            out += models.map { Option(choice: .provider, model: $0, name: $0) }
        }
        return out
    }

    /// The row that is picked now.
    @MainActor
    static var picked: Option {
        let all = options
        switch choice {
        case .none: return all[0]
        case .apple: return all.first { $0.choice == .apple } ?? all[0]
        case .downloaded: return all.first { $0.choice == .downloaded } ?? all[0]
        case .provider: return all.first { $0.choice == .provider && $0.model == settings.modelInUse && settings.hasModel } ?? all[0]
        case .account: return all.first { $0.choice == .account } ?? all[0]
        }
    }

    /// The account's model as a row of the menu, while it is the pick and its account is still there.
    private static var accountOption: Option? {
        guard let pick = accountPick, ModelAccounts.isSetUp(pick.provider) else { return nil }
        return Option(choice: .account, model: pick.model, name: AccountDecisions.name(pick.provider, pick.model))
    }

    static func pick(_ option: Option) {
        if option.choice == .provider {
            var changed = settings
            changed.model = option.model
            settings = changed
        }
        choice = option.choice
    }

    /// The decider PokiCore asks, read at each run: nil while the pick is Off or cannot run.
    static var decider: Decider? {
        switch choice {
        case .none: return nil
        case .apple: return OnDeviceDecisions.apple
        case .downloaded: return OnDeviceDecisions.downloaded
        case .provider: return settings.hasModel ? providerDecider : nil
        case .account: return accountPick.flatMap { AccountDecisions.decider($0.provider, model: $0.model) }
        }
    }

    /// The provider's decider, with or without a model picked; nil while its settings are incomplete.
    static var providerDecider: SystemOneDecider? { settings.decider(token: tokenInUse(settings, typed: token)) }

    /// The token a call carries: the one entered here, else for OpenAI the API key already saved on
    /// Settings › Models, which is the same key. A ChatGPT sign-in is not used: OpenAI answers 401 to
    /// its token on the Decisions API (tried on the owner's phone, 2026-11-18).
    static func tokenInUse(_ settings: DeciderSettings, typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, settings.provider == .openai { return ModelKeys.key(.openai) ?? "" }
        return typed
    }

    /// Whether a provider has been added, with or without a model picked.
    static var hasProvider: Bool { providerDecider != nil }

    static func remove() {
        token = ""
        settings = DeciderSettings()
        if choice == .provider { choice = .none }
    }
}

/// The models on this iPhone that can decide: nothing of the task or the screen leaves the phone.
enum OnDeviceDecisions {
    /// Apple's own model, where Apple Intelligence is on the iPhone.
    static var appleAvailable: Bool { BacktapeWriter.apple }

    static var apple: PromptDecider? {
        guard appleAvailable else { return nil }
        return PromptDecider(name: "Apple Intelligence", maxState: 5000) { prompt, instructions in await askApple(prompt, instructions: instructions) }
    }

    /// The downloaded model's name once it is on the phone and can run; nil until then.
    @MainActor
    static var downloadedName: String? {
        BacktapeModel.supported && BacktapeModel.shared.ready ? BacktapeModel.shared.choice.name : nil
    }

    /// The downloaded model as the decider. Its files are checked when it is asked: a model removed
    /// since gives no answer, which is an error and never a guess.
    static var downloaded: PromptDecider? {
        guard BacktapeModel.supported else { return nil }
        return PromptDecider(name: "downloaded model", maxState: 5000, patience: 15) { prompt, instructions in
            await BacktapeModel.shared.respond(to: prompt, instructions: instructions, maxTokens: 160, temperature: 0)
        }
    }

    private static func askApple(_ prompt: String, instructions: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(to: prompt).content
            } catch {
                await AppLog.shared.add("decisions", "Apple Intelligence gave no decision: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}

/// Settings › Models: the Decision Model menu, and the way to the providers' page. `picked` is the
/// page's, so the In Use card above shows the same pick.
struct DecisionModelRows: View {
    @Binding var picked: QuickFixes.Option
    @State private var options = QuickFixes.options

    var body: some View {
        Picker(selection: $picked) {
            ForEach(options) { Text(verbatim: $0.name).tag($0) }
        } label: {
            SettingsLabel("Decision Model", systemImage: "bolt")
        }
        .accessibilityIdentifier("models.decisionModel")
        .onChange(of: picked) { _, new in QuickFixes.pick(new) }
        NavigationLink { QuickFixesView() } label: { SettingsLabel("Decision Model Providers", systemImage: "cloud") }
            .accessibilityIdentifier("models.fastDecisions")
            .onAppear(perform: refresh)
            // The downloaded model joins the menu when its download ends, and leaves it when removed.
            .onChange(of: BacktapeModel.shared.state) { _, _ in refresh() }
            // An account's own page picked or dropped its model as the decision model.
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in refresh() }
    }

    /// Back from the providers' page, or a download ended: the models, and the pick, may have changed.
    private func refresh() {
        options = QuickFixes.options
        picked = QuickFixes.picked
    }
}

/// Settings › Models: the model the owner can download to this iPhone. It is offered whether or not
/// the iPhone has Apple Intelligence.
struct DownloadedModelSection: View {
    let model = BacktapeModel.shared

    var body: some View {
        if BacktapeModel.supported {
            Section {
                Picker(selection: Binding(get: { model.choice.id }, set: { id in
                    if let picked = BacktapeModel.choices.first(where: { $0.id == id }) { model.choice = picked }
                })) {
                    ForEach(BacktapeModel.choices) { choice in
                        Text(verbatim: "\(choice.name), \(ByteCountFormatter.string(fromByteCount: choice.bytes, countStyle: .file))").tag(choice.id)
                    }
                } label: {
                    SettingsLabel("Model", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("models.downloaded.choice")
                switch model.state {
                case .missing, .failed:
                    Button("Download Model") { model.download() }
                        .accessibilityIdentifier("models.downloaded.download")
                case .downloading(let part):
                    LabeledContent {
                        Text(verbatim: "\(Int(part * 100)) %").monospacedDigit()
                    } label: {
                        ProgressView(value: part)
                    }
                    Button("Cancel Download") { model.cancel() }
                case .ready:
                    Button("Remove Model", role: .destructive) { model.remove() }
                        .accessibilityIdentifier("models.downloaded.remove")
                }
            } header: {
                Text("Downloaded Model").textCase(nil)
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: LocalizedStringKey {
        switch model.state {
        case .ready:
            "This model is on this iPhone and runs here. Pick it as the decision model above. Screen History uses it for its notes where the iPhone has no Apple Intelligence. Nothing is sent anywhere."
        case .failed:
            "The download did not finish. Try again on Wi-Fi, and it goes on where it stopped."
        default:
            "Download a small model to run on this iPhone, with or without Apple Intelligence. It can be the decision model, and it writes Screen History’s notes where the iPhone has no Apple Intelligence. Only one model is kept, and picking another removes the one before. Nothing is sent anywhere."
        }
    }
}

extension DeciderSettings.Provider {
    var title: LocalizedStringKey {
        switch self {
        case .cloudflare: "Cloudflare Workers AI"
        case .typesafe: "TypeSafe"
        case .openai: "OpenAI"
        case .custom: "Custom Address"
        }
    }
}

/// Settings › Models › Fast Decisions: the provider, its token and the model. Picking a model turns
/// fast decisions on; None turns them off.
struct QuickFixesView: View {
    @State private var settings = QuickFixes.settings
    @State private var token = QuickFixes.token
    @State private var checking = false
    @State private var result: CheckResult?
    @State private var fixed = 0
    @State private var confirmRemove = false

    private enum CheckResult: Equatable {
        case works(Int)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.provider) {
                    ForEach(DeciderSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Provider", systemImage: "cloud")
                }
                switch settings.provider {
                case .cloudflare:
                    field("Account ID", text: $settings.account, prompt: "0123456789abcdef", identifier: "quickFixes.account")
                case .custom:
                    field("Address", text: $settings.address, prompt: "https://example.com/v1/systemone", identifier: "quickFixes.address", url: true)
                case .typesafe, .openai:
                    EmptyView()
                }
                LabeledContent {
                    SecureField(text: $token, prompt: Text(tokenPrompt)) { Text("API Token") }
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("quickFixes.token")
                } label: {
                    Text("API Token")
                }
            } header: {
                SettingsHeader("Provider")
            } footer: {
                Text("The request goes from this iPhone straight to this provider with your own token. It holds the goal of the task and the names of the elements on screen. No screenshot is sent and password fields are left out. The token stays in this iPhone’s keychain.")
            }

            Section {
                if settings.provider == .custom {
                    field("Model", text: $settings.model, prompt: AppLocalization.text("None"), identifier: "quickFixes.model")
                } else {
                    Picker(selection: $settings.model) {
                        Text("None").tag("")
                        ForEach(DeciderSettings.models(settings.provider), id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: {
                        SettingsLabel("Model", systemImage: "bolt")
                    }
                    .disabled(!hasProvider)
                    .accessibilityIdentifier("quickFixes.model")
                }
            } header: {
                SettingsHeader("Fast Decision Model")
            } footer: {
                Text("Poki uses this model from the moment you pick it, here or on the Models page. Choose None to stop using it.")
            }

            Section {
                Button(action: check) {
                    HStack {
                        SettingsLabel("Check Connection", systemImage: "bolt.horizontal")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(!hasProvider || checking)
                .accessibilityIdentifier("quickFixes.check")
                if fixed > 0 { LabeledContent("Steps Fixed", value: fixed.formatted()) }
            } footer: {
                switch result {
                case .works(let ms): Text("It answered in \(ms) ms.").foregroundStyle(Tint.green)
                case .failed(let why): Text(verbatim: why).foregroundStyle(.red)
                case nil: EmptyView()
                }
            }

            if hasProvider {
                Section {
                    Button("Remove Provider", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("quickFixes.remove")
                }
            }
        }
        .navigationTitle(AppLocalization.text("Decision Model Providers"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fixed = RoutineStore.shared.routines.reduce(0) { $0 + ($1.fixes ?? 0) } }
        .onChange(of: settings) { old, new in
            var new = new
            // Another provider's models are its own: the pick starts again at None.
            if old.provider != new.provider, new.provider != .custom, !DeciderSettings.models(new.provider).contains(new.model) {
                new.model = ""
                settings = new
            }
            QuickFixes.settings = new
            // Picking a model here picks it as the decision model; None gives the pick up.
            if new.hasModel, old.model != new.model || old.provider != new.provider { QuickFixes.choice = .provider }
            if !new.hasModel, QuickFixes.choice == .provider { QuickFixes.choice = .none }
            result = nil
        }
        .onChange(of: token) { _, new in
            QuickFixes.token = new
            result = nil
        }
        .confirmationDialog("Remove this provider and its token from this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Provider", role: .destructive) {
                QuickFixes.remove()
                settings = QuickFixes.settings
                token = ""
            }
        }
    }

    private var hasProvider: Bool { providerDecider != nil }
    private var providerDecider: SystemOneDecider? { settings.decider(token: QuickFixes.tokenInUse(settings, typed: token)) }

    /// OpenAI can go on the API key already saved on the Models page.
    private var tokenPrompt: LocalizedStringKey {
        if settings.provider == .custom { return "Optional" }
        if settings.provider == .openai, ModelKeys.hasKey(.openai) { return "Uses Your OpenAI Key" }
        return "Required"
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, identifier: String, url: Bool = false) -> some View {
        LabeledContent {
            TextField(text: text, prompt: Text(verbatim: prompt)) { Text(title) }
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .keyboardType(url ? .URL : .asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
        } label: {
            Text(title)
        }
    }

    private func check() {
        guard let decider = providerDecider else { return }
        checking = true
        result = nil
        Task {
            let outcome = await decider.check()
            checking = false
            switch outcome {
            case .success(let ms): result = .works(ms)
            case .failure(let error): result = .failed(AppLocalization.text(LocalizedStringResource("The check failed. \(error.description)")))
            }
        }
    }
}
