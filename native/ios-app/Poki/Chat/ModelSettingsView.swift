// The model page combines two files from lhuanyu/OllamaMessage (commit c857a02), Copyright (c) 2023
// Huanyu Luo, MIT License; see THIRD_PARTY_NOTICES.md:
// - OllamaMessage/Class/View/MessageList/DialogueSettingsView.swift: the "Model" row with its label and a hidden-label
//   Picker on the right;
// - OllamaMessage/Class/View/DialogueList/OllamaModelSelectionView.swift: one row per provider with its 30 pt icon, the
//   whole row tappable, and the footer under the list.
// Changed: the ESP-171 board "M Model" (the grouped rows, the provider tiles, "Add Key"), keys entered
// into the keychain instead of a server's model list, and the agents on a computer below.
import SwiftUI

/// Models: what each use runs on (Chat, Voice, Decisions, Senses), each picked from the models ticked
/// under the providers, in sections by provider; and the providers, as the Mail app lists mail
/// accounts. Local, the models on this iPhone, is always there. Each custom provider is one of its own.
/// The sections are `ModelSettingsSections`, which the start flow's Connect a Model page shows too.
struct ModelSettingsView: View {
    /// Opened from Talk with Poki without a key: the OpenAI key's form at once, or its voice models
    /// when the key is there but live voice is off.
    var opensVoiceKey = false
    @State private var enteringVoiceKey = false
    @State private var showingLiveVoice = false
    @State private var openedForVoice = false

