import AuthenticationServices
import XCTest
@testable import Poki

@MainActor
final class ChatGPTBrowserSessionTests: XCTestCase {
    func testSignInServerReturnKeepsTheLoginRunning() {
        let signedIn = URL(string: "poki-chatgpt://signed-in")!
        let failed = URL(string: "poki-chatgpt://signed-in?error=1")!

        XCTAssertEqual(ChatGPTBrowserSession.outcome(callbackURL: signedIn, error: nil), .returned)
        // A failed exchange also returns. Its result comes from account/login/completed, not the URL.
        XCTAssertEqual(ChatGPTBrowserSession.outcome(callbackURL: failed, error: nil), .returned)
    }

    func testClosedSheetCancelsAndOtherEndingsFail() {
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        let refused = ASWebAuthenticationSessionError(.presentationContextInvalid)

        XCTAssertEqual(ChatGPTBrowserSession.outcome(callbackURL: nil, error: cancelled), .cancelled)
        XCTAssertEqual(ChatGPTBrowserSession.outcome(callbackURL: nil, error: refused), .failed)
        XCTAssertEqual(ChatGPTBrowserSession.outcome(callbackURL: URL(string: "https://example.com"), error: nil), .failed)
    }

    func testCallbackSchemeMatchesTheCodexServerPatch() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("codex-voice/build.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("\(ChatGPTBrowserSession.callbackScheme)://signed-in\".to_string()"))
        XCTAssertTrue(text.contains("url=\(ChatGPTBrowserSession.callbackScheme)://signed-in?error=1"))
    }
}
