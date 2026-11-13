import Foundation
import Network
import Observation
import PokiCore
import XCTest
@testable import Poki

/// Poki's browser tools on real pages served from 127.0.0.1, on the line between what Poki may tap and
/// what is the owner's. A notice that only informs (a cookie banner, a site's terms notice) Poki
/// dismisses itself, with the reject choice when there is one, and the step says so. Anything that
/// would give the owner an obligation or an identity (sign-in, sign-up, age, agreeing to terms, a
/// prompt with an email field) goes to the owner through web_handoff. Each button on a page writes what
/// was tapped into the page, so a test reads the page to see whether a tap happened.
@MainActor
final class BrowserGuardTests: XCTestCase {
    override func tearDown() async throws {
        PokiBrowser.shared.close()
    }

    func testPokiRejectsCookiesAndLeavesSignInAgeAndTermsToTheOwner() async throws {
        let server = try PageServer(pages: ["/": Self.page])
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
        XCTAssertEqual(PokiBrowser.shared.steps.last?.text, "Dismissed 127.0.0.1’s cookie banner: “Reject all”")
    }

    /// "By continuing to use this site you agree to our terms" only informs: Poki taps Continue itself,
    /// and the step names the notice it dismissed.
    func testPokiDismissesASiteTermsNoticeAndShowsItInTheSteps() async throws {
        let server = try PageServer(pages: ["/": Self.termsNotice])
        let opened = await WebTools.perform("web_open", arguments: Self.json(["url": "http://127.0.0.1:\(server.port)/"]))
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertTrue(opened.text.contains("banner is open"), "the notice is named: \(opened.text)")

        let tapped = await WebTools.perform("web_click", arguments: Self.json(["ref": try Self.ref("Continue", in: opened.text)]))
        XCTAssertFalse(tapped.isError, tapped.text)
        XCTAssertTrue(tapped.text.contains("Tapped: Continue"), tapped.text)
        XCTAssertEqual(PokiBrowser.shared.steps.last?.text, "Dismissed 127.0.0.1’s terms notice: “Continue”")
    }

    /// A sign-in prompt and a prompt that needs "I agree to the terms" ticked also float over the page,
    /// mention privacy and say Continue: they are the owner's, so Poki is neither pointed at Continue
    /// nor allowed to tap it.
    func testOwnersPromptsAreNotTakenForNotices() async throws {
        let server = try PageServer(pages: ["/": Self.signIn, "/agree": Self.agreeToTerms])
        for (path, labels) in [("/", ["Continue", "Continue with Google"]), ("/agree", ["Continue"])] {
            let opened = await WebTools.perform("web_open", arguments: Self.json(["url": "http://127.0.0.1:\(server.port)\(path)"]))
            XCTAssertFalse(opened.isError, opened.text)
            XCTAssertFalse(opened.text.contains("banner is open"), "\(path): no banner hint on the owner's prompt: \(opened.text)")
            for label in labels {
                let tapped = await WebTools.perform("web_click", arguments: Self.json(["ref": try Self.ref(label, in: opened.text)]))
                XCTAssertTrue(tapped.isError, "\(path) \(label): \(tapped.text)")
                XCTAssertTrue(tapped.text.contains("web_handoff"), "\(path) \(label): \(tapped.text)")
            }
            let page = await WebTools.perform("web_read", arguments: "{}")
            XCTAssertFalse(page.text.contains("Tapped:"), "\(path): nothing on the page was tapped: \(page.text)")
        }
    }

