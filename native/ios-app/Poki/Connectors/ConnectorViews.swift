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
    /// Marks that already are a tile of their own.
    static let tiles: Set<String> = ["Connector-stripe", "Connector-asana"]
    let connector: MCPConnector
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29
    @State private var fetched: UIImage?

    var body: some View {
        let size = min(side, 40)
        Group {
            if let name = connector.iconAsset, let image = UIImage(named: name) {
                if Self.tiles.contains(name) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    // A mark on its own goes on a plain tile, as on a Home Screen.
                    Image(uiImage: image).resizable().scaledToFit()
                        .padding(size * 0.2)
                        .frame(width: size, height: size)
                        .background(Color(.tertiarySystemBackground))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
                }
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


/// Add Custom Connector, in two steps. Step 1: a name and the server's address, and a live check of
/// the server that shows each step and what the server answered. Step 2: how Poki signs in, which
/// OAuth client it uses, request headers and the transport, every choice explained in a line, and
/// what the check found preselected and marked Detected.
struct AddCustomConnectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = "https://"
    @State private var checking = false
    @State private var done: [ConnectorProbe.Step: Int] = [:]
    @State private var failure: String?
    /// What the check found: the steps stay on screen with it, and Next goes on to step 2.
    @State private var found: ConnectorProbe?
    @State private var probe: ConnectorProbe?

    private var url: URL? {
        URL(string: address.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppLocalization.text("Name"), text: $name)
                        .onChange(of: name) { if !checking, found != nil { found = nil; done = [:] } }
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("customConnector.name")
                } header: {
                    Group {
                        SettingsHeader("Step 1 of 2")
                    }
                    .settingsHeader()
                } footer: {
                    Group {
                        Text("Shown in the connectors list.")
                    }
                    .settingsFooter()
                }
                Section {
                    TextField(AppLocalization.text("Server Address"), text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("customConnector.address")
                        .onChange(of: address) { if !checking { found = nil; done = [:]; failure = nil } }
                } footer: {
                    Group {
                        // Verbatim, so the example address is not a link.
                        Text(verbatim: AppLocalization.text(LocalizedStringResource("The HTTPS address where the server takes MCP requests, for example https://mcp.example.com/mcp.")))
                    }
                    .settingsFooter()
                }
                if checking || !done.isEmpty || failure != nil {
                    Section {
                        stepRow(.server, "Connecting to the Server")
                        stepRow(.signInSettings, "Looking Up Sign-In Settings")
                        stepRow(.provider, "Checking the Sign-In Provider")
                    } header: {
                        Group {
                            SettingsHeader(checking ? "Checking the Server" : "Server Check")
                        }
                        .settingsHeader()
                    } footer: {
                        Group {
                            if let failure { Text(verbatim: failure).foregroundStyle(Tint.red) }
                            else if found != nil { Text("Server found.") }
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
                StartButtons(primary: found == nil ? "Continue" : "Next", action: {
                    if let found { probe = found } else { Task { await check() } }
                }, primaryID: "customConnector.continue")
                    .disabled(url == nil || checking)
            }
            .navigationDestination(item: $probe) { found in
                CustomConnectorDetails(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (found.serverName ?? url?.host ?? "") : name,
                                       address: url?.absoluteString ?? address, probe: found, finish: { dismiss() })
            }
        }
        .presentationDetents([.large])
    }

    /// A step of the check: Done and the status the server answered, a spinner, or a cross.
    @ViewBuilder private func stepRow(_ step: ConnectorProbe.Step, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Group {
                if done[step] != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.systemGreen))
                } else if checking {
                    ProgressView()
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.systemRed))
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.allo(.body))
                if done[step] != nil { Text("Done").font(.allo(.footnote)).foregroundStyle(.secondary) }
            }
            Spacer()
            if let code = done[step], code > 0 {
                Text(verbatim: String(code)).font(.allo(.subheadline)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func check() async {
        guard let url else { return }
        // The keyboard goes down, so the check's steps are in sight.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        checking = true
        failure = nil
        done = [:]
        found = nil
        defer { checking = false }
        do {
            let result = try await ConnectorProbe.run(url) { step, code in done[step] = code }
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let serverName = result.serverName { name = serverName }
            found = result
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

/// One choice of a group: a tick, its name with Detected when the check chose it, and a line on what it does.
private struct ConnectorChoice: View {
    let title: LocalizedStringKey
    let about: LocalizedStringKey
    var detected = false
    let chosen: Bool
    var pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.allo(.body)).foregroundStyle(chosen ? Tint.blue : Color(.tertiaryLabel))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.allo(.body)).foregroundStyle(Color(.label))
                        if detected {
                            Text("Detected").font(.allo(.caption, .semibold)).foregroundStyle(Tint.blue)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Tint.blue.opacity(0.12), in: .capsule)
                        }
                    }
                    Text(about).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The second step: how Poki signs in, which OAuth client it uses, request headers and the transport.
struct CustomConnectorDetails: View {
    enum SignIn: Hashable { case now, whenNeeded, none }
    enum Client: Hashable { case automatic, own }

    let name: String
    let address: String
    let probe: ConnectorProbe
    var finish: () -> Void

    @State private var signIn: SignIn = .now
    @State private var client: Client = .automatic
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var headers: [(name: String, value: String)] = []
    @State private var transport: ConnectorProbe.Transport = .streamableHTTP
    @State private var working = false
    @State private var problem: String?

    private var detectedSignIn: SignIn { probe.needsSignIn ? .now : .none }
    private var detectedClient: Client? {
        guard probe.needsSignIn else { return nil }
        return probe.registration == .dynamic ? .automatic : .own
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(AppLocalization.text("Name"), value: name)
                LabeledContent(AppLocalization.text("Server Address")) {
                    Text(verbatim: address).lineLimit(1).truncationMode(.middle)
                }
            } header: {
                Group {
                    SettingsHeader("Step 2 of 2")
                }
                .settingsHeader()
            }
            Section {
                ConnectorChoice(title: "Sign In Now", about: "You sign in through the server’s own sign-in before Poki uses any of its tools.",
                                detected: detectedSignIn == .now, chosen: signIn == .now) { signIn = .now }
                ConnectorChoice(title: "Sign In When Needed", about: "Poki connects without signing in and asks you to sign in when the server wants it. For servers with some tools open to everyone.",
                                chosen: signIn == .whenNeeded) { signIn = .whenNeeded }
                ConnectorChoice(title: "No Sign-In", about: "For servers with open access, or ones that take an API key in a request header instead.",
                                detected: detectedSignIn == .none, chosen: signIn == .none) { signIn = .none }
            } header: {
                Group {
                    SettingsHeader("Sign-In")
                }
                .settingsHeader()
            }
            if signIn != .none {
                Section {
                    ConnectorChoice(title: "Register Automatically", about: "Poki registers itself with the server’s sign-in as you connect. Works with most servers.",
                                    detected: detectedClient == .automatic, chosen: client == .automatic) { client = .automatic }
                    ConnectorChoice(title: "Use Your Own OAuth Client", about: "A client ID you registered with the server yourself. Leave the secret empty unless the server asks for one.",
                                    detected: detectedClient == .own, chosen: client == .own) { client = .own }
                    if client == .own {
                        TextField(AppLocalization.text("Client ID"), text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("customConnector.clientID")
                        SecureField(AppLocalization.text("Client Secret, Optional"), text: $clientSecret)
                    }
                } header: {
                    Group {
                        SettingsHeader("OAuth Client")
                    }
                    .settingsHeader()
                } footer: {
                    Group {
                        if probe.registration == .metadataDocument {
                            Text("This server takes a client ID document, which Poki does not publish yet. Use your own client.")
                        }
                    }
                    .settingsFooter()
                }
            }
            Section {
                ForEach(headers.indices, id: \.self) { index in
                    TextField(AppLocalization.text("Header Name"), text: $headers[index].name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(AppLocalization.text("Header Value"), text: $headers[index].value)
                }
                if headers.count < 4 {
                    Button("Add Request Header", systemImage: "plus") { headers.append(("", "")) }
                }
            } header: {
                Group {
                    SettingsHeader("Request Headers")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Sent with every request, beside the sign-in. Values stay in the keychain and are never shown again. Up to four.")
                }
                .settingsFooter()
            }
            Section {
                ConnectorChoice(title: "Streamable HTTP", about: "The current MCP transport. Use this unless the server only offers SSE.",
                                detected: probe.transport == .streamableHTTP, chosen: transport == .streamableHTTP) { transport = .streamableHTTP }
                ConnectorChoice(title: "SSE, Legacy", about: "An older transport, chosen by itself when the address ends in /sse. Poki can’t use it yet.",
                                detected: probe.transport == .sseLegacy, chosen: transport == .sseLegacy) { transport = .sseLegacy }
            } header: {
                Group {
                    SettingsHeader("Transport")
                }
                .settingsHeader()
            } footer: {
                Group {
                    if let problem { Text(verbatim: problem).foregroundStyle(Tint.red) }
                    else if transport == .sseLegacy { Text("Ask the server for its Streamable HTTP address.") }
                    else { Text("Set from the address. Change it only if the server’s documentation says so.") }
                }
                .settingsFooter()
            }
            Section {} footer: {
                Group {
                    Text("Only add connectors from developers you trust. Poki can’t check what a server’s tools do, or whether they change.")
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Add Custom Connector"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            signIn = detectedSignIn
            transport = probe.transport
            client = detectedClient ?? .automatic
        }
        .safeAreaInset(edge: .bottom) {
            StartButtons(primary: "Connect", action: { Task { await connect() } }, primaryID: "customConnector.connect")
                .disabled(working || transport == .sseLegacy
                          || (signIn != .none && client == .own && clientID.trimmingCharacters(in: .whitespaces).isEmpty))
        }
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
        if signIn != .none, client == .own, !clientID.trimmingCharacters(in: .whitespaces).isEmpty {
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
