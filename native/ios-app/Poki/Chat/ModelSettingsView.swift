// The model page combines two files from lhuanyu/OllamaMessage (commit c857a02), Copyright (c) 2023
// Huanyu Luo, MIT License; see THIRD_PARTY_NOTICES.md:
// - OllamaMessage/Class/View/MessageList/DialogueSettingsView.swift: the "Model" row with its label and a hidden-label
//   Picker on the right;
// - OllamaMessage/Class/View/DialogueList/OllamaModelSelectionView.swift: one row per provider with its 30 pt icon, the
//   whole row tappable, and the footer under the list.
// Changed: the ESP-171 board "M Model" (the grouped rows, the provider tiles, "Add Key"), keys entered
// into the keychain instead of a server's model list, and the agents on a computer below.
import SwiftUI

/// Accounts, as the Mail app lists mail accounts: every model account on this iPhone whatever its
/// provider, each with what it is used for (the text chat, live voice) switched on or off inside it.
/// What an account can power is worked out from its type: any wired provider can run the text chat;
/// live voice needs a Realtime API, which an OpenAI API key or a custom provider's service can open.
/// Each custom provider is an account of its own.
struct ModelSettingsView: View {
    /// Opened from Talk with Poki without a key: the OpenAI key's form at once, or Live Voice when the
    /// key is there but Live Voice is turned off.
    var opensVoiceKey = false
    @State private var adding = false
    @State private var version = ModelKeys.saved
    @State private var enteringVoiceKey = false
    @State private var showingLiveVoice = false
    @State private var openedForVoice = false

