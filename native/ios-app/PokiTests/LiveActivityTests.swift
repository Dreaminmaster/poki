import XCTest
@testable import Poki

@MainActor
final class LiveActivityTests: XCTestCase {
    /// The Live Activity counts the chat's plan from the first step on the phone (the chat publishes it
    /// before that step, while the activity is idle or still shows the last run as finished), and a
    /// finished run's plan never carries into the next run.
    func testTheChatsPlanCountsFromItsFirstStepAndEndsWithItsRun() {
        let chat = ActivityController()
        chat.update { $0.plan = nil }
        chat.update { $0.plan = .init(total: 2, current: 1) }
        chat.update { $0.phase = .working; $0.caller = nil; $0.headline = "Open Notes" }
        XCTAssertEqual(chat.state.plan, .init(total: 2, current: 1))

        // The next chat task, while the last run still shows as finished.
        chat.finishNow(alert: false)
        XCTAssertEqual(chat.state.phase, .done)
        chat.update { $0.plan = nil }
        chat.update { $0.plan = .init(total: 3, current: 1) }
        chat.update { $0.phase = .working; $0.headline = "Open Clock" }
        XCTAssertEqual(chat.state.plan, .init(total: 3, current: 1))

        let agent = ActivityController()
        agent.update { $0.plan = .init(total: 2, current: 2); $0.phase = .working; $0.caller = nil }
        agent.finishNow(alert: false)
        agent.update { $0.phase = .working; $0.caller = "Claude Code"; $0.headline = "Open Notes" }
        XCTAssertNil(agent.state.plan)
    }
}
