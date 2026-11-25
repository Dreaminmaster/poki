import PiSwiftMCP
import XCTest
@testable import Poki

final class ConnectorTests: XCTestCase {
    // MARK: Retrying a tool call

    /// A tool call is sent again only when the server ended the session (it never ran). A timeout, a
    /// server error or a cancel may come after the tool ran, so those are not sent twice.
    func testOnlyAnEndedSessionSendsAToolCallAgain() {
        XCTAssertTrue(MCPSessions.retriesOnFreshSession(McpSessionExpiredError(body: "")))
        XCTAssertFalse(MCPSessions.retriesOnFreshSession(CancellationError()))
        XCTAssertFalse(MCPSessions.retriesOnFreshSession(URLError(.timedOut)))
        XCTAssertFalse(MCPSessions.retriesOnFreshSession(McpHTTPError(status: 500, body: "", message: "boom")))
        XCTAssertFalse(MCPSessions.retriesOnFreshSession(McpTransportError.responseStreamFailed("cut")))
    }

    // MARK: The live check's parsing

    func testResourceMetadataComesFromA401() {
        let header = #"Bearer error="invalid_token", resource_metadata="https://pokimcp.zheha.nz/.well-known/oauth-protected-resource/mcp", scope="read""#
        XCTAssertEqual(ConnectorProbe.resourceMetadata(fromWWWAuthenticate: header)?.absoluteString,
                       "https://pokimcp.zheha.nz/.well-known/oauth-protected-resource/mcp")
        XCTAssertNil(ConnectorProbe.resourceMetadata(fromWWWAuthenticate: #"Bearer realm="x""#))
    }

    func testWellKnownAddresses() {
        let server = URL(string: "https://example.com/v1/mcp?x=1")!
        XCTAssertEqual(ConnectorProbe.protectedResourceURLs(for: server).map(\.absoluteString), [
            "https://example.com/.well-known/oauth-protected-resource/v1/mcp",
            "https://example.com/.well-known/oauth-protected-resource",
        ])
        XCTAssertEqual(ConnectorProbe.authorizationServerMetadataURLs(for: URL(string: "https://auth.example.com")!).map(\.absoluteString), [
            "https://auth.example.com/.well-known/oauth-authorization-server",
            "https://auth.example.com/.well-known/openid-configuration",
        ])
        XCTAssertEqual(ConnectorProbe.authorizationServerMetadataURLs(for: URL(string: "https://auth.example.com/tenant")!).first?.absoluteString,
                       "https://auth.example.com/.well-known/oauth-authorization-server/tenant")
    }

    func testAuthorizationServerAndRegistration() {
        let resource = Data(#"{"resource":"https://example.com/mcp","authorization_servers":["https://auth.example.com"]}"#.utf8)
        XCTAssertEqual(ConnectorProbe.authorizationServer(fromResourceMetadata: resource)?.absoluteString, "https://auth.example.com")
        XCTAssertEqual(ConnectorProbe.registration(fromAuthorizationServerMetadata: Data(#"{"registration_endpoint":"https://auth.example.com/register"}"#.utf8)), .dynamic)
        XCTAssertEqual(ConnectorProbe.registration(fromAuthorizationServerMetadata: Data(#"{"client_id_metadata_document_supported":true,"registration_endpoint":"https://a/r"}"#.utf8)), .dynamic, "what Poki speaks comes first")
        XCTAssertEqual(ConnectorProbe.registration(fromAuthorizationServerMetadata: Data(#"{"client_id_metadata_document_supported":true}"#.utf8)), .metadataDocument)
        XCTAssertEqual(ConnectorProbe.registration(fromAuthorizationServerMetadata: Data(#"{"issuer":"https://a"}"#.utf8)), .none)
    }

    func testTransportAndServerName() {
        XCTAssertEqual(ConnectorProbe.transport(for: URL(string: "https://a.com/sse")!), .sseLegacy)
        XCTAssertEqual(ConnectorProbe.transport(for: URL(string: "https://a.com/mcp")!), .streamableHTTP)
        let json = Data(#"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"poki-mcp","title":"Poki MCP"}}}"#.utf8)
        XCTAssertEqual(ConnectorProbe.serverName(fromInitialize: json), "Poki MCP")
        let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"Linear\"}}}\n\n".utf8)
        XCTAssertEqual(ConnectorProbe.serverName(fromInitialize: sse), "Linear")
    }

    // MARK: The registry and account names

    func testEveryPresetHasAnIconANameAndAnAddress() {
        let ids = Set(MCPConnector.presets.map(\.id))
        XCTAssertEqual(ids.count, MCPConnector.presets.count, "unique ids")
        for connector in MCPConnector.presets {
            XCTAssertNotNil(URL(string: connector.url)?.host, connector.id)
            XCTAssertFalse(connector.symbol.isEmpty, connector.id)
            XCTAssertNotNil(connector.about, connector.id)
            XCTAssertFalse(connector.custom, connector.id)
        }
    }

    func testAccountsAreNamedFromTheSignIn() {
        func jwt(_ claims: String) -> String {
            let body = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJub25lIn0.\(body).c2ln"
        }
        XCTAssertEqual(MCPConnectors.identity(idToken: jwt(#"{"email":"sam@example.com","name":"Sam"}"#), accessToken: nil), "sam@example.com")
        XCTAssertEqual(MCPConnectors.identity(idToken: nil, accessToken: jwt(#"{"preferred_username":"sam"}"#)), "sam")
        XCTAssertNil(MCPConnectors.identity(idToken: nil, accessToken: "opaque-token"))

        let notion = MCPConnector.presets[0]
        var account = MCPConnectorAccount(id: UUID(), connector: notion.id, label: "")
        XCTAssertEqual(MCPConnectors.title(account, connector: notion, index: 1), "Notion")
        XCTAssertEqual(MCPConnectors.title(account, connector: notion, index: 2), "Notion Account 2")
        account.identity = "sam@example.com"
        XCTAssertEqual(MCPConnectors.title(account, connector: notion, index: 2), "sam@example.com")
        account.label = "Work"
        XCTAssertEqual(MCPConnectors.title(account, connector: notion, index: 2), "Notion Work", "a rename wins")
    }

    func testOldSavedConnectorsAndAccountsStillLoad() throws {
        let id = UUID()
        let oldAccounts = Data(#"[{"id":"\#(id.uuidString)","connector":"notion","label":"Personal","automatic":true,"asks":"changes","disabledTools":[],"added":700000000}]"#.utf8)
        let accounts = try JSONDecoder().decode([MCPConnectorAccount].self, from: oldAccounts)
        XCTAssertEqual(accounts.first?.label, "Personal")
        XCTAssertNil(accounts.first?.identity)
        XCTAssertEqual(MCPConnectors.title(accounts[0], connector: MCPConnector.presets[0], index: 1), "Notion Personal")

        let oldCustom = Data(#"[{"id":"custom-ab12","name":"Mine","url":"https://a.com/mcp","sign":"oauth","symbol":"puzzlepiece.extension","custom":true}]"#.utf8)
        let custom = try JSONDecoder().decode([MCPConnector].self, from: oldCustom)
        XCTAssertEqual(custom.first?.name, "Mine")
        XCTAssertNil(custom.first?.clientID)
        XCTAssertNil(custom.first?.headerNames)
    }
}
