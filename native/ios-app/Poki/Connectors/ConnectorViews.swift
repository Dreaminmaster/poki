import PiSwiftMCP
import SwiftUI

/// Settings › Connectors: the services Poki's chat can use beside the phone. Each connector lists its
/// accounts; a connector can hold several (work and personal), and any MCP server can be added by its
/// address.
struct ConnectorsView: View {
    @State private var store = MCPConnectors.shared
    @State private var addingCustom = false

    var body: some View {
        List {
            if !store.connected.isEmpty {
                Section {
                    ForEach(store.connected) { connector in
                        NavigationLink(value: ConnectorRoute.connector(connector.id)) { row(connector) }
                    }
                } header: { SettingsHeader("Connected") }
            }
            Section {
                ForEach(store.all.filter { c in !store.connected.contains(c) }) { connector in
                    NavigationLink(value: ConnectorRoute.connector(connector.id)) { row(connector) }
                }
                Button { addingCustom = true } label: {
                    SettingsRow(title: "Add Custom Connector", symbol: "plus", accessory: .leaves)
                }
                .accessibilityIdentifier("connectors.addCustom")
            } header: {
                SettingsHeader("Available")
            } footer: {
                Text("Connectors let Poki use a service directly, without opening its app. Mention one with @ in a message.")
            }
        }
        .navigationTitle(AppLocalization.text("Connectors"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ConnectorRoute.self) { route in
            Group {
                switch route {
                case .connector(let id): ConnectorDetailView(id: id)
                case .account(let id): ConnectorAccountView(id: id)
                }
            }
            .settingsPage()
        }
        .sheet(isPresented: $addingCustom) { CustomConnectorSheet() }
    }

    private func row(_ connector: MCPConnector) -> some View {
        let count = store.accounts(of: connector).count
        let value: String? = count == 0 ? nil : AppLocalization.text(LocalizedStringResource("^[\(count) Account](inflect: true)"))
        return SettingsRow(title: LocalizedStringKey(connector.name), symbol: connector.symbol, value: value)
    }
}

enum ConnectorRoute: Hashable {
    case connector(String)
    case account(UUID)
}

/// One connector: its accounts, the way to add another, and for one the owner added, its address.
struct ConnectorDetailView: View {
    let id: String
    @State private var store = MCPConnectors.shared
    @State private var adding = false
    @State private var label = ""
    @State private var token = ""
    @State private var working = false
    @State private var problem: String?
    @State private var address = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let connector = store.connector(id) {
            List {
                let accounts = store.accounts(of: connector)
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            NavigationLink(value: ConnectorRoute.account(account.id)) {
                                SettingsRow(title: LocalizedStringKey(store.title(account)), symbol: connector.symbol,
                                            value: status(account), warns: store.problems[account.id] != nil)
                            }
                        }
                    } header: { SettingsHeader("Accounts") }
                }
                Section {
                    if adding || accounts.isEmpty {
                        TextField(AppLocalization.text("Account Name"), text: $label, prompt: Text("Work or Personal"))
                            .textInputAutocapitalization(.words)
                        if connector.sign == .token {
                            SecureField(AppLocalization.text("Token"), text: $token)
                                .textContentType(.password)
                            if let help = connector.tokenHelp.flatMap(URL.init(string:)) {
                                Link(destination: help) { Label("Make a Token", systemImage: "key") }
                            }
                        }
                        Button {
                            Task { await add(connector) }
                        } label: {
                            HStack {
                                if connector.sign == .oauth {
                                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                                } else {
                                    Label("Add Account", systemImage: "plus")
                                }
                                Spacer()
                                if working { ProgressView() }
                            }
                        }
                        .disabled(working || (connector.sign == .token && token.trimmingCharacters(in: .whitespaces).isEmpty))
                        .accessibilityIdentifier("connector.signIn")
                    } else {
                        Button { withAnimation(.snappy) { adding = true } } label: {
                            Label("Add Another Account", systemImage: "plus")
                        }
                    }
                } footer: {
                    if let problem { Text(problem).foregroundStyle(Tint.red) }
                    else if accounts.isEmpty { Text(verbatim: connector.url) }
                }
                if connector.custom {
                    Section {
                        TextField(AppLocalization.text("Address"), text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit {
                                var changed = connector
                                changed.url = address.trimmingCharacters(in: .whitespaces)
                                store.update(changed)
                            }
                        Button(role: .destructive) {
                            store.remove(connector)
                            dismiss()
                        } label: { Label("Remove Connector", systemImage: "trash") }
                    } header: { SettingsHeader("Server") }
                    .onAppear { address = connector.url }
                }
            }
            .navigationTitle(connector.name)
            .navigationBarTitleDisplayMode(.inline)
            .animation(.snappy, value: adding)
        }
    }

    private func status(_ account: MCPConnectorAccount) -> String {
        if store.problems[account.id] != nil { return AppLocalization.text(LocalizedStringResource("Needs Attention")) }
        guard let tools = store.tools[account.id] else { return "" }
        return AppLocalization.text(LocalizedStringResource("^[\(tools.count) Tool](inflect: true)"))
    }

    private func add(_ connector: MCPConnector) async {
        working = true
        problem = nil
        defer { working = false }
        do {
            _ = try await MCPSignIn.add(connector, label: label.trimmingCharacters(in: .whitespaces), token: token)
            label = ""
            token = ""
            adding = false
        } catch MCPConnectorError.cancelled {
            // The owner closed the sign-in sheet: nothing to say.
        } catch {
            problem = MCPConnectorError.words(error)
        }
    }
}

