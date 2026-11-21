import PiSwiftMCP
import SwiftUI

/// Settings › Connectors: one list for every connector, built from the registry (`MCPConnector.presets`
/// and the owner's own), so a new service is a new descriptor, not a new page. Connected ones come
/// first with their account count; the rest are under Add Connector, with Add Custom Connector.
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
                } header: {
                    Group {
                        SettingsHeader("Connected")
                    }
                    .settingsHeader()
                }
            }
            Section {
                ForEach(store.all.filter { c in !store.connected.contains(c) }) { connector in
                    NavigationLink(value: ConnectorRoute.connector(connector.id)) { row(connector) }
                }
                Button { addingCustom = true } label: {
                    SettingsRow(title: "Add Custom Connector", symbol: "plus")
                }
                .accessibilityIdentifier("connectors.addCustom")
            } header: {
                Group {
                    SettingsHeader("Add Connector")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Connectors let Poki use a service directly, without opening its app. Mention one with @ in a message.")
                }
                .settingsFooter()
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
        .sheet(isPresented: $addingCustom) { AddCustomConnectorView() }
    }

    private func row(_ connector: MCPConnector) -> some View {
        let count = store.accounts(of: connector).count
        let value: String? = count == 0 ? nil : AppLocalization.text(LocalizedStringResource("^[\(count) Account](inflect: true)"))
        return ConnectorRow(connector: connector, title: connector.name, value: value)
    }
}

enum ConnectorRoute: Hashable {
    case connector(String)
    case account(UUID)
}

/// A connector's picture: its brand icon from the asset catalogue, else the icon its server publishes
/// (custom connectors, cached), else its symbol on Poki's soft ground.
struct ConnectorIcon: View {
    let connector: MCPConnector
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29
    @State private var fetched: UIImage?