    func testOwnerFieldValuesStayOutOfModelSessionsAndLogs() async throws {
        let fields = [
            ("<input autocomplete='one-time-code' inputmode='numeric'>", "739281"),
            ("<input type='tel' autocomplete='section-pay billing cc-number'>", "4111222233334444"),
            ("<input type='password'>", "fake-password-739"),
            ("<input autocomplete='current-password'>", "fake-current-392"),
            ("<input autocomplete='new-password'>", "fake-new-824"),
            ("<input type='number' autocomplete='cc-csc'>", "937482"),
            ("<input autocomplete='cc-exp'>", "12/2039"),
            ("<input autocomplete='cc-exp-month'>", "fake-month-09"),
            ("<input autocomplete='cc-exp-year'>", "2038"),
            ("<input name='passportNumber'>", "FAKE-PASSPORT-821"),
            ("<input aria-label='身份证号码'>", "FAKE-ID-624"),
            ("<input name='verificationCode'>", "842617"),
            ("<input name='cardNumber'>", "5555666677778888"),
            ("<input name='expiryDate'>", "11/2037"),
            ("<input name='securityCode'>", "826491"),
            ("<input inputmode='numeric'>", "318642"),
            ("<input>", "private-unknown-952"),
            ("<textarea name='passport'></textarea>", "FAKE-TEXTAREA-739"),
            ("<div contenteditable='true' aria-label='Identity document'></div>", "FAKE-EDITABLE-521"),
            ("<select autocomplete='cc-exp-year'><option value=''>Choose</option><option>2036</option></select>", "2036"),
        ]
        let controls = fields.map(\.0).joined(separator: "<br>")
        let page = "<html><head><title>Local privacy fixture</title></head><body><input type='search' aria-label='Search' value='ordinary search'><button>Refresh</button>" + controls + "</body></html>"
        let values = fields.map(\.1)
        let fill = "for (const [i, el] of [...document.querySelectorAll('input:not([type=search]), textarea, select, [contenteditable]')].entries()) { if (el.isContentEditable) el.textContent = values[i]; else el.value = values[i]; }"
        let pages = try PageServer(pages: ["/": page, "/filled": page.replacingOccurrences(of: "</body>", with: "<script>const values = \(Self.json(values)); \(fill)</script></body>")])
        let address = "http://127.0.0.1:\(pages.port)"
        let opened = await WebTools.perform("web_open", arguments: Self.json(["url": address]))
        XCTAssertFalse(opened.isError)
        let refresh = try Self.ref("Refresh", in: opened.text)
        let search = try Self.ref("Search", in: opened.text)
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("web_handoff", ["reason": "Enter the local test fields"]),
            FakeCompletions.tool("web_read", [:]),
            FakeCompletions.tool("web_click", ["ref": refresh]),
            FakeCompletions.tool("web_type", ["ref": search, "text": "ordinary updated search"]),
            FakeCompletions.tool("web_open", ["url": address + "/filled"]),
            FakeCompletions.text("Local privacy check finished."),
        ])
        let settings = ["chat.provider", "chat.customURL", "chat.customModel"]
        let previous = settings.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(settings, previous) { UserDefaults.standard.set(value, forKey: key) } }
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        let chat = ChatModel(app: app, kind: .handoff, requester: "Local privacy test")
        defer { chat.stop() }
        let handedOver = expectation(description: "browser handed to owner")
        withObservationTracking { _ = PokiBrowser.shared.owner } onChange: { handedOver.fulfill() }
        chat.send("Inspect the local fixture after the owner hands it back.")
        await fulfillment(of: [handedOver], timeout: 20)
        XCTAssertTrue(PokiBrowser.shared.ownerHasIt)
        _ = try await PokiBrowser.shared.webView.callAsyncJavaScript(fill, arguments: ["values": values], in: nil, contentWorld: .page)
        let finished = expectation(description: "chat finished after handback")
        withObservationTracking { _ = chat.running } onChange: { finished.fulfill() }
        PokiBrowser.shared.handBack()
        await fulfillment(of: [finished], timeout: 30)

        let calls = SessionStore.shared.record(chat.sessionID)
        XCTAssertEqual(calls.map(\.name), ["web_handoff", "web_read", "web_click", "web_type", "web_open"])
        XCTAssertTrue(calls.allSatisfy(\.ok))
        XCTAssertTrue(calls.first?.answer.contains("ordinary search") == true)
        XCTAssertTrue(calls.first?.answer.contains("(filled)") == true)
        XCTAssertTrue(calls.first?.answer.contains("one-time code") == true)
        XCTAssertTrue(calls.first?.answer.contains("payment card") == true)
        XCTAssertTrue(calls.first?.answer.contains("identity document") == true)
        XCTAssertTrue(calls.first { $0.name == "web_type" }?.answer.contains("ordinary updated search") == true)
        XCTAssertTrue(opened.text.contains("(empty)"))
        let requests = Self.json(server.requests)
        XCTAssertTrue(requests.contains("The owner handed the page back."))
        XCTAssertTrue(requests.contains("ordinary updated search"))
        let session = try XCTUnwrap(SessionStore.shared.session(chat.sessionID))
        let exported = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let stored = try String(contentsOf: support.appendingPathComponent("Poki/Sessions/\(chat.sessionID).json"), encoding: .utf8)
        XCTAssertTrue(stored.contains("web_handoff"))
        let cache = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let log = try String(contentsOf: cache.appendingPathComponent("poki-log.txt"), encoding: .utf8)
        let rawRead = try await PokiBrowser.shared.call("return window.__pokiReader.read({budget: 20000})")
        let debug = Self.json(try XCTUnwrap(rawRead))
        for (index, value) in values.enumerated() {
            for (surface, text) in [("model requests", requests), ("session export", exported), ("session file", stored),
                                    ("app log", AppLog.shared.text), ("log file", log), ("reader debug result", debug)] {
                XCTAssertFalse(text.replacingOccurrences(of: "\\/", with: "/").contains(value), "Field \(index) leaked into \(surface)")
            }
        }
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

    private static let termsNotice = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Showtimes</title></head>
    <body>
    <h1>Showtimes</h1>
    <p id="log"></p>
    <div style="position:fixed;left:0;right:0;bottom:0;background:#fff;padding:12px">
      <p>By continuing to use this site, you agree to our Terms of Use.</p>
      <button onclick="this.parentElement.style.display='none'">Continue</button>
    </div>
    <script>
    for (const b of document.querySelectorAll('button')) {
      b.addEventListener('click', () => { document.getElementById('log').textContent = 'Tapped: ' + b.textContent; });
    }
    </script>
    </body></html>
    """

    private static let agreeToTerms = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Rewards</title></head>
    <body>
    <h1>Rewards</h1>
    <p id="log"></p>
    <div role="dialog" style="position:fixed;inset:0;background:#fff;padding:24px">
      <h2>Before you go on</h2>
      <label><input type="checkbox" id="terms"> I agree to the Terms of Service and Privacy Policy</label>
      <button>Continue</button>
    </div>
    <script>
    for (const b of document.querySelectorAll('button')) {
      b.addEventListener('click', () => { document.getElementById('log').textContent = 'Tapped: ' + b.textContent; });
    }
    </script>
    </body></html>
    """

    private static func ref(_ label: String, in text: String) throws -> String {
        let pattern = "\\[(e\\d+)\\] (?:button|link|textbox|searchbox) \"" + NSRegularExpression.escapedPattern(for: label) + "\""
        let match = try XCTUnwrap(try NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                  "“\(label)” is on the page read: \(text)")
        return String(text[Range(match.range(at: 1), in: text)!])
    }

    private static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// HTML pages on 127.0.0.1 by path; any other path is not found.
private final class PageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "page-server")
    private let pages: [String: String]

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(pages: [String: String]) throws {
        self.pages = pages
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
                let path = String(decoding: received.prefix(64), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = self.pages[path] ?? ""
                let status = self.pages[path] == nil ? "404 Not Found" : "200 OK"
                let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                return connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            if done || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }
}
