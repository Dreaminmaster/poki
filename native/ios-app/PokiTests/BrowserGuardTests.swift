import Foundation
import Network
import PokiCore
import XCTest
@testable import Poki

/// Poki's browser tools on a real page served from 127.0.0.1: what Poki must not tap for the owner. A
/// cookie banner with a reject choice is dismissed with that choice, not with Accept; sign-in, sign-up,
/// age and terms buttons go to the owner (web_handoff). Each button on the page writes what was tapped
/// into the page, so the test reads the page to see whether a tap happened. A sign-in prompt that
/// mentions privacy is not taken for a cookie banner.
@MainActor
final class BrowserGuardTests: XCTestCase {
    override func tearDown() async throws {
        PokiBrowser.shared.close()
    }

    func testPokiRejectsCookiesAndLeavesSignInAgeAndTermsToTheOwner() async throws {
        let server = try PageServer(html: Self.page)
        let opened = await WebTools.perform("web_open", arguments: Self.json(["url": "http://127.0.0.1:\(server.port)/"]))
        XCTAssertFalse(opened.isError, opened.text)
        let accept = try Self.ref("Accept all", in: opened.text)
        let reject = try Self.ref("Reject all", in: opened.text)

        let accepted = await WebTools.perform("web_click", arguments: Self.json(["ref": accept]))
        XCTAssertTrue(accepted.isError, accepted.text)
        XCTAssertTrue(accepted.text.contains("[\(reject)]"), "names the reject choice: \(accepted.text)")

        for label in ["Sign In", "Create account", "I am 21 or older", "I agree to the Terms of Service"] {
            let tapped = await WebTools.perform("web_click", arguments: Self.json(["ref": try Self.ref(label, in: opened.text)]))
            XCTAssertTrue(tapped.isError, "\(label): \(tapped.text)")
            XCTAssertTrue(tapped.text.contains("web_handoff"), "\(label): \(tapped.text)")
        }
        let page = await WebTools.perform("web_read", arguments: "{}")
        XCTAssertFalse(page.text.contains("Tapped:"), "nothing on the page was tapped: \(page.text)")

        let rejected = await WebTools.perform("web_click", arguments: Self.json(["ref": reject]))
        XCTAssertFalse(rejected.isError, rejected.text)
        XCTAssertTrue(rejected.text.contains("Tapped: Reject all"), rejected.text)
    }

    /// A sign-in prompt also floats over the page and mentions privacy, and its button says Continue:
    /// it is not a consent banner, so Poki is neither pointed at Continue nor allowed to tap it.
    func testASignInPromptIsNotTakenForACookieBanner() async throws {
        let server = try PageServer(html: Self.signIn)
        let opened = await WebTools.perform("web_open", arguments: Self.json(["url": "http://127.0.0.1:\(server.port)/"]))
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertFalse(opened.text.contains("banner is open"), "no banner hint on a sign-in prompt: \(opened.text)")

        for label in ["Continue", "Continue with Google"] {
            let tapped = await WebTools.perform("web_click", arguments: Self.json(["ref": try Self.ref(label, in: opened.text)]))
            XCTAssertTrue(tapped.isError, "\(label): \(tapped.text)")
            XCTAssertTrue(tapped.text.contains("web_handoff"), "\(label): \(tapped.text)")
        }
        let page = await WebTools.perform("web_read", arguments: "{}")
        XCTAssertFalse(page.text.contains("Tapped:"), "nothing on the page was tapped: \(page.text)")
    }

    private static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Showtimes</title></head>
    <body>
    <h1>Showtimes</h1>
    <p id="log"></p>
    <button>Sign In</button>
    <a href="#join" role="button">Create account</a>
    <section><h2>Rated R</h2><button>I am 21 or older</button></section>
    <form><button type="button">I agree to the Terms of Service</button></form>
    <div id="cookie-banner" style="position:fixed;left:0;right:0;bottom:0;background:#fff;padding:12px">
      <p>We and our partners use cookies for analytics and advertising.</p>
      <button>Accept all</button>
      <button onclick="this.parentElement.style.display='none'">Reject all</button>
    </div>
    <script>
    for (const b of document.querySelectorAll('button, [role=button]')) {
      b.addEventListener('click', (e) => { e.preventDefault(); document.getElementById('log').textContent = 'Tapped: ' + b.textContent; });
    }
    </script>
    </body></html>
    """

    private static let signIn = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>News</title></head>
    <body>
    <h1>Today's story</h1>
    <p id="log"></p>
    <div role="dialog" style="position:fixed;inset:0;background:#fff;padding:24px">
      <h2>Sign in to keep reading</h2>
      <input type="email" placeholder="Email address">
      <button>Continue</button>
      <button>Continue with Google</button>
      <p>By continuing you agree to our Terms of Use and Privacy Policy.</p>
    </div>
    <script>
    for (const b of document.querySelectorAll('button')) {
      b.addEventListener('click', () => { document.getElementById('log').textContent = 'Tapped: ' + b.textContent; });
    }
    </script>
    </body></html>
    """

    private static func ref(_ label: String, in text: String) throws -> String {
        let pattern = "\\[(e\\d+)\\] (?:button|link) \"" + NSRegularExpression.escapedPattern(for: label) + "\""
        let match = try XCTUnwrap(try NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                  "“\(label)” is on the page read: \(text)")
        return String(text[Range(match.range(at: 1), in: text)!])
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// One HTML page on 127.0.0.1, whatever the path.
private final class PageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "page-server")
    private let html: String

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(html: String) throws {
        self.html = html
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            let received = received + (data ?? Data())
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                let path = String(decoding: received.prefix(64), as: UTF8.self).split(separator: " ").dropFirst().first ?? "/"
                let body = path == "/" ? self.html : ""
                let status = path == "/" ? "200 OK" : "404 Not Found"
                let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                return connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            if done || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }
}