    var body: some View {
        let size = min(side, 40)
        Group {
            if let name = connector.iconAsset, let image = UIImage(named: name) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let image = fetched ?? ConnectorIconCache.cached(connector.id) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                SettingsIcon(symbol: connector.symbol, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
        .task(id: connector.iconURL) {
            guard connector.iconAsset == nil, fetched == nil, let address = connector.iconURL else { return }
            fetched = await ConnectorIconCache.load(connector.id, from: address)
        }
    }
}

/// The icons custom connectors' servers publish, kept in Caches by connector id.
enum ConnectorIconCache {
    private static func file(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("connector-icon-\(id).png")
    }

    static func cached(_ id: String) -> UIImage? { UIImage(contentsOfFile: file(id).path) }

    static func load(_ id: String, from address: String) async -> UIImage? {
        if let image = cached(id) { return image }
        guard let url = URL(string: address), url.scheme == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
              let image = UIImage(data: data) else { return nil }
        try? data.write(to: file(id))
        return image
    }

    /// The icon a server's own site publishes: its touch icon, at the server's origin.
    static func address(for server: URL) -> String? {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/apple-touch-icon.png"
        parts.query = nil
        return parts.url?.absoluteString
    }
}

/// A connector or account row: the connector's icon, the name on one line, and a value.
struct ConnectorRow: View {
    let connector: MCPConnector
    let title: String
    var value: String? = nil
    var warns = false
    @ScaledMetric(relativeTo: .body) private var spacing = SettingsRowMetrics.iconSpacing

    var body: some View {
        HStack(spacing: min(18, spacing)) {
            ConnectorIcon(connector: connector)
            Text(verbatim: title).font(.allo(.body)).foregroundStyle(Color(.label)).lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(verbatim: value).font(.allo(.subheadline))
                    .foregroundStyle(warns ? Color(.systemOrange) : Color(.secondaryLabel)).lineLimit(1)
            }
        }
    }
}

/// One connector, the same page for all of them: its accounts (named from the sign-in, renamed or
/// removed from their menus), Add Account, and what Poki can do with it. A custom connector also
/// shows its address and can be removed.
struct ConnectorDetailView: View {
    let id: String
    @State private var store = MCPConnectors.shared
    @State private var token = ""
    @State private var working = false
    @State private var problem: String?
    @State private var renaming: MCPConnectorAccount?
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let connector = store.connector(id) {
            List {
                let accounts = store.accounts(of: connector)
                Section {
                    ForEach(accounts) { account in
                        NavigationLink(value: ConnectorRoute.account(account.id)) {
                            ConnectorRow(connector: connector, title: store.title(account), value: status(account),
                                         warns: store.problems[account.id] != nil)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                newName = account.label
                                renaming = account
                            }
                            Button("Remove Account", systemImage: "trash", role: .destructive) { store.remove(account) }
                        }
                    }
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
                            Label(accounts.isEmpty ? "Add Account" : "Add Another Account", systemImage: "plus")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || (connector.sign == .token && token.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("connector.signIn")
                } header: {
                    Group {
                        SettingsHeader("Accounts")
                    }
                    .settingsHeader()
                } footer: {
                    Group {
                        if let problem { Text(problem).foregroundStyle(Tint.red) }
                        else if let about = connector.about { Text(LocalizedStringKey(about)) }
                    }
                    .settingsFooter()
                }
                if connector.custom {
                    Section {
                        LabeledContent(AppLocalization.text("Address")) {
                            Text(verbatim: connector.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Button(role: .destructive) {
                            store.remove(connector)
                            dismiss()
                        } label: { Label("Remove Connector", systemImage: "trash") }
                    } header: {
                        Group {
                            SettingsHeader("Server")
                        }
                        .settingsHeader()
                    }
                }
            }
            .navigationTitle(connector.name)
            .navigationBarTitleDisplayMode(.inline)
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(AppLocalization.text("Name"), text: $newName)
                Button("Save") {
                    if var account = renaming {
                        account.label = newName.trimmingCharacters(in: .whitespaces)
                        store.update(account)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func status(_ account: MCPConnectorAccount) -> String? {
        if store.problems[account.id] != nil { return AppLocalization.text(LocalizedStringResource("Needs Attention")) }
        guard let tools = store.tools[account.id] else { return nil }
        return AppLocalization.text(LocalizedStringResource("^[\(tools.count) Tool](inflect: true)"))
    }

    private func add(_ connector: MCPConnector) async {
        working = true
        problem = nil
        defer { working = false }
        do {
            _ = try await MCPSignIn.add(connector, token: token)
            token = ""
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
                    Group {
                        account.automatic ? Text("Poki can use this account in any chat.") : Text("Poki uses this account only when a message mentions it with @.")
                    }
                    .settingsFooter()
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
                                        Text(verbatim: about).font(.allo(.footnote)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    } else if let problem = store.problems[account.id] {
                        Text(problem).foregroundStyle(Tint.red)
                    } else {
                        HStack { Text("Connecting"); Spacer(); ProgressView() }
                    }
                } header: {
                    Group {
     SettingsHeader("Tools") 
                    }
                    .settingsHeader()
                }

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


/// Add Custom Connector: a name and an address, a live check of the server, and Connect. Everything
/// the check finds (sign-in, client registration, transport) is preselected and marked as detected;
/// the owner's own client, request headers and the transport are under Advanced, closed.
struct AddCustomConnectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = "https://"
    @State private var checking = false
    @State private var done: Set<ConnectorProbe.Step> = []
    @State private var failure: String?
    @State private var probe: ConnectorProbe?

    private var url: URL? {
        URL(string: address.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppLocalization.text("Name"), text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("customConnector.name")
                    TextField(AppLocalization.text("Server Address"), text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("customConnector.address")
                }
                if checking || !done.isEmpty || failure != nil {
                    Section {
                        stepRow(.server, "Connecting to the Server")
                        stepRow(.signInSettings, "Looking Up Sign-In Settings")
                        stepRow(.provider, "Checking the Sign-In Provider")
                    } footer: {
                        Group {
                            if let failure { Text(verbatim: failure).foregroundStyle(Tint.red) }
                            else if probe != nil { Text("Server found.") }
                        }
                        .settingsFooter()
                    }
                }
            }
            .navigationTitle(AppLocalization.text("Add Custom Connector"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                StartButtons(primary: "Continue", action: { Task { await check() } }, primaryID: "customConnector.continue")
                    .disabled(url == nil || checking)
            }
            .navigationDestination(item: $probe) { found in
                CustomConnectorDetails(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (found.serverName ?? url?.host ?? "") : name,
                                       address: url?.absoluteString ?? address, probe: found, finish: { dismiss() })
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func stepRow(_ step: ConnectorProbe.Step, _ title: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            Spacer()
            if done.contains(step) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.systemGreen))
            } else if checking {
                ProgressView()
            } else if failure != nil {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.systemRed))
            }
        }
    }

    private func check() async {
        guard let url else { return }
        checking = true
        failure = nil
        done = []
        defer { checking = false }
        do {
            let found = try await ConnectorProbe.run(url) { step in done.insert(step) }
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let serverName = found.serverName { name = serverName }
            probe = found
        } catch let error as ConnectorProbe.Failure {
            failure = error.words
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension ConnectorProbe: Hashable, Identifiable {
    var id: String { "\(resourceMetadata?.absoluteString ?? "")|\(authorizationServer?.absoluteString ?? "")|\(registration)|\(transport)" }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The second step: only what matters, each choice the check made preselected and marked.
struct CustomConnectorDetails: View {
    enum SignIn: Hashable { case now, whenNeeded, none }

    let name: String
    let address: String
    let probe: ConnectorProbe
    var finish: () -> Void

    @State private var signIn: SignIn = .now
    @State private var advanced = false
    @State private var ownClient = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var headers: [(name: String, value: String)] = []
    @State private var transport: ConnectorProbe.Transport = .streamableHTTP
    @State private var working = false
    @State private var problem: String?

    private var detectedSignIn: SignIn { probe.needsSignIn ? .now : .none }

    var body: some View {
        Form {
            Section {
                LabeledContent(AppLocalization.text("Name"), value: name)
                LabeledContent(AppLocalization.text("Server Address")) {
                    Text(verbatim: address).lineLimit(1).truncationMode(.middle)
                }
            }
            Section {
                Picker(selection: $signIn) {
                    choice("Sign In Now", .now)
                    choice("Sign In When Needed", .whenNeeded)
                    choice("No Sign-In", .none)
                } label: {
                    Label("Sign-In", systemImage: "person.badge.key")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Group {
                    SettingsHeader("Sign-In")
                }
                .settingsHeader()
            } footer: {
                Group {
                    if probe.needsSignIn {
                        switch probe.registration {
                        case .dynamic: Text("Detected. Poki registers itself with the server’s sign-in.")
                        case .metadataDocument: Text("Detected. The server takes a client ID document. If signing in fails, use your own client under Advanced.")
                        case .none: Text("Detected. The server needs your own client, under Advanced.")
                        }
                    }
                }
                .settingsFooter()
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Toggle("Use Your Own Client", isOn: $ownClient)
                    if ownClient {
                        TextField(AppLocalization.text("Client ID"), text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(AppLocalization.text("Client Secret, Optional"), text: $clientSecret)
                    }
                    ForEach(headers.indices, id: \.self) { index in
                        TextField(AppLocalization.text("Header Name"), text: $headers[index].name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(AppLocalization.text("Header Value"), text: $headers[index].value)
                    }
                    if headers.count < 4 {
                        Button("Add Request Header", systemImage: "plus") { headers.append(("", "")) }
                    }
                    Picker(AppLocalization.text("Transport"), selection: $transport) {
                        Text("Streamable HTTP").tag(ConnectorProbe.Transport.streamableHTTP)
                        Text("SSE, Legacy").tag(ConnectorProbe.Transport.sseLegacy)
                    }
                }
            } footer: {
                Group {
                    if transport == .sseLegacy { Text("Poki can’t use the older SSE transport yet. Ask the server for its Streamable HTTP address.") }
                    else if let problem { Text(verbatim: problem).foregroundStyle(Tint.red) }
                    else { Text("Only add connectors from developers you trust.") }
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Add Custom Connector"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            signIn = detectedSignIn
            transport = probe.transport
            ownClient = probe.needsSignIn && probe.registration == .none
            advanced = ownClient
        }
        .safeAreaInset(edge: .bottom) {
            StartButtons(primary: "Connect", action: { Task { await connect() } }, primaryID: "customConnector.connect")
                .disabled(working || transport == .sseLegacy || (ownClient && clientID.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    @ViewBuilder private func choice(_ title: LocalizedStringKey, _ value: SignIn) -> some View {
        HStack {
            Text(title)
            if value == detectedSignIn {
                Text("Detected").font(.allo(.footnote)).foregroundStyle(.secondary)
            }
        }
        .tag(value)
    }

    private func connect() async {
        working = true
        problem = nil
        defer { working = false }
        var connector = MCPConnector(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, url: address,
                                     sign: signIn == .none ? .none : .oauth, symbol: "puzzlepiece.extension", custom: true)
        connector.signInWhenNeeded = signIn == .whenNeeded
        connector.registration = probe.registration
        connector.transport = transport
        connector.iconURL = URL(string: address).flatMap(ConnectorIconCache.address(for:))
        let kept = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty }
        connector.headerNames = kept.isEmpty ? nil : kept.map { $0.name.trimmingCharacters(in: .whitespaces) }
        if ownClient, !clientID.trimmingCharacters(in: .whitespaces).isEmpty {
            connector.clientID = clientID.trimmingCharacters(in: .whitespaces)
            if !clientSecret.isEmpty { MCPCredentials.save(clientSecret: clientSecret, for: connector.id) }
        }
        for header in kept { MCPCredentials.save(header: header.value, named: header.name.trimmingCharacters(in: .whitespaces), for: connector.id) }
        MCPConnectors.shared.addCustom(connector)
        if signIn == .whenNeeded { finish(); return }
        do {
            _ = try await MCPSignIn.add(connector)
            finish()
        } catch MCPConnectorError.cancelled {
            finish()
        } catch {
            problem = MCPConnectorError.words(error)
        }
    }
}
