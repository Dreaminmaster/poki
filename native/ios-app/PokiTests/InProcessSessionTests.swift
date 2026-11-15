import Foundation
import PokiCore
import XCTest
@testable import Poki

/// Poki opens its own automation session when a call needs it (ESP-152). The call that waited on an
/// open that failed hears why and ends; the next call asks for a new open and waits for it, instead
/// of hearing the old failure again while an open nobody waits for starts behind it.
final class InProcessSessionTests: XCTestCase {
    func testACallThatBeginsOnAFailedOpenAsksForANewOneAndWaits() {
        let host = AppCoreHost()
        let tries = Tries()
        host.onRetry { tries.add() }
        host.update(runner: InProcessSession.failed(code: "session_timeout", detail: "").agentState)

        let state = host.runnerState()

        guard case .starting = state else { return XCTFail("the agent reads \(state.describe)") }
        XCTAssertEqual(tries.count, 1, "the call asks Poki to open the session again")
        let noRetry = AppCoreHost()
        noRetry.update(runner: InProcessSession.failed(code: "session_timeout", detail: "").agentState)
        guard case .failed(let detail, let fix) = noRetry.runnerState() else { return XCTFail("without a retry the failure is answered as it is") }
        XCTAssertTrue(detail.contains("session_timeout"), detail)
        XCTAssertNotNil(fix)
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
