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

    /// One step count on every presentation of the Live Activity (the inventory of state machines,
    /// item 2): with a plan from the chat's model, the compact island, the line above the title and
    /// the row of segments all say the plan's step, however many actions lie under it; without a
    /// plan they all count actions, and no total is made up.
    func testEveryPresentationShowsTheSameStep() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.stepCount = 7
        state.plan = .init(total: 5, current: 2)
        var face = state.face
        XCTAssertEqual(face.kicker, "Step 2 of 5")
        XCTAssertEqual(face.compact, .steps(verb: "Tap", count: "2/5"))
        XCTAssertEqual(face.bottom, .progress(step: 2, total: 5, stop: true))

        state.plan = nil
        face = state.face
        XCTAssertEqual(face.kicker, "Step 8")
        XCTAssertEqual(face.compact, .steps(verb: "Tap", count: "Step 8"))
        XCTAssertEqual(face.bottom, .progress(step: 8, total: nil, stop: true))
    }
}
