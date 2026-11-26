import Foundation

/// The live check behind Add Custom Connector: reach the server, find how it signs in, and pick the
/// client registration it supports, so the owner only gives a name and an address. Everything found
/// is preselected and marked as detected; nothing here asks the owner a question.
struct ConnectorProbe: Equatable {
    enum Step: Int, CaseIterable, Equatable {
        case server, signInSettings, provider
    }

    enum Registration: String, Codable, Equatable {
        /// Dynamic client registration (RFC 7591): the server registers Poki on the spot.
        case dynamic
        /// A client ID metadata document: Poki's client ID is the address of its own description.
        case metadataDocument
        /// Neither: the owner's own client ID is needed.
        case none
    }

    enum Transport: String, Codable, Equatable {
        case streamableHTTP
        /// The older server-sent events transport, which Poki does not speak.
        case sseLegacy
    }

    var serverName: String?
    /// The server answered 401: it wants a sign-in.
    var needsSignIn = false
    var resourceMetadata: URL?
    var authorizationServer: URL?
    var registration: Registration = .none
    var transport: Transport = .streamableHTTP

    // MARK: Parsing, kept apart from the network so it is tested on its own

    /// `resource_metadata` from a 401's WWW-Authenticate header (RFC 9728 §5.1).
    static func resourceMetadata(fromWWWAuthenticate header: String) -> URL? {
        let pattern = try! NSRegularExpression(pattern: #"resource_metadata\s*=\s*"([^"]+)""#, options: [.caseInsensitive])
        let range = NSRange(header.startIndex..., in: header)
        guard let match = pattern.firstMatch(in: header, range: range), let value = Range(match.range(at: 1), in: header) else { return nil }
        return URL(string: String(header[value]))
    }

    /// The protected resource metadata's well-known addresses for a server (RFC 9728 §3): with the
    /// server's path first, then the origin's.
    static func protectedResourceURLs(for server: URL) -> [URL] {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return [] }
        let path = parts.path == "/" ? "" : parts.path
        parts.query = nil
        parts.fragment = nil
        var urls: [URL] = []
        if !path.isEmpty {
            parts.path = "/.well-known/oauth-protected-resource" + path
            if let url = parts.url { urls.append(url) }
        }
        parts.path = "/.well-known/oauth-protected-resource"
        if let url = parts.url { urls.append(url) }
        return urls
    }

    /// The first authorization server a protected resource names.
    static func authorizationServer(fromResourceMetadata data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["authorization_servers"] as? [String], let first = servers.first else { return nil }
        return URL(string: first)
    }

    /// The authorization server's metadata addresses (RFC 8414 and OpenID Connect discovery).
    static func authorizationServerMetadataURLs(for issuer: URL) -> [URL] {
        guard var parts = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = parts.path == "/" ? "" : parts.path
        var urls: [URL] = []
        for name in ["oauth-authorization-server", "openid-configuration"] {
            parts.path = "/.well-known/\(name)" + path
            if let url = parts.url { urls.append(url) }
        }
        if !path.isEmpty, let url = URL(string: issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/openid-configuration") {
            urls.append(url)
        }
        return urls
    }

    /// How Poki registers with this authorization server: dynamic registration when it has a
    /// registration endpoint (what Poki speaks), else a client ID metadata document when the server
    /// says it takes one (which Poki does not publish yet), else neither.
    static func registration(fromAuthorizationServerMetadata data: Data) -> Registration {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        if let endpoint = object["registration_endpoint"] as? String, !endpoint.isEmpty { return .dynamic }
        if object["client_id_metadata_document_supported"] as? Bool == true { return .metadataDocument }
        return .none
    }

    /// The legacy transport for an address that ends in /sse.
    static func transport(for server: URL) -> Transport {
        server.path.lowercased().hasSuffix("/sse") ? .sseLegacy : .streamableHTTP
    }

    /// The server's own name from an initialize answer, as JSON or as one server-sent event.
    static func serverName(fromInitialize body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        let json = text.split(separator: "\n").first { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? text
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let info = result["serverInfo"] as? [String: Any] else { return nil }
        let name = (info["title"] as? String) ?? (info["name"] as? String)
        return name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name : nil
    }

    // MARK: The live check

    enum Failure: Error, Equatable {
        case notHTTPS
        case unreachable
        case notMCP(Int)
        case noSignInSettings
        case noProvider
    }

    /// Reaches the server and works out its sign-in. `progress` gets each step as it finishes, with
    /// the HTTP status the server answered it with (0 when the step needed no request of its own).
    static func run(_ server: URL, session: URLSession = .shared, progress: @escaping @MainActor (Step, Int) -> Void) async throws -> ConnectorProbe {
        guard server.scheme == "https", server.host != nil else { throw Failure.notHTTPS }
        var probe = ConnectorProbe()
        probe.transport = transport(for: server)

        var request = URLRequest(url: server, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Poki","version":"1.0.0"}}}"#.utf8)
        let (body, response): (Data, URLResponse)
        do { (body, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200..<300:
            probe.serverName = serverName(fromInitialize: body)
            await progress(.server, http.statusCode)
            await progress(.signInSettings, 0)
            await progress(.provider, 0)
            return probe
        case 401:
            probe.needsSignIn = true
            await progress(.server, 401)
        default:
            throw Failure.notMCP(http.statusCode)
        }

        // Sign-in settings: where the 401 points, else the well-known addresses.
        let header = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        let candidates = (resourceMetadata(fromWWWAuthenticate: header).map { [$0] } ?? []) + protectedResourceURLs(for: server)
        var resourceStatus = 0
        for url in candidates {
            guard let (data, status) = await fetch(url, session: session) else { continue }
            resourceStatus = status
            guard status == 200, let issuer = authorizationServer(fromResourceMetadata: data) else { continue }
            probe.resourceMetadata = url
            probe.authorizationServer = issuer
            break
        }
        // A server with no resource metadata often is its own authorization server.
        if probe.authorizationServer == nil, var origin = URLComponents(url: server, resolvingAgainstBaseURL: false) {
            origin.path = ""
            origin.query = nil
            probe.authorizationServer = origin.url
        }
        await progress(.signInSettings, probe.resourceMetadata == nil ? 0 : resourceStatus)

        guard let issuer = probe.authorizationServer else { throw Failure.noSignInSettings }
        for url in authorizationServerMetadataURLs(for: issuer) {
            guard let (data, status) = await fetch(url, session: session), status == 200 else { continue }
            probe.registration = registration(fromAuthorizationServerMetadata: data)
            await progress(.provider, status)
            return probe
        }
        throw Failure.noProvider
    }

    private static func fetch(_ url: URL, session: URLSession) async -> (Data, Int)? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }
}

extension ConnectorProbe.Failure {
    var words: String {
        switch self {
        case .notHTTPS: AppLocalization.text(LocalizedStringResource("Use an address that starts with https."))
        case .unreachable: AppLocalization.text(LocalizedStringResource("The server did not answer. Check the address and your connection."))
        case .notMCP(let code): AppLocalization.text(LocalizedStringResource("The server answered \(code), not as an MCP server. Check the address, which often ends in /mcp."))
        case .noSignInSettings: AppLocalization.text(LocalizedStringResource("The server wants a sign-in but does not say where. Use your own client under Advanced."))
        case .noProvider: AppLocalization.text(LocalizedStringResource("The sign-in provider did not answer. Try again, or use your own client under Advanced."))
        }
    }
}
