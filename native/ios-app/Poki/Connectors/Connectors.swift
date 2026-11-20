import Foundation
import PiSwiftMCP

/// Connectors: remote MCP servers the chat's model can use beside the phone (Settings › Connectors).
/// A connector is a service (Notion, Linear, or one the owner adds by its address); each one can hold
/// several accounts, and each account is its own sign-in with its own tokens in the keychain. The
/// MCP client is PiSwiftMCP, the same pi port the chat's loop runs on.
struct MCPConnector: Identifiable, Hashable, Codable {
    enum Sign: String, Codable, Hashable {
        /// MCP's OAuth (discovery, dynamic client registration, PKCE) in the system's sign-in sheet.
        case oauth
        /// A token the owner pastes, sent as a bearer token.
        case token
        /// Nothing: an open server.
        case none
    }

    let id: String
    var name: String
    var url: String
    var sign: Sign
    /// An SF Symbol for the connector's capsule and rows.
    var symbol: String
    /// Built in (from `presets`), or added by the owner.
    var custom = false
    /// Where a token is made, for a connector that takes one.
    var tokenHelp: String? = nil

    /// The name as written after @ in a message: no spaces, so the mention ends where the word does.
    var handle: String { name.replacingOccurrences(of: " ", with: "") }

    /// A short, model-safe prefix for its tools ("notion", "linear").
    var slug: String {
        let base = name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let text = String(String.UnicodeScalarView(base))
        return text.isEmpty ? "mcp" : String(text.prefix(16))
    }