/// One account: its name, whether Poki uses it in every chat, when it asks, and its tools.
struct ConnectorAccountView: View {
    let id: UUID
    @State private var store = MCPConnectors.shared
    @State private var working = false
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let account = store.accounts.first(where: { $0.id == id }), let connector = store.connector(account.connector) {
            List {
                Section {
                    TextField(AppLocalization.text("Account Name"), text: binding(account, \.label), prompt: Text("Work or Personal"))
                    Toggle(isOn: binding(account, \.automatic)) {
                        Label("Use in Every Chat", systemImage: "sparkles")
                    }
                    Picker(selection: binding(account, \.asks)) {
                        ForEach(MCPConnectorAccount.Asks.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Ask Before", systemImage: "checkmark.shield")
                    }
                    .pickerStyle(.menu)
                } footer: {
                    account.automatic ? Text("Poki can use this account in any chat.") : Text("Poki uses this account only when a message mentions it with @.")
                }

                Section {
                    if let tools = store.tools[account.id] {
                        if tools.isEmpty { Text("This server offers no tools.").foregroundStyle(.secondary) }
                        ForEach(tools, id: \.name) { tool in
                            Toggle(isOn: Binding(get: { !account.disabledTools.contains(tool.name) }, set: { on in
                                var changed = account
                                if on { changed.disabledTools.remove(tool.name) } else { changed.disabledTools.insert(tool.name) }
                                store.update(changed)
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: tool.annotations?.title ?? tool.title ?? tool.name)
                                    if let about = tool.description, !about.isEmpty {
                                        Text(verbatim: about).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    } else if let problem = store.problems[account.id] {
                        Text(problem).foregroundStyle(Tint.red)
                    } else {
                        HStack { Text("Connecting"); Spacer(); ProgressView() }
                    }
                } header: { SettingsHeader("Tools") }

                Section {
                    if connector.sign == .token {
                        SecureField(AppLocalization.text("New Token"), text: $token)
                    }
                    if connector.sign != .none {
                        Button {
                            Task { await signIn(account, connector) }
                        } label: {
                            HStack { Label("Sign In Again", systemImage: "arrow.clockwise"); Spacer(); if working { ProgressView() } }
                        }
                        .disabled(working || (connector.sign == .token && token.isEmpty))
                    }
                    Button(role: .destructive) {
                        store.remove(account)
                        dismiss()
                    } label: { Label("Remove Account", systemImage: "trash") }
                }
            }
            .navigationTitle(store.title(account))
            .navigationBarTitleDisplayMode(.inline)
            .task { if store.tools[account.id] == nil { await MCPSessions.shared.refresh(account, connector: connector) } }
            .refreshable { await MCPSessions.shared.refresh(account, connector: connector) }
        }
    }

    private func binding<Value>(_ account: MCPConnectorAccount, _ path: WritableKeyPath<MCPConnectorAccount, Value>) -> Binding<Value> {
        Binding(get: { (store.accounts.first { $0.id == account.id } ?? account)[keyPath: path] },
                set: { value in
                    var changed = store.accounts.first { $0.id == account.id } ?? account
                    changed[keyPath: path] = value
                    store.update(changed)
                })
    }

    private func signIn(_ account: MCPConnectorAccount, _ connector: MCPConnector) async {
        working = true
        defer { working = false }
        do {
            try await MCPSignIn.signIn(account, connector: connector, token: token)
            token = ""
            await MCPSessions.shared.refresh(account, connector: connector)
        } catch MCPConnectorError.cancelled {
        } catch {
            store.failed(account.id, MCPConnectorError.words(error))
        }
    }
}

extension MCPConnectorAccount.Asks {
    var title: String {
        switch self {
        case .changes: AppLocalization.text(LocalizedStringResource("Changes"))
        case .always: AppLocalization.text(LocalizedStringResource("Every Step"))
        case .never: AppLocalization.text(LocalizedStringResource("Never Ask"))
        }
    }
}

/// A connector the owner adds by its address: any MCP server on the web.
struct CustomConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = "https://"
    @State private var sign: MCPConnector.Sign = .oauth

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: address.trimmingCharacters(in: .whitespaces)).map { $0.scheme == "https" && $0.host != nil } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppLocalization.text("Name"), text: $name)
                    TextField(AppLocalization.text("Address"), text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("The server's streamable HTTP address, often ending in /mcp.")
                }
                Section {
                    Picker(selection: $sign) {
                        Text("Sign In").tag(MCPConnector.Sign.oauth)
                        Text("Token").tag(MCPConnector.Sign.token)
                        Text("None").tag(MCPConnector.Sign.none)
                    } label: {
                        Label("Sign In With", systemImage: "person.badge.key")
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle(AppLocalization.text("Custom Connector"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        _ = MCPConnectors.shared.addCustom(name: name.trimmingCharacters(in: .whitespaces),
                                                          url: address.trimmingCharacters(in: .whitespaces), sign: sign)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
