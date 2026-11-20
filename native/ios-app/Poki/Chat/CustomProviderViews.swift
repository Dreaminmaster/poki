import SwiftUI

/// A custom provider in the providers list: its name and what it is used for.
struct CustomAccountRow: View {
    var provider: CustomProvider
    var body: some View {
        HStack(spacing: 12) {
            ProviderTile(provider: .custom)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: provider.displayName)
                Text(verbatim: ProviderUseValue.summary(.custom(provider.id))).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// One custom provider, laid out as a hosted one: its type and connection, its addresses and the API
/// each speaks, reasoning, what it is used for (the tick lists), and Delete.
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
                    LabeledContent("Connection", value: ModelAccounts.method(.custom))
                    LabeledContent("Key", value: CustomProviders.key(id) == nil ? AppLocalization.text(LocalizedStringResource("None")) : AppLocalization.text(LocalizedStringResource("Saved")))
                    Button("Edit Address and Key") { editing = true }
                }

                Section {
                    ForEach(Array(provider.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: endpoint.normalized).lineLimit(2).truncationMode(.middle)
                            Text(verbatim: apiLine(endpoint, first: index == 0)).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Picker("Reasoning", selection: Binding(get: { provider.reasoning }, set: { value in
                        var changed = provider
                        changed.reasoning = value
                        CustomProviders.upsert(changed)
                    })) {
                        Text("Automatic").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text(provider.endpoints.count > 1
                         ? LocalizedStringKey("Poki uses the first address. When it can’t be reached, Poki tries the next ones that speak the same API, in order. Automatic reasoning is on for models Poki knows as reasoning models.")
                         : LocalizedStringKey("Automatic reasoning is on for models Poki knows as reasoning models, such as GPT-6.1 Sol."))
                }

                Section {
                    ProviderUseRows(provider: .custom(id))
                } header: {
                    Text("Use This Provider For")
                } footer: {
                    Text("Voice needs the Realtime API at the first address.")
                }

                Section {
                    Button("Delete Provider", role: .destructive) {
                        if let pick = QuickFixes.accountPick, pick.provider == .custom, CustomProviders.parse(pick.model)?.provider == id {
                            QuickFixes.pickAccount(.custom, model: nil)
                        }
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

    /// "Responses", "Automatic, uses Responses", with "Backup" for the addresses after the first.
    private func apiLine(_ endpoint: CustomEndpoint, first: Bool) -> String {
        let api = endpoint.api == .automatic
            ? (endpoint.found.map { AppLocalization.text(LocalizedStringResource("Automatic, uses \($0.name)")) } ?? CustomAPIStyle.automatic.name)
            : endpoint.api.name
        return first ? api : AppLocalization.text(LocalizedStringResource("Backup, \(api)"))
    }
}

/// Adding or editing one custom provider, in the same pane as a hosted provider's key: its address
/// and the API it speaks, backup addresses, its key, Test Connection and Save. Its models are ticked
/// afterwards under the provider, as a hosted provider's are; the test uses the service's own list.
/// Save tests too and keeps the pane open when the first address fails, saved all the same. A saved
/// key is only ever sent to the addresses it was saved for: a new address needs it typed again.
struct CustomProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    var id: UUID?
    var onSave: () -> Void = {}

    @State private var draft: CustomProvider
    @State private var key = ""
    @State private var results: [UUID: Outcome] = [:]
    @State private var testing = false
    @State private var saved = false
    @State private var failed = false
    /// The hosts the saved key was saved for.
    @State private var keyHosts: Set<String>

    struct Outcome: Equatable {
        var result: ConnectionCheck.Result
        var api: CustomAPIStyle
        var model: String?
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
                    addressFields($draft.endpoints[0])
                } header: {
                    Text("Address")
                } footer: {
                    Text("Automatic tries the Responses API first and uses chat completions where the address has none.")
                }

                Section {
                    ForEach(Array(draft.endpoints.dropFirst())) { endpoint in addressFields(binding(endpoint.id)) }
                        .onDelete { offsets in draft.endpoints.remove(atOffsets: IndexSet(offsets.map { $0 + 1 })) }
                    Button("Add Backup Address", systemImage: "plus") {
                        draft.endpoints.append(CustomEndpoint(url: "", api: draft.endpoints.first?.api ?? .automatic))
                    }
                } header: {
                    Text("Backup Addresses")
                } footer: {
                    Text("When the address can’t be reached, Poki tries these in order.")
                }

                Section {
                    SecureField(ModelProvider.custom.keyPrompt, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("\(draft.displayName) key")
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
                    if !testing, let first = filled.first, let outcome = results[first.id] {
                        VStack(alignment: .leading, spacing: 4) {
                            resultView(outcome)
                            ForEach(filled.dropFirst()) { backup in
                                if let other = results[backup.id] {
                                    Text(verbatim: backup.normalized).lineLimit(1).truncationMode(.middle)
                                    resultView(other)
                                }
                            }
                            if saved, !outcome.result.passed { Text("Saved. Change it and save again, or keep it as it is.") }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("customEditor.result")
                    }
                }

                if !keyHosts.isEmpty, CustomProviders.key(draft.id) != nil {
                    Section { Button("Remove Key", role: .destructive) { CustomProviders.removeKey(draft.id); keyHosts = [] } }
                }
            }
            .navigationTitle(Text(verbatim: id == nil ? ModelProvider.custom.name : draft.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave || testing) }
            }
        }
    }

    /// An address of the draft by its id; one deleted meanwhile reads as empty and takes no change.
    private func binding(_ id: UUID) -> Binding<CustomEndpoint> {
        Binding(get: { draft.endpoints.first { $0.id == id } ?? CustomEndpoint(id: id, url: "") },
                set: { new in if let i = draft.endpoints.firstIndex(where: { $0.id == id }) { draft.endpoints[i] = new } })
    }

    /// An address and its API, as one row group.
    @ViewBuilder private func addressFields(_ endpoint: Binding<CustomEndpoint>) -> some View {
        TextField("https://…/v1", text: endpoint.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        Picker("API", selection: endpoint.api) {
            ForEach(CustomAPIStyle.allCases) { Text(verbatim: $0.name).tag($0) }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder private func resultView(_ outcome: Outcome) -> some View {
        Label {
            Text(outcome.result.words)
        } icon: {
            Image(systemName: outcome.result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        .foregroundStyle(outcome.result.passed ? Color(.systemGreen) : Color(.systemOrange))
        if outcome.result.passed {
            Text(verbatim: AppLocalization.text(LocalizedStringResource("Answered in the \(outcome.api.name) API")))
        }
        if let detail = outcome.result.detail { Text(verbatim: detail) }
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

    private var canSave: Bool { !filled.isEmpty && filled.allSatisfy { Self.valid($0.url) } }

    // MARK: Testing and saving

    /// The model a test asks: the provider's own, else the first chat model the address lists.
    private static func testModel(_ provider: CustomProvider, address: String, key: String) async -> String? {
        let own = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return (try? await ModelCatalog.fetchCustom(address: address, key: key.isEmpty ? nil : key))?.first
    }

    /// Tests every address in turn. Once saved, what Automatic found at each is kept, a model the
    /// test found becomes the provider's own when it had none, and with `closeIfPassed` the pane
    /// closes when the first address works.
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

    /// A provider saved without a model takes the one its test answered with, so Chat has one ticked.
    private func adopt(_ model: String) {
        guard var current = CustomProviders.provider(draft.id), current.model.isEmpty else { return }
        current.model = model
        CustomProviders.upsert(current)
        if !ModelKeys.hasUsableKey {
            ModelKeys.selectedProvider = .custom
            ModelKeys.selectedModel = CustomProviders.choiceID(current.id, model)
        }
    }

    private func save() {
        var provider = draft
        provider.endpoints = filled.map { var e = $0; e.url = e.normalized; return e }
        provider.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // The saved key stays only while every address is one it was saved for.
            try ModelKeys.saveCustom(provider, typedKey: key, keepKey: newHosts.isEmpty)
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