    var body: some View {
        List {
            ModelSettingsSections()
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(AppLocalization.text("Models"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $enteringVoiceKey) { KeyEntry(provider: .openai).outsideStartFlow() }
        .navigationDestination(isPresented: $showingLiveVoice) { ModelTickList(use: .voice, provider: .account(.openai)) }
        .task {
            guard opensVoiceKey, !openedForVoice else { return }
            openedForVoice = true
            if !ModelKeys.hasKey(.openai) { enteringVoiceKey = true } else if VoiceDirect.account == nil { showingLiveVoice = true }
        }
    }
}

/// The Models page's sections, for a List or a Form: In Use, the local recommendation, and the
/// providers with Add Provider. One copy, on Settings' Models page and the start flow's page.
struct ModelSettingsSections: View {
    @State private var adding = false
    @State private var version = ModelKeys.saved

    var body: some View {
        Section {
            ForEach(ModelUse.allCases) { use in
                ModelUsePicker(use: use, version: version)
            }
        } header: {
            Group {
                Text("In Use").textCase(nil)
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("Each list offers the models ticked under the providers below. Senses reads the screen and checks privacy on this iPhone. Its insights use the model picked on the Senses page. Dictation in the message field needs no model.")
            }
            .settingsFooter()
        }

        if LocalModels.recommends {
            Section { LocalRecommendation() }
        }

        Section {
            NavigationLink { LocalProviderDetail() } label: { LocalProviderRow() }
                .accessibilityIdentifier("models.provider.local")
            ForEach(ModelProvider.allCases.filter { $0 != .custom && ModelAccounts.isSetUp($0) }) { provider in
                let usage = ProviderUseValue.summary(.account(provider))
                NavigationLink { AccountDetail(provider: provider) } label: {
                    AccountRow(provider: provider, name: provider.name, usage: usage)
                }
            }
            ForEach(CustomProviders.all) { custom in
                let usage = ProviderUseValue.summary(.custom(custom.id))
                NavigationLink { CustomProviderDetail(id: custom.id) } label: {
                    AccountRow(provider: .custom, name: custom.displayName, usage: usage)
                }
            }
            // The sheet and the redraw hang on this one row: on the sections they would repeat per row.
            Button("Add Provider", systemImage: "plus") { adding = true }
                .accessibilityIdentifier("models.provider.add")
                .sheet(isPresented: $adding) { AddAccount().outsideStartFlow() }
                .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        } header: {
            Group {
                Text("Providers").textCase(nil)
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("Keys and sign-ins stay in this iPhone’s Keychain. Poki sends each one only to its own provider.")
            }
            .settingsFooter()
        }
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
}

private struct AccountRow: View {
    let provider: ModelProvider
    let name: String
    let usage: String
    var body: some View {
        HStack(spacing: 12) {
            ProviderTile(provider: provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: provider.name)
                Text(verbatim: ProviderUseValue.summary(.account(provider))).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
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
        .font(.allo(.footnote))
        .accessibilityElement(children: .combine)
    }
}

/// The rows of a provider's "Use This Provider For": one per use it can serve, each opening the tick
/// list of the models that use's picker offers.
struct ProviderUseRows: View {
    var provider: ProviderRef

    var body: some View {
        ForEach(provider.uses) { use in
            NavigationLink { ModelTickList(use: use, provider: provider) } label: {
                LabeledContent {
                    Text(verbatim: ProviderUseValue.text(use, for: provider))
                } label: { SettingsLabel(use.title, systemImage: use.symbol) }
            }
            .accessibilityIdentifier("provider.use.\(use.rawValue)")
        }
    }
}

/// One hosted provider: its type and connection, what it is used for (the tick lists), and Delete.
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
                Button(provider.signsIn ? "Sign In Again" : "Replace Key") {
                    if provider.signsIn { signingIn = true } else { editing = true }
                }
            }

            Section {
                ProviderUseRows(provider: .account(provider))
            } header: {
                Group {
                    Text("Use This Provider For")
                }
                .settingsHeader()
            } footer: {
                Group {
                    if !ModelAccounts.canChat(provider) {
                        Text("Poki keeps this key; chatting with \(provider.name) comes in an update.")
                    } else if provider != .openai {
                        Text("Live voice runs on a Realtime API, which an OpenAI API key or a custom endpoint can open.")
                    }
                }
                .settingsFooter()
            }

            Section {
                Button(provider.signsIn ? "Sign Out" : "Delete Provider", role: .destructive) {
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
        .sheet(isPresented: $editing, onDismiss: { version = ModelKeys.saved }) { KeyEntry(provider: provider).outsideStartFlow() }
        .sheet(isPresented: $signingIn, onDismiss: { version = ModelKeys.saved }) { ChatGPTSignIn().outsideStartFlow() }
        .alert("Could not sign out of ChatGPT. Try again.", isPresented: $signOutFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func accountRemoved() {
        if QuickFixes.accountModel(provider) != nil { QuickFixes.pickAccount(provider, model: nil) }
        if ModelKeys.selectedProvider == provider,
           let other = ModelProvider.allCases.first(where: { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
            ModelKeys.selectedProvider = other
        }
        dismiss()
    }
}

/// Add Provider: the provider types, each with what it can be used for; choosing one opens its key,
/// address or sign-in, the same pane for every one.
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
                                    Text(capabilities(provider)).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                                }
                                Spacer()
                                // Custom endpoints can be added again and again.
                                if provider != .custom, ModelAccounts.isSetUp(provider) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } footer: {
                    Group {
                        Text("Chat and decisions work with every provider. Voice needs ChatGPT, an OpenAI API key or a custom endpoint with the Realtime API. Add as many custom endpoints as you like. Local is always there.")
                    }
                    .settingsFooter()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.text("Add Provider"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $editing, onDismiss: { if editing == nil { dismiss() } }) { provider in KeyEntry(provider: provider).outsideStartFlow() }
            .sheet(isPresented: $signingIn, onDismiss: { if ChatGPTAccount.signedIn { dismiss() } }) { ChatGPTSignIn().outsideStartFlow() }
            .sheet(isPresented: $addingCustom, onDismiss: { if addedCustom { dismiss() } }) { CustomProviderEditor(id: nil) { addedCustom = true }.outsideStartFlow() }
        }
    }

    /// What a provider can be used for: chat and decisions on every wired one, voice where it has a
    /// Realtime API.
    private func capabilities(_ provider: ModelProvider) -> String {
        if ModelAccounts.canTalkLive(provider) { return AppLocalization.text(LocalizedStringResource("Chat, voice and decisions")) }
        if ModelAccounts.canChat(provider) { return AppLocalization.text(LocalizedStringResource("Chat and decisions")) }
        return AppLocalization.text(LocalizedStringResource("Coming in an update"))
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
                    } header: {
                        Group {
     Text("Address and model") 
                        }
                        .settingsHeader()
                    }
                }
                Section {
                    SecureField(provider.keyPrompt, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Group {
                        Text("\(provider.name) key")
                    }
                    .settingsHeader()
                } footer: {
                    Group {
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
                    .settingsFooter()
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
                        Group {
                            if let problem = discovery.problem {
                                Text(problem.message)
                            } else {
                                Text("Choose a model from the service, or enter its ID manually.")
                            }
                        }
                        .settingsFooter()
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
                        Group {
                            if let result, !testing {
                                ConnectionCheckFeedback(result: result, saved: saved)
                                    .accessibilityIdentifier("keyEntry.result")
                            }
                        }
                        .settingsFooter()
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
