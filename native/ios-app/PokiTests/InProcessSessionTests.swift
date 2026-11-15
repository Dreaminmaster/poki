import Foundation
import PokiCore
import XCTest
@testable import Poki

/// Poki opens its own automation session before an agent needs it (ESP-152). When that fails (the
/// owner cancelled the passcode, testmanagerd did not answer within 3 s), an agent's call hears why at
/// once and asks for another try, instead of every call waiting out "opening the session".
final class InProcessSessionTests: XCTestCase {
    func testWorkspaceLauncherIgnoresDuplicateSystemEntriesAndTheMatchingWidgetLabel() {
        let icon = NSValue(cgRect: CGRect(x: 100, y: 250, width: 86, height: 86))
        let offPage = NSValue(cgRect: CGRect(x: 490, y: 720, width: 160, height: 162))
        let title = NSValue(cgPoint: CGPoint(x: 587, y: 323))
        let widget = NSValue(cgPoint: CGPoint(x: 120, y: 550))
        let point = PKWorkspaceLauncherPoint(["备忘录": [offPage, icon, icon]], ["备忘录": [widget, title]], false)
        XCTAssertEqual(point, CGPoint(x: 587, y: 287))
    }

    func testWorkspaceLauncherRefusesTwoVisibleIconsWithTheSameName() {
        let icon = NSValue(cgRect: CGRect(x: 100, y: 250, width: 86, height: 86))
        let labels = [NSValue(cgPoint: CGPoint(x: 587, y: 323)), NSValue(cgPoint: CGPoint(x: 690, y: 323))]
        XCTAssertTrue(PKWorkspaceLauncherPoint(["备忘录": [icon]], ["备忘录": labels], false).x.isNaN)
    }

    func testAFailedOpenIsAnsweredWithItsReasonAndTheCallTriesAgain() {
        let host = AppCoreHost()
        let tries = Tries()
        host.onRetry { tries.add() }
        host.update(runner: InProcessSession.failed(code: "session_timeout", detail: "").agentState)

        let state = host.runnerState()

        guard case .failed(let detail, let fix) = state else { return XCTFail("the agent reads \(state.describe)") }
        XCTAssertTrue(detail.contains("session_timeout"), detail)
        XCTAssertNotNil(fix)
        XCTAssertEqual(tries.count, 1, "the call asks Poki to open the session again")
    }

    /// Seen on the phone: the banner up and the session open, while every look answered "still
    /// starting", because nothing asked for another open. A call that finds it opening asks too.
    func testACallThatFindsTheSessionStillOpeningAsksForAnOpen() {
        let host = AppCoreHost()
        let tries = Tries()
        host.onRetry { tries.add() }
        host.update(runner: InProcessSession.opening.agentState)

        let state = host.runnerState()

        guard case .starting = state else { return XCTFail("the agent reads \(state.describe)") }
        XCTAssertEqual(tries.count, 1, "the call asks Poki to open the session")
    }
}

private final class Tries: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
