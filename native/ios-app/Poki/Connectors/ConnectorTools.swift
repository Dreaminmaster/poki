import Foundation
import PiSwiftAgent
import PiSwiftAI
import PiSwiftMCP

/// The connectors' tools as pi tools for the chat's loop. Each account's tools carry its own prefix
/// ("notion__search", "notion2__search" for a second account), so the model can tell accounts apart,
/// and the description says which account it is. A tool that is not marked read only goes through
/// Poki's approvals first (the account's Ask setting decides), as a step on the phone does.
@MainActor
enum ConnectorTools {
    /// Asks the owner, through Poki's approvals, whether a connector's step may run.
    typealias Clearance = @MainActor (_ connector: String, _ summary: String, _ always: Bool) async -> Bool

    /// The tools of every account in use for a message: those used automatically, and those it
    /// mentions with @.
    static func tools(mentioned: Set<UUID>, clear: @escaping Clearance) -> [AgentTool] {
        let store = MCPConnectors.shared
        var out: [AgentTool] = []
        var taken = Set<String>()
        for connector in store.all {
            for (index, account) in store.accounts(of: connector).enumerated() where account.automatic || mentioned.contains(account.id) {
                let prefix = connector.slug + (index == 0 ? "" : "\(index + 1)")
                let title = store.title(account)
                for tool in store.tools[account.id] ?? [] where !account.disabledTools.contains(tool.name) {
                    let name = uniqueName(prefix: prefix, tool: tool.name, taken: &taken)
                    out.append(agentTool(name: name, tool: tool, title: title, account: account, connector: connector, clear: clear))
                }
            }
        }
        return out
    }

    /// The accounts a message mentions: "@Notion" for every Notion account, "@NotionWork" for one.
    static func mentioned(in text: String) -> Set<UUID> {
        let store = MCPConnectors.shared
        var out = Set<UUID>()
        for connector in store.connected {
            for account in store.accounts(of: connector) {
                let handles = ["@" + connector.handle, "@" + store.title(account).replacingOccurrences(of: " ", with: "")]
                if handles.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) { out.insert(account.id) }
            }
        }
        return out
    }

    /// Reaches every account whose tools are not known yet, before a message that may use them. The
    /// message waits a few seconds at most: an account still connecting joins the next message.
    static func prepare(_ accounts: Set<UUID>) async {
        let store = MCPConnectors.shared
        let pending = store.accounts.compactMap { account -> (MCPConnectorAccount, MCPConnector)? in
            guard account.automatic || accounts.contains(account.id), store.tools[account.id] == nil, store.problems[account.id] == nil,
                  let connector = store.connector(account.connector) else { return nil }
            return (account, connector)
        }
        guard !pending.isEmpty else { return }
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for (account, connector) in pending { group.addTask { await MCPSessions.shared.refresh(account, connector: connector) } }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: .seconds(6)) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func agentTool(name: String, tool: McpTool, title: String, account: MCPConnectorAccount, connector: MCPConnector,
                                  clear: @escaping Clearance) -> AgentTool {
        let schema = (tool.inputSchema?.value as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
        let about = tool.description ?? tool.title ?? tool.name
        let readOnly = tool.annotations?.readOnlyHint == true
        let toolName = tool.name
        let label = tool.annotations?.title ?? tool.title ?? tool.name
        return AgentTool(label: label, name: name,
                         description: "[\(title) connector] \(about)",
                         parameters: schema.mapValues { AnyCodable($0) }) { _, params, signal, _ in
            let asks: Bool = switch account.asks {
            case .never: false
            case .always: true
            case .changes: !readOnly
            }
            if asks {
                let summary = AppLocalization.text(LocalizedStringResource("Use \(label) in \(title)"))
                let allowed = await clear(title, summary, account.asks == .always)
                if !allowed {
                    return AgentToolResult(content: [.text(TextContent(text: "The owner did not approve this \(title) step. It was not run."))], isError: true)
                }
            }
            do {
                let result = try await MCPSessions.shared.call(toolName, arguments: params, account: account, connector: connector, signal: signal)
                let blocks = resolveMcpResultContent(result)
                let line = "\(connector.id) \(toolName): \(result.isError ? "error" : "ok")"
                await MainActor.run { AppLog.shared.add("connector", line) }
                return AgentToolResult(content: blocks.isEmpty ? [.text(TextContent(text: "Done."))] : blocks, isError: result.isError)
            } catch {
                let words = MCPConnectorError.words(error)
                await MainActor.run { MCPConnectors.shared.failed(account.id, words) }
                return AgentToolResult(content: [.text(TextContent(text: "\(title) could not be reached: \(words)"))], isError: true)
            }
        }
    }

    /// `prefix__tool`, within the 64 characters providers allow, made of letters, digits, _ and -.
    static func uniqueName(prefix: String, tool: String, taken: inout Set<String>) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let clean = String(String.UnicodeScalarView(tool.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        var name = String((prefix + "__" + clean).prefix(64))
        var n = 2
        while !taken.insert(name).inserted {
            let tail = "_\(n)"
            name = String((prefix + "__" + clean).prefix(64 - tail.count)) + tail
            n += 1
        }
        return name
    }
}