    var body: some View {
        List {
            ModelSettingsSections { adding = true }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(AppLocalization.text("Models"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .sheet(isPresented: $adding) { AddAccount() }
        .sheet(isPresented: $enteringVoiceKey) { KeyEntry(provider: .openai) }
        .navigationDestination(isPresented: $showingLiveVoice) { LiveVoiceFeature(account: .openai) }
        .task {
            guard opensVoiceKey, !openedForVoice else { return }
            openedForVoice = true
            if !ModelKeys.hasKey(.openai) { enteringVoiceKey = true } else if VoiceDirect.account == nil { showingLiveVoice = true }
        }
    }
}

/// Shared by Settings and the setup guide. Both use the same installed models and providers.
struct ModelSettingsSections: View {
    var add: () -> Void

    var body: some View {
        // ESP-469 board "02 模型": what runs now, on a card on top, with the way to change the chat's model.
        Section {
            InUseCard(add: add)
        } header: {
            Text("In Use").textCase(nil)
        } footer: {
            Text("Change the chat model in Poki’s menu. Tap the picture on the home page or the name in a conversation. Dictation in the message field needs no account.")
        }

        // With no account yet the card above has Add Account, and an empty group would only be a heading.
        if ModelProvider.allCases.contains(where: ModelAccounts.isSetUp) {
            Section {
                ForEach(ModelProvider.allCases.filter { $0 != .custom && ModelAccounts.isSetUp($0) }) { provider in
                    let usage = ModelAccounts.uses(provider)
                    NavigationLink { AccountDetail(provider: provider) } label: {
                        AccountRow(provider: provider, name: provider.name, usage: usage)
                    }
                }
                ForEach(CustomProviders.all) { custom in
                    let usage = ModelAccounts.uses(custom)
                    NavigationLink { CustomProviderDetail(id: custom.id) } label: {
                        AccountRow(provider: .custom, name: custom.displayName, usage: usage)
                    }
                }
                Button("Add Account", systemImage: "plus") { add() }
            } header: {
                Text("Accounts").textCase(nil)
            } footer: {
                Text("Keys and sign-ins stay in this iPhone’s Keychain. Poki sends each one only to its own provider.")
            }
        }
    }
}

/// What runs now: the chat's model and its account, what the text chat, live voice and dictation each
/// use (main's In Use rows), and Add Account while there is none. The chat model is changed on Poki's
/// card, its one place.
private struct InUseCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var add: () -> Void

    var body: some View {
        let has = ModelKeys.hasUsableKey
        let provider = ModelKeys.selectedProvider
        VStack(alignment: .leading, spacing: 14) {
            let heading = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            heading {
                if has { ProviderTile(provider: provider, size: 44) } else { SettingsIcon(symbol: "sparkles", warns: true, size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: has ? ModelKeys.selectedModelName : AppLocalization.text(LocalizedStringResource("No Account")))
                        .font(.title3.weight(.semibold)).foregroundStyle(Color(.label))
                    if has { Text(verbatim: ModelKeys.selectedAccountName).font(.subheadline).foregroundStyle(Color(.secondaryLabel)) }
                }
            }
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { uses(has: has, provider: provider, singleLine: true) }
                VStack(alignment: .leading, spacing: 6) { uses(has: has, provider: provider, singleLine: false) }
            }
            if !has {
                SettingsPill(title: "Add Account", symbol: "plus", prominent: true, action: add)
                    .accessibilityIdentifier("model.inUse.action")
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func uses(has: Bool, provider: ModelProvider, singleLine: Bool) -> some View {
        chip("Text Chat", has ? ModelKeys.selectedAccountName : AppLocalization.text(LocalizedStringResource("No Account")), singleLine: singleLine)
        chip("Live Voice", VoiceDirect.account?.name ?? AppLocalization.text(LocalizedStringResource("No Account")), singleLine: singleLine)
        chip("Dictation", AppLocalization.text(LocalizedStringResource("On This iPhone")), singleLine: singleLine)
    }

    private func chip(_ title: LocalizedStringKey, _ value: String, singleLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(Color(.secondaryLabel))
            Text(verbatim: value).font(.footnote.weight(.semibold)).foregroundStyle(Color(.label))
        }
        .lineLimit(singleLine ? 1 : nil)
        // Measure the row at its natural width. The stacked fallback can wrap long values.
        .fixedSize(horizontal: singleLine, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Tint.blueSoft.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// What a model account is and what it can power.
enum ModelAccounts {
    static func isSetUp(_ provider: ModelProvider) -> Bool {
        isSetUp(provider, storage: .live)
    }

    static func isSetUp(_ provider: ModelProvider, storage: PokiStorage) -> Bool {
        switch provider {
        case .custom: !CustomProviders.all(in: storage).isEmpty
        case .chatgpt: ChatGPTAccount.isSignedIn(storage: storage)
        default: ModelKeys.hasKey(provider, storage: storage)
        }
    }

    static func canChat(_ provider: ModelProvider) -> Bool { provider.wired }
    static func canTalkLive(_ provider: ModelProvider) -> Bool { provider == .chatgpt || provider == .openai || provider == .custom }

    static func method(_ provider: ModelProvider) -> String {
        switch provider {
        case .chatgpt: AppLocalization.text(LocalizedStringResource("Sign in with ChatGPT"))
        case .custom: AppLocalization.text(LocalizedStringResource("OpenAI-compatible address"))
        default: AppLocalization.text(LocalizedStringResource("API key"))
        }
    }

    /// "Text Chat, Live Voice", "Not in use".
    static func uses(_ provider: ModelProvider) -> String {
        var out: [String] = []
        if ModelKeys.selectedProvider == provider, ModelKeys.hasUsableKey { out.append(AppLocalization.text(LocalizedStringResource("Text Chat"))) }
        if provider == .openai, VoiceDirect.account == .openai { out.append(AppLocalization.text(LocalizedStringResource("Live Voice"))) }
        if provider == .chatgpt, ModelKeys.selectedProvider == .chatgpt, CodexAccount.accessToken != nil {
            out.append(AppLocalization.text("Live Voice"))
        }
        return out.isEmpty ? AppLocalization.text(LocalizedStringResource("Not in use")) : out.joined(separator: ", ")
    }

    /// The same for one custom provider.
    static func uses(_ custom: CustomProvider) -> String {
        var out: [String] = []
        if ModelKeys.selectedProvider == .custom, ModelKeys.hasUsableKey, CustomProviders.parse(ModelKeys.selectedModel)?.provider == custom.id {
            out.append(AppLocalization.text(LocalizedStringResource("Text Chat")))
        }
        if VoiceDirect.account == .custom(custom.id) { out.append(AppLocalization.text(LocalizedStringResource("Live Voice"))) }
        return out.isEmpty ? AppLocalization.text(LocalizedStringResource("Not in use")) : out.joined(separator: ", ")
    }
}

private struct AccountRow: View {
    let provider: ModelProvider
    let name: String
    let usage: String
    var body: some View {
        HStack(spacing: 12) {
            ProviderTile(provider: provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                Text(verbatim: usage).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

struct ConnectionCheckFeedback: View {
    let result: ConnectionCheck.Result
    var api: CustomAPIStyle? = nil
    var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(result.words)
            } icon: {
                Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(result.passed ? Color(.systemGreen) : Color(.systemOrange))
            if let api, result.passed {
                Text(verbatim: AppLocalization.text(LocalizedStringResource("Answered in the \(api.name) API")))
                    .foregroundStyle(Color(.secondaryLabel))
            }
            if let detail = result.detail { Text(verbatim: detail) }
            if saved, !result.passed { Text("Saved. Change it and save again, or keep it as it is.") }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

/// One account: its type and connection, what it is used for (switches; the ones it can't power are
/// shown greyed with why), its model, and Delete.
private struct AccountDetail: View {
    @Environment(\.dismiss) private var dismiss
    var provider: ModelProvider
    @State private var editing = false
    @State private var signingIn = false
    @State private var signOutFailed = false
    @State private var signingOut = false
    @State private var version = ModelKeys.saved

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: provider.name)
                LabeledContent("Connection", value: ModelAccounts.method(provider))
                if provider == .custom { LabeledContent("Address", value: ModelKeys.customURL) }
                Button(provider.signsIn ? "Sign In Again" : provider == .custom ? "Edit Address and Key" : "Replace Key") {
                    if provider.signsIn { signingIn = true } else { editing = true }
                }
            }

            Section {
                NavigationLink { TextChatFeature(provider: provider) } label: {
                    LabeledContent {
                        Text(ModelKeys.selectedProvider == provider ? ModelKeys.selectedModelName : ModelAccounts.canChat(provider) ? AppLocalization.text(LocalizedStringResource("Off")) : AppLocalization.text(LocalizedStringResource("Not Supported")))
                    } label: { SettingsLabel("Text Chat", systemImage: "bubble.left.and.text.bubble.right") }
                }
                .disabled(!ModelAccounts.canChat(provider))
                if provider == .chatgpt {
                    LabeledContent {
                        Text(CodexAccount.accessToken == nil ? AppLocalization.text("Sign In Again") : ModelKeys.selectedProvider == .chatgpt ? "ChatGPT" : AppLocalization.text("Off"))
                    } label: { SettingsLabel("Live Voice", systemImage: "waveform") }
                } else {
                    NavigationLink { LiveVoiceFeature(account: .openai) } label: {
                        LabeledContent {
                            Text(ModelAccounts.canTalkLive(provider) ? (VoiceDirect.isOn(.openai) ? ModelCatalog.voiceModelID(for: .openai) : AppLocalization.text(LocalizedStringResource("Off"))) : AppLocalization.text(LocalizedStringResource("Not Supported")))
                        } label: { SettingsLabel("Live Voice", systemImage: "waveform") }
                    }
                    .disabled(!ModelAccounts.canTalkLive(provider))
                }
            } header: {
                Text("Use This Account For")
            } footer: {
                if !ModelAccounts.canChat(provider) {
                    Text("Poki keeps this key; chatting with \(provider.name) comes in an update.")
                } else if provider == .chatgpt {
                    Text("Poki uses this ChatGPT sign-in for both text chat and live voice.")
                } else if !ModelAccounts.canTalkLive(provider) {
                    Text("Live voice runs on a Realtime API, which an OpenAI API key or a custom endpoint can open. Dictation in the message field works with this account.")
                }
            }

            Section {
                Button(provider.signsIn ? "Sign Out" : "Delete Account", role: .destructive) {
                    if provider.signsIn {
                        signingOut = true
                        Task {
                            defer { signingOut = false }
                            do {
                                try await ChatGPTAccount.signOutIncludingVoice()
                                accountRemoved()
                            } catch {
                                signOutFailed = true
                            }
                        }
                        return
                    } else if provider == .custom, let current = CustomProviders.current {
                        CustomProviders.remove(current.id)
                    } else {
                        ModelKeys.remove(provider)
                    }
                    accountRemoved()
                }
                .disabled(signingOut)
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(Text(verbatim: provider.name))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .sheet(isPresented: $editing, onDismiss: { version = ModelKeys.saved }) { KeyEntry(provider: provider) }
        .sheet(isPresented: $signingIn, onDismiss: { version = ModelKeys.saved }) { ChatGPTSignIn() }
        .alert("Could not sign out of ChatGPT. Try again.", isPresented: $signOutFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func accountRemoved() {
        if ModelKeys.selectedProvider == provider,
           let other = ModelProvider.allCases.first(where: { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
            ModelKeys.selectedProvider = other
        }
        dismiss()
    }
}

/// Account › Text Chat: which of its models Poki's card offers. Which one answers is chosen on the card.
struct TextChatFeature: View {
    var provider: ModelProvider
    /// One custom provider's models only.
    var custom: UUID? = nil
    @State private var version = ModelKeys.saved
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(custom.map { ModelCatalog.all(custom: $0) } ?? ModelCatalog.all(provider)) { choice in
                    Toggle(isOn: Binding(get: { ModelCatalog.enabled(provider).contains(choice.id) }, set: { ModelCatalog.set(choice.id, on: $0, for: provider) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.name)
                            if ModelCatalog.fast(choice.id) { Text("Fast").font(.caption).foregroundStyle(Color(.secondaryLabel)) }
                        }
                    }
                }
                if lists {
                    Button(loading ? "Reading the Model List…" : "Refresh Model List") { refresh() }.disabled(loading)
                }
            } header: {
                Text("Models to Choose From")
            } footer: {
                Text(problem ?? AppLocalization.text(LocalizedStringResource("Fast models without long thinking answer quickest on the phone. Models from \(accountName)’s list start switched off.")))
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(AppLocalization.text("Text Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .task {
            // A list that is missing or a day old is read again, so the provider's new models show up.
            let empty = custom.map { ModelCatalog.listedCustom($0).isEmpty } ?? ModelCatalog.listed(provider).isEmpty
            let list = custom.map(ModelCatalog.ModelList.custom) ?? .provider(provider)
            if lists, empty || ModelCatalog.isStale(list) && !ModelCatalog.isBackingOff(list) { refresh() }
        }
    }

    /// A ChatGPT sign-in has a model list only through Codex.
    private var lists: Bool { provider != .chatgpt || ModelCatalog.listable().contains(.chatgpt) }

    private var accountName: String { custom.flatMap { CustomProviders.provider($0) }?.displayName ?? provider.name }

    private func refresh() {
        loading = true
        problem = nil
        Task {
            do { if let custom { _ = try await ModelCatalog.refresh(custom: custom) } else { _ = try await ModelCatalog.refresh(provider) } }
            catch is CancellationError { /* The account changed while loading. */ }
            catch let error as ModelCatalog.DiscoveryError { problem = error.message }
            catch { problem = AppLocalization.text(LocalizedStringResource("\(accountName) didn’t return its model list. The built-in models still work.")) }
            loading = false
        }
    }
}

/// Account › Live Voice: on or off, the voice model, and which voice models to offer, for OpenAI or a
/// custom provider. One account runs live voice at a time.
struct LiveVoiceFeature: View {
    var account: VoiceAccount
    @State private var version = ModelKeys.saved

    var body: some View {
        Form {
            Section {
                Toggle("Use for Live Voice", isOn: Binding(get: { VoiceDirect.isOn(account) }, set: { VoiceDirect.set(account, on: $0) }))
                if VoiceDirect.isOn(account) {
                    Picker("Voice Model", selection: Binding(get: { ModelCatalog.voiceModelID(for: account) }, set: { ModelCatalog.setVoiceModelID($0, for: account) })) {
                        ForEach(ModelCatalog.voiceOffered(for: account)) { Text($0.name).tag($0.id) }
                    }
                }
            } footer: {
                if account == .openai {
                    Text("Live voice is a spoken conversation with OpenAI’s Realtime model: it listens, taps and types, and answers out loud.")
                } else {
                    Text("Live voice is a spoken conversation with the Realtime API at this service’s first address. It listens, taps and types, and answers out loud. Turn it on only if the service offers the Realtime API.")
                }
            }
            Section {
                ForEach(ModelCatalog.voiceChoices(for: account)) { choice in
                    Toggle(choice.name, isOn: Binding(get: { ModelCatalog.voiceOn(for: account).contains(choice.id) }, set: { ModelCatalog.setVoice(choice.id, on: $0, for: account) }))
                }
            } header: {
                Text("Voice Models to Choose From")
            } footer: {
                Text("Refresh the model list under Text Chat to add the other Realtime models your key can use.")
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(AppLocalization.text("Live Voice"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
    }
}

/// Add Account: the account types, each with how it connects; choosing one opens its key, address or
/// sign-in.
struct AddAccount: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ModelProvider?
    @State private var signingIn = false
    @State private var addingCustom = false
    @State private var addedCustom = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelProvider.allCases) { provider in
                        Button {
                            if provider.signsIn { signingIn = true } else if provider == .custom { addingCustom = true } else { editing = provider }
                        } label: {
                            HStack(spacing: 12) {
                                ProviderTile(provider: provider)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: provider.name).foregroundStyle(Color(.label))
                                    Text(capabilities(provider)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                                }
                                Spacer()
                                // Custom endpoints can be added again and again.
                                if provider != .custom, ModelAccounts.isSetUp(provider) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } footer: {
                    Text("Text chat works with every account. Live voice works with ChatGPT, an OpenAI API key, or a custom endpoint with the Realtime API.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.text("Add Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $editing, onDismiss: { if editing == nil { dismiss() } }) { provider in KeyEntry(provider: provider) }
            .sheet(isPresented: $signingIn, onDismiss: { if ChatGPTAccount.signedIn { dismiss() } }) { ChatGPTSignIn() }
            .sheet(isPresented: $addingCustom, onDismiss: { if addedCustom { dismiss() } }) { CustomProviderEditor(id: nil) { addedCustom = true } }
        }
    }

    private func capabilities(_ provider: ModelProvider) -> String {
        let how = ModelAccounts.method(provider)
        if ModelAccounts.canTalkLive(provider) { return AppLocalization.text(LocalizedStringResource("\(how) · Text chat and live voice")) }
        if ModelAccounts.canChat(provider) { return AppLocalization.text(LocalizedStringResource("\(how) · Text chat")) }
        return AppLocalization.text(LocalizedStringResource("\(how) · Coming in an update"))
    }
}

/// Entering, replacing or removing one provider's key. The field is secure and the key is never shown
/// again after it is saved. Test Connection sends one small request with what is on the page (the typed
/// key, or the saved one when the field is empty); Save tests too and keeps the page open on a failure,
/// saved all the same.
struct KeyEntry: View {
    @Environment(\.dismiss) private var dismiss
    var provider: ModelProvider
    @State private var key = ""
    @State private var url = ModelKeys.customURL
    @State private var modelID = ModelKeys.customModel
    @State private var discovery = CustomModelDiscovery()
    @State private var failed = false
    @State private var testing = false
    @State private var connectionTest: Task<Void, Never>?
    @State private var result: ConnectionCheck.Result?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                if provider == .custom {
                    Section {
                        TextField("https://…/v1", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model, such as llama-4-maverick", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Address and model") }
                }
                Section {
                    SecureField(provider.keyPrompt, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("\(provider.name) key")
                } footer: {
                    if !provider.wired {
                        Text("Poki keeps the key now; chatting with \(provider.name) comes in an update. Until then, choose Anthropic or OpenAI.")
                    } else if provider == .custom,
                              ModelCatalog.normalizedAddress(url) != ModelCatalog.normalizedAddress(ModelKeys.customURL),
                              ModelKeys.hasKey(provider) {
                        Text("The saved key belongs to the previous address. Enter a key for this service if it needs one.")
                    } else if ModelKeys.hasKey(provider) {
                        Text("A key is saved. Enter a new one to replace it.")
                    } else {
                        Text(verbatim: provider.keyHelp)
                    }
                }
                if provider == .custom {
                    Section {
                        Button(action: fetchModels) {
                            HStack {
                                Text(discovery.loading ? "Reading the Model List…" : "Fetch Model List")
                                Spacer()
                                if discovery.loading { ProgressView() }
                            }
                        }
                        .disabled(discovery.loading || testing || !validCustomAddress)
                        .accessibilityIdentifier("keyEntry.fetchModels")
                    } footer: {
                        if let problem = discovery.problem {
                            Text(problem.message)
                        } else {
                            Text("Choose a model from the service, or enter its ID manually.")
                        }
                    }
                }
                if failed { Text("The keychain did not take the key. Try again.").foregroundStyle(Color(.systemRed)) }
                if provider.wired {
                    Section {
                        Button(action: test) {
                            HStack {
                                Text(testing ? "Testing…" : "Test Connection")
                                Spacer()
                                if testing { ProgressView() }
                            }
                        }
                        .disabled(testing || testKey == nil)
                        .accessibilityIdentifier("keyEntry.test")
                    } footer: {
                        if let result, !testing {
                            ConnectionCheckFeedback(result: result, saved: saved)
                                .accessibilityIdentifier("keyEntry.result")
                        }
                    }
                }
                if ModelKeys.hasKey(provider) {
                    Section { Button("Remove Key", role: .destructive) { ModelKeys.remove(provider); dismiss() } }
                }
            }
            .navigationTitle(Text(verbatim: provider.name))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: url) { _, _ in discovery.reset() }
            .onChange(of: key) { _, _ in discovery.reset() }
            .onDisappear {
                discovery.cancel()
                connectionTest?.cancel()
                connectionTest = nil
                testing = false
            }
            .sheet(isPresented: $discovery.presenting) {
                CustomModelPicker(models: discovery.models, selection: $modelID)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave || testing) }
            }
        }
    }

    private var validCustomAddress: Bool {
        (try? ModelCatalog.customRequest(address: url, key: nil)) != nil
    }

    private func fetchModels() {
        discovery.fetch(address: url, key: ModelKeys.customDraftKey(address: url, typedKey: key))
    }

    /// The key a test sends: the one typed, else the saved one. A custom endpoint may have none, but
    /// needs an address and a model.
    private var testKey: String? {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .custom {
            let ready = validCustomAddress && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ready ? (ModelKeys.customDraftKey(address: url, typedKey: key) ?? "") : nil
        }
        return typed.isEmpty ? ModelKeys.key(provider) : typed
    }

    private func test() {
        guard let testKey else { return }
        check(testKey, closeIfPassed: false)
    }

    private func check(_ key: String, closeIfPassed: Bool) {
        connectionTest?.cancel()
        testing = true
        result = nil
        let url = provider == .custom ? ModelCatalog.normalizedAddress(url) : url
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionTest = Task {
            defer { if !Task.isCancelled { connectionTest = nil } }
            guard !Task.isCancelled else { return }
            let outcome = await ConnectionCheck.run(provider, key: key, customURL: url, modelID: modelID)
            guard !Task.isCancelled else { return }
            result = outcome
            testing = false
            if closeIfPassed, outcome.passed {
                do { try await Task.sleep(for: .milliseconds(900)) }
                catch { return }
                guard !Task.isCancelled else { return }
                dismiss()
            }
        }
    }

    private var canSave: Bool {
        provider == .custom ? validCustomAddress && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let tested = testKey
        do {
            if provider == .custom {
                try ModelKeys.saveCustom(address: url, model: modelID, typedKey: key)
                discovery.reset()
            } else if !key.isEmpty { try ModelKeys.save(key, for: provider) }
            // A new key or address is read at once, not after the old one's wait.
            if provider == .custom {
                if let saved = CustomProviders.current() { ModelCatalog.clearFailures(.custom(saved.id)) }
            } else {
                ModelCatalog.clearFailures(provider)
            }
            // A new key picks its provider; the model page's picker switches between providers with keys.
            if provider.wired, !key.isEmpty, provider != .custom {
                // Ready at once: chat on this account's first fast model, live voice on where it can.
                ModelKeys.selectedProvider = provider
                if let first = ModelCatalog.available(provider).first { ModelKeys.selectedModel = first.id }
                if provider == .openai, VoiceDirect.account == nil { VoiceDirect.set(.openai, on: true) }
                Task { _ = try? await ModelCatalog.refresh(provider) }
            }
            key = ""
            saved = true
            // Tested once saved; a failure keeps the page open with the result, the key saved all the same.
            if provider.wired, let tested { check(tested, closeIfPassed: true) } else { dismiss() }
        } catch {
            failed = true
        }
    }
}


struct CustomModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let models: [String]
    @Binding var selection: String
    @State private var query = ""

    private var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if models.isEmpty {
                    Text("No chat models were returned. You can enter a model ID manually.")
                        .foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text("No matching models.").foregroundStyle(.secondary)
                } else {
                    ForEach(matches, id: \.self) { model in
                        Button {
                            selection = model
                            dismiss()
                        } label: {
                            HStack {
                                Text(verbatim: model).foregroundStyle(.primary)
                                Spacer()
                                if model == selection { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle(AppLocalization.text("Choose a Model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