    /// Common connectors with a remote MCP server on the open web. Their addresses are the services'
    /// own streamable HTTP endpoints.
    static let presets: [MCPConnector] = [
        MCPConnector(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", sign: .oauth, symbol: "doc.text"),
        MCPConnector(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", sign: .oauth, symbol: "line.3.horizontal.decrease.circle"),
        MCPConnector(id: "github", name: "GitHub", url: "https://api.githubcopilot.com/mcp/", sign: .token, symbol: "chevron.left.forwardslash.chevron.right",
                     tokenHelp: "https://github.com/settings/personal-access-tokens"),
        MCPConnector(id: "atlassian", name: "Atlassian", url: "https://mcp.atlassian.com/v1/mcp", sign: .oauth, symbol: "square.stack.3d.up"),
        MCPConnector(id: "asana", name: "Asana", url: "https://mcp.asana.com/v2/mcp", sign: .oauth, symbol: "circle.grid.cross"),
        MCPConnector(id: "canva", name: "Canva", url: "https://mcp.canva.com/mcp", sign: .oauth, symbol: "paintpalette"),
        MCPConnector(id: "stripe", name: "Stripe", url: "https://mcp.stripe.com", sign: .oauth, symbol: "creditcard"),
        MCPConnector(id: "huggingface", name: "Hugging Face", url: "https://huggingface.co/mcp", sign: .oauth, symbol: "face.smiling"),
    ]
}

/// One signed-in account of a connector.
struct MCPConnectorAccount: Identifiable, Hashable, Codable {
    enum Asks: String, Codable, CaseIterable, Identifiable {
        /// Tools the server marks read only run at once; the others go through Poki's approvals.
        case changes
        /// Every tool goes through Poki's approvals.
        case always
        /// Nothing is asked, also when Approvals ask for the phone.
        case never
        var id: String { rawValue }
    }

    let id: UUID
    let connector: String
    /// The owner's name for it ("Work", "Personal"); the connector's name with a number when left empty.
    var label: String
    /// Its tools are offered to the model in every chat. Off: only when the message mentions it.
    var automatic = true
    var asks: Asks = .changes
    /// Tool names the owner turned off.
    var disabledTools: Set<String> = []
    var added = Date()
}

/// The connectors and their accounts, saved as JSON in UserDefaults; the tokens are in the keychain.
@MainActor
@Observable
final class MCPConnectors {
    static let shared = MCPConnectors()
    nonisolated static let changed = Notification.Name("poki.connectors.changed")
    private static let customKey = "connectors.custom"
    private static let accountsKey = "connectors.accounts"

    private(set) var custom: [MCPConnector]
    private(set) var accounts: [MCPConnectorAccount]
    /// The tools each account answered with, after it was reached.
    private(set) var tools: [UUID: [McpTool]] = [:]
    /// What went wrong reaching an account, in words, until it is reached.
    private(set) var problems: [UUID: String] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = (defaults.data(forKey: Self.customKey)).flatMap { try? JSONDecoder().decode([MCPConnector].self, from: $0) } ?? []
        accounts = (defaults.data(forKey: Self.accountsKey)).flatMap { try? JSONDecoder().decode([MCPConnectorAccount].self, from: $0) } ?? []
        publishCapsules()
    }

    /// "@Notion" (and "@NotionWork" for each named account) shows as the connector's capsule.
    private func publishCapsules() {
        ConnectorCapsules.set(connected.map { connector in
            var names = ["@" + connector.handle]
            for account in accounts(of: connector) {
                let handle = "@" + title(account).replacingOccurrences(of: " ", with: "")
                if !names.contains(handle) { names.append(handle) }
            }
            return AppCapsule(id: ConnectorCapsules.prefix + connector.id, names: names, symbol: connector.symbol)
        })
    }

    var all: [MCPConnector] { MCPConnector.presets + custom }

    func connector(_ id: String) -> MCPConnector? { all.first { $0.id == id } }

    func accounts(of connector: MCPConnector) -> [MCPConnectorAccount] {
        accounts.filter { $0.connector == connector.id }.sorted { $0.added < $1.added }
    }

    /// Connectors with at least one account, in the order of `all`.
    var connected: [MCPConnector] { all.filter { c in accounts.contains { $0.connector == c.id } } }

    /// "Notion", or "Notion Work" when the connector has more than one account.
    func title(_ account: MCPConnectorAccount) -> String {
        guard let connector = connector(account.connector) else { return account.label }
        let label = account.label.trimmingCharacters(in: .whitespaces)
        if label.isEmpty {
            let index = (accounts(of: connector).firstIndex { $0.id == account.id } ?? 0) + 1
            return index == 1 ? connector.name : "\(connector.name) \(index)"
        }
        return "\(connector.name) \(label)"
    }

    // MARK: Changes

    func addCustom(name: String, url: String, sign: MCPConnector.Sign) -> MCPConnector {
        let connector = MCPConnector(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, url: url, sign: sign,
                                     symbol: "puzzlepiece.extension", custom: true)
        custom.append(connector)
        save()
        return connector
    }

    func update(_ connector: MCPConnector) {
        guard let index = custom.firstIndex(where: { $0.id == connector.id }) else { return }
        custom[index] = connector
        save()
    }

    func remove(_ connector: MCPConnector) {
        for account in accounts(of: connector) { remove(account) }
        custom.removeAll { $0.id == connector.id }
        save()
    }

    func add(_ account: MCPConnectorAccount) {
        accounts.append(account)
        save()
    }

    func update(_ account: MCPConnectorAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    func remove(_ account: MCPConnectorAccount) {
        accounts.removeAll { $0.id == account.id }
        tools[account.id] = nil
        problems[account.id] = nil
        MCPCredentials.delete(account.id)
        Task { await MCPSessions.shared.close(account.id) }
        save()
    }

    func reached(_ account: UUID, tools list: [McpTool]) {
        tools[account] = list
        problems[account] = nil
    }

    func failed(_ account: UUID, _ words: String) { problems[account] = words }

    private func save() {
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
        defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
        publishCapsules()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// An account's secrets in the keychain: its OAuth state (client registration and tokens) or its token.
enum MCPCredentials {
    private static func account(_ id: UUID) -> String { "connector.\(id.uuidString)" }

    static func oauth(_ id: UUID) -> McpOAuthState? {
        (try? Keychain.read(account(id))).flatMap { try? JSONDecoder().decode(McpOAuthState.self, from: $0) }
    }

    static func save(_ state: McpOAuthState, for id: UUID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? Keychain.write(data, account: account(id))
    }

    static func token(_ id: UUID) -> String? {
        (try? Keychain.read(account(id) + ".token")).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func save(token: String, for id: UUID) {
        try? Keychain.write(Data(token.utf8), account: account(id) + ".token")
    }

    static func delete(_ id: UUID) {
        Keychain.delete(account(id))
        Keychain.delete(account(id) + ".token")
    }
}

/// PiSwiftMCP's OAuth state, kept in the keychain for one account.
actor MCPKeychainOAuthStore: McpOAuthStateStore {
    let id: UUID
    init(_ id: UUID) { self.id = id }
    func load() -> McpOAuthState? { MCPCredentials.oauth(id) }
    func save(_ state: McpOAuthState) { MCPCredentials.save(state, for: id) }
}
