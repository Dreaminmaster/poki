import AuthenticationServices
import Foundation
import PiSwiftAI
import PiSwiftMCP
import UIKit

/// The open MCP connections, one per account, made when a chat first needs one and kept while Poki
/// runs. A connection that drops is made again on the next call.
actor MCPSessions {
    static let shared = MCPSessions()
    nonisolated static let redirect = URL(string: "poki://connector/callback")!
    nonisolated static let client = McpImplementation(name: "Poki", version: "1.0.0")

    private var clients: [UUID: McpClient] = [:]

    /// The account's client, connected; the tools it offers are saved on `MCPConnectors`.
    func client(for account: MCPConnectorAccount, connector: MCPConnector) async throws -> McpClient {
        if let client = clients[account.id], await client.isConnected() { return client }
        clients[account.id] = nil
        guard let url = URL(string: connector.url) else { throw MCPConnectorError.badAddress }
        let auth: (any McpAuthProvider)?
        // A custom connector's own request headers, their values from the keychain.
        var headers: [String: String] = [:]
        for name in connector.headerNames ?? [] {
            if let value = MCPCredentials.header(name, connector: connector.id) { headers[name] = value }
        }
        switch connector.sign {
        case .none: auth = nil
        case .token:
            guard let token = MCPCredentials.token(account.id) else { throw MCPConnectorError.signedOut }
            headers["Authorization"] = "Bearer \(token)"
            auth = nil
        case .oauth:
            guard MCPCredentials.oauth(account.id)?.tokens != nil else { throw MCPConnectorError.signedOut }
            // Refreshes run without a sheet; a sign-in that ran out says so, and the owner signs in again.
            let provider = McpOAuthProvider(serverURL: url, redirectURL: Self.redirect, clientMetadata: Self.metadata,
                                            clientID: connector.clientID, clientSecret: connector.clientID.flatMap { _ in MCPCredentials.clientSecret(connector.id) },
                                            store: MCPKeychainOAuthStore(account.id),
                                            onRedirect: { _ in throw MCPConnectorError.signedOut })
            auth = McpOAuthAuthAdapter(provider: provider)
        }
        let transport = StreamableHTTPTransport(url: url, headers: headers, authProvider: auth, openGetStream: false)
        let client = McpClient(requestTimeoutMs: 60_000, clientInfo: Self.client)
        try await client.connect(transport: transport)
        clients[account.id] = client
        return client
    }

    /// Connects and lists the account's tools.
    func refresh(_ account: MCPConnectorAccount, connector: MCPConnector) async {
        do {
            let client = try await client(for: account, connector: connector)
            let tools = try await client.listAllTools()
            await MainActor.run { MCPConnectors.shared.reached(account.id, tools: tools) }
        } catch {
            clients[account.id] = nil
            let words = MCPConnectorError.words(error)
            await MainActor.run { MCPConnectors.shared.failed(account.id, words) }
        }
    }

    func call(_ tool: String, arguments: [String: AnyCodable], account: MCPConnectorAccount, connector: MCPConnector,
              signal: CancellationToken?) async throws -> McpToolResult {
        do {
            return try await client(for: account, connector: connector).callTool(name: tool, arguments: arguments, signal: signal)
        } catch {
            // Once more on a fresh connection: the server may have ended the session.
            clients[account.id] = nil
            return try await client(for: account, connector: connector).callTool(name: tool, arguments: arguments, signal: signal)
        }
    }

    func close(_ account: UUID) async {
        await clients[account]?.close()
        clients[account] = nil
    }

    nonisolated static var metadata: McpOAuthClientMetadata {
        McpOAuthClientMetadata(redirectURIs: [redirect.absoluteString], applicationType: "native", clientName: "Poki",
                               clientURI: "https://github.com/JosssphZhou/poki")
    }
}

enum MCPConnectorError: LocalizedError {
    case badAddress, signedOut, cancelled

    var errorDescription: String? {
        switch self {
        case .badAddress: AppLocalization.text(LocalizedStringResource("This address is not a web address."))
        case .signedOut: AppLocalization.text(LocalizedStringResource("Sign in again to use this account."))
        case .cancelled: AppLocalization.text(LocalizedStringResource("Sign-in was cancelled."))
        }
    }

    static func words(_ error: Error) -> String {
        if let error = error as? MCPConnectorError { return error.errorDescription ?? "" }
        if case McpOAuthError.authorizationRequired = error { return MCPConnectorError.signedOut.errorDescription ?? "" }
        return error.localizedDescription
    }
}

/// MCP's OAuth in the system's sign-in sheet: the server's page opens, and its redirect to
/// `poki://connector/callback` comes back here.
@MainActor
final class MCPSignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("poki")) { callback, error in
                if let callback { continuation.resume(returning: callback); return }
                let failure: any Error = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    ? MCPConnectorError.cancelled : (error ?? MCPConnectorError.cancelled)
                continuation.resume(throwing: failure)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func cancel() { session?.cancel(); session = nil }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// The presenter PiSwiftMCP's sign-in asks to open the page.
struct MCPSheetPresenter: McpSignInPresenter {
    let sheet: MCPSignInSheet
    func redirectURL(for state: String) async throws -> URL { MCPSessions.redirect }
    func present(authorizationURL: URL, state: String) async throws -> URL { try await sheet.present(authorizationURL) }
    func cancel() async { await sheet.cancel() }
}

enum MCPSignIn {
    /// A new account: signed in (or its token saved), reached once, and added.
    @MainActor
    static func add(_ connector: MCPConnector, label: String = "", token: String? = nil) async throws -> MCPConnectorAccount {
        var account = MCPConnectorAccount(id: UUID(), connector: connector.id, label: label)
        try await signIn(account, connector: connector, token: token)
        // Named by who signed in, when the sign-in says (the owner, Nov 21 2026: no name field).
        let tokens = MCPCredentials.oauth(account.id)?.tokens
        account.identity = MCPConnectors.identity(idToken: tokens?.idToken, accessToken: tokens?.accessToken)
        MCPConnectors.shared.add(account)
        await MCPSessions.shared.refresh(account, connector: connector)
        return account
    }

    /// Signs an account in again (or for the first time).
    @MainActor
    static func signIn(_ account: MCPConnectorAccount, connector: MCPConnector, token: String? = nil) async throws {
        guard let url = URL(string: connector.url), url.scheme == "https" || url.scheme == "http" else { throw MCPConnectorError.badAddress }
        switch connector.sign {
        case .none: break
        case .token:
            let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else { throw MCPConnectorError.signedOut }
            MCPCredentials.save(token: token, for: account.id)
        case .oauth:
            let sheet = MCPSignInSheet()
            _ = try await McpOAuthSignIn.signIn(serverURL: url, presenter: MCPSheetPresenter(sheet: sheet),
                                                clientMetadata: MCPSessions.metadata, clientID: connector.clientID,
                                                clientSecret: connector.clientID.flatMap { _ in MCPCredentials.clientSecret(connector.id) },
                                                store: MCPKeychainOAuthStore(account.id))
        }
        await MCPSessions.shared.close(account.id)
    }
}
