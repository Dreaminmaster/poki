import SwiftUI

/// One custom provider: its addresses and the API each speaks, what it is used for (the text chat,
/// live voice), and Delete.
struct CustomProviderDetail: View {
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    @State private var editing = false
    @State private var version = ModelKeys.saved

    var body: some View {
        Form {
            if let provider = CustomProviders.provider(id) {
                Section {
                    LabeledContent("Type", value: ModelProvider.custom.name)
                    LabeledContent("Key", value: CustomProviders.key(id) == nil ? AppLocalization.text(LocalizedStringResource("None")) : AppLocalization.text(LocalizedStringResource("Saved")))
                    Button("Edit Service") { editing = true }
                }

                Section {
                    ForEach(Array(provider.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: endpoint.normalized).lineLimit(2).truncationMode(.middle)
                            Text(verbatim: apiLine(endpoint, first: index == 0)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    if provider.endpoints.count > 1 {
                        Text("Poki uses the first address. When it can’t be reached, Poki tries the next ones that speak the same API, in order.")
                    }
                }

                Section {
                    NavigationLink { TextChatFeature(provider: .custom, custom: id) } label: {
                        LabeledContent {
                            Text(verbatim: chatValue(provider))
                        } label: { SettingsLabel("Text Chat", systemImage: "bubble.left.and.text.bubble.right") }
                    }
                    NavigationLink { LiveVoiceFeature(account: .custom(id)) } label: {
                        LabeledContent {
                            Text(verbatim: VoiceDirect.isOn(.custom(id)) ? ModelCatalog.voiceModelID(for: .custom(id)) : AppLocalization.text(LocalizedStringResource("Off")))
                        } label: { SettingsLabel("Live Voice", systemImage: "waveform") }
                    }
                } header: {
                    Text("Use This Account For")
                } footer: {
                    Text("Live voice needs the Realtime API at the first address.")
                }

                Section {
                    Button("Delete Service", role: .destructive) {
                        CustomProviders.remove(id)
                        if ModelKeys.selectedProvider == .custom, !ModelKeys.hasUsableKey,
                           let other = ModelProvider.allCases.first(where: { $0 != .custom && ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
                            ModelKeys.selectedProvider = other
                        }
                        dismiss()
                    }
                }
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(Text(verbatim: CustomProviders.provider(id)?.displayName ?? ModelProvider.custom.name))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .sheet(isPresented: $editing, onDismiss: { version = ModelKeys.saved }) { CustomProviderEditor(id: id) }
    }

    private func chatValue(_ provider: CustomProvider) -> String {
        if ModelKeys.selectedProvider == .custom, let chosen = CustomProviders.parse(ModelKeys.selectedModel), chosen.provider == provider.id {
            return chosen.model
        }
        return AppLocalization.text(LocalizedStringResource("Off"))
    }

    /// "Responses", "Automatic, found Responses", with "Backup" for the addresses after the first.
    private func apiLine(_ endpoint: CustomEndpoint, first: Bool) -> String {
        let api = endpoint.api == .automatic
            ? (endpoint.found.map { AppLocalization.text(LocalizedStringResource("Automatic, uses \($0.name)")) } ?? CustomAPIStyle.automatic.name)
            : endpoint.api.name
        return first ? api : AppLocalization.text(LocalizedStringResource("Backup, \(api)"))
    }
}

/// Adding or editing one custom provider: its name, its addresses each with its API, its model and
/// thinking, and its key. Test Connection sends one small request to every address with what is on the
/// page; Save tests too and keeps the page open when the first address fails, saved all the same. A
/// saved key is only ever sent to the addresses it was saved for: a new address needs it typed again.
struct CustomProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    var id: UUID?
    var onSave: () -> Void = {}

    @State private var draft: CustomProvider
    @State private var key = ""
    @State private var discovery = CustomModelDiscovery()
    @State private var results: [UUID: Outcome] = [:]
    @State private var testing = false
    @State private var saved = false
    @State private var failed = false
    /// The hosts the saved key was saved for.
    @State private var keyHosts: Set<String>

    struct Outcome: Equatable {
        var result: ConnectionCheck.Result
        var api: CustomAPIStyle
    }

    init(id: UUID?, onSave: @escaping () -> Void = {}) {
        self.id = id
        self.onSave = onSave
        var start = id.flatMap { CustomProviders.provider($0) } ?? CustomProvider()
        if start.endpoints.isEmpty { start.endpoints = [CustomEndpoint(url: "")] }
        _draft = State(initialValue: start)
        _keyHosts = State(initialValue: id.flatMap { CustomProviders.key($0) } == nil ? [] : Set(start.endpoints.compactMap { Self.host($0.url) }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Company Gateway", text: $draft.name).autocorrectionDisabled()
                } header: { Text("Name") }

                Section {
                    ForEach($draft.endpoints) { $endpoint in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("https://…/v1", text: $endpoint.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("API", selection: $endpoint.api) {
                                ForEach(CustomAPIStyle.allCases) { Text(verbatim: $0.name).tag($0) }
                            }
                            if let outcome = results[endpoint.id], !testing {
                                ConnectionCheckFeedback(result: outcome.result, api: outcome.api)
                                    .accessibilityIdentifier("customEditor.result")
                            }
                        }
                    }
                    .onDelete { draft.endpoints.remove(atOffsets: $0); if draft.endpoints.isEmpty { draft.endpoints = [CustomEndpoint(url: "")] } }
                    Button("Add Address", systemImage: "plus") { draft.endpoints.append(CustomEndpoint(url: "", api: draft.endpoints.last?.api ?? .automatic)) }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Poki uses the first address and tries the others in order when it can’t be reached. Automatic tries the Responses API first and uses chat completions where an address has none.")
                }

                Section {
                    TextField("Model, such as llama-4-maverick", text: $draft.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(action: fetchModels) {
                        HStack {
                            Text(discovery.loading ? "Reading the Model List…" : "Fetch Model List")
                            Spacer()
                            if discovery.loading { ProgressView() }
                        }
                    }
                    .disabled(discovery.loading || testing || firstAddress == nil)
                    .accessibilityIdentifier("customEditor.fetchModels")
                    Picker("Reasoning", selection: $draft.reasoning) {
                        Text("Automatic").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if let problem = discovery.problem {
                        Text(problem.message)
                    } else {
                        Text("Choose a model from the service, or enter its ID manually. Automatic reasoning is on for models Poki knows as reasoning models, such as GPT-6.1 Sol.")
                    }
                }

                Section {
                    SecureField(ModelProvider.custom.keyPrompt, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Key")
                } footer: {
                    if !keyHosts.isEmpty, key.isEmpty, !newHosts.isEmpty {
                        Text("The saved key is only sent to the addresses it was saved for. Enter it again to use it with the new address.")
                    } else if !keyHosts.isEmpty {
                        Text("A key is saved. Enter a new one to replace it.")
                    } else {
                        Text(verbatim: ModelProvider.custom.keyHelp)
                    }
                }

                if failed { Text("The keychain did not take the key. Try again.").foregroundStyle(Color(.systemRed)) }

                Section {
                    Button(action: { test(closeIfPassed: false) }) {
                        HStack {
                            Text(testing ? "Testing…" : "Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !canSave)
                    .accessibilityIdentifier("customEditor.test")
                } footer: {
                    if saved, !testing, results[draft.endpoints.first?.id ?? UUID()]?.result.passed == false {
                        Text("Saved. Change it and save again, or keep it as it is.")
                    }
                }

                if !keyHosts.isEmpty, CustomProviders.key(draft.id) != nil {
                    Section { Button("Remove Key", role: .destructive) { CustomProviders.removeKey(draft.id); keyHosts = [] } }
                }
            }
            .navigationTitle(Text(verbatim: id == nil ? AppLocalization.text(LocalizedStringResource("Add Custom Endpoint")) : draft.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draft.endpoints.first?.url) { _, _ in discovery.reset() }
            .onChange(of: key) { _, _ in discovery.reset() }
            .onDisappear { discovery.cancel() }
            .sheet(isPresented: $discovery.presenting) {
                CustomModelPicker(models: discovery.models, selection: $draft.model)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave || testing) }
            }
        }
    }

    // MARK: Addresses and the key

    private static func host(_ address: String) -> String? {
        URLComponents(string: ModelCatalog.normalizedAddress(address))?.host?.lowercased()
    }

    private static func valid(_ address: String) -> Bool {
        (try? ModelCatalog.customRequest(address: address, key: nil)) != nil
    }

    /// The addresses filled in, in order.
    private var filled: [CustomEndpoint] { draft.endpoints.filter { !$0.normalized.isEmpty } }

    private var firstAddress: String? { filled.first.map(\.normalized).flatMap { Self.valid($0) ? $0 : nil } }

    /// Hosts on the page that the saved key was not saved for.
    private var newHosts: Set<String> { Set(filled.compactMap { Self.host($0.url) }).subtracting(keyHosts) }

    /// The key a request to `address` carries: the one typed, else the saved one for an address it was
    /// saved for, else none.
    private func key(for address: String) -> String {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard let host = Self.host(address), keyHosts.contains(host) else { return "" }
        return CustomProviders.key(draft.id) ?? ""
    }

    private var canSave: Bool {
        !filled.isEmpty && filled.allSatisfy { Self.valid($0.url) } && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fetchModels() {
        guard let firstAddress else { return }
        let draftKey = key(for: firstAddress)
        discovery.fetch(address: firstAddress, key: draftKey.isEmpty ? nil : draftKey)
    }

    // MARK: Testing and saving

    /// Tests every address in turn. Automatic results for saved addresses are kept, and with
    /// `closeIfPassed` the page closes when the first address works.
    private func test(closeIfPassed: Bool) {
        testing = true
        results = [:]
        let endpoints = filled
        let draft = self.draft
        let keys = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, key(for: $0.url)) })
        Task {
            for endpoint in endpoints {
                let run = await CustomProviders.testConnection(to: endpoint, key: keys[endpoint.id] ?? "", draft: draft)
                results[endpoint.id] = Outcome(result: run.result, api: run.api)
            }
            testing = false
            if closeIfPassed, let first = endpoints.first, results[first.id]?.result.passed == true {
                try? await Task.sleep(for: .milliseconds(900))
                dismiss()
            }
        }
    }

    private func save() {
        var provider = draft
        provider.endpoints = filled.map { var e = $0; e.url = e.normalized; return e }
        provider.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // The saved key stays only while every address is one it was saved for.
            try ModelKeys.saveCustom(provider, typedKey: key, keepKey: newHosts.isEmpty)
            discovery.reset()
            draft = CustomProviders.provider(provider.id) ?? provider
            keyHosts = CustomProviders.key(provider.id) == nil ? [] : Set(provider.endpoints.compactMap { Self.host($0.url) })
            saved = true
            onSave()
            Task { _ = try? await ModelCatalog.refresh(custom: provider.id) }
            test(closeIfPassed: true)
            key = ""
        } catch {
            failed = true
        }
    }
}
