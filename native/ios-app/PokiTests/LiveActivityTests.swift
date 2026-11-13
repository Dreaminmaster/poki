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
        chat.update { $0.plan = .init(steps: ["Open Notes", "Write the list"], current: 1) }
        chat.update { $0.phase = .working; $0.caller = nil; $0.headline = "Open Notes" }
        XCTAssertEqual(chat.state.plan, .init(steps: ["Open Notes", "Write the list"], current: 1))

        // The next chat task, while the last run still shows as finished.
        chat.finishNow(alert: false)
        XCTAssertEqual(chat.state.phase, .done)
        chat.update { $0.plan = nil }
        chat.update { $0.plan = .init(steps: ["Open Clock", "Open Alarms", "Add an alarm"], current: 1) }
        chat.update { $0.phase = .working; $0.headline = "Open Clock" }
        XCTAssertEqual(chat.state.plan, .init(steps: ["Open Clock", "Open Alarms", "Add an alarm"], current: 1))

        let agent = ActivityController()
        agent.update { $0.plan = .init(steps: ["Open Notes", "Write the list"], current: 2); $0.phase = .working; $0.caller = nil }
        agent.finishNow(alert: false)
        agent.update { $0.phase = .working; $0.caller = "Claude Code"; $0.headline = "Open Notes" }
        XCTAssertNil(agent.state.plan)
    }

    func testANewRunDoesNotKeepTheLastRunsApp() {
        let controller = ActivityController()
        controller.update { $0.phase = .working; $0.headline = "Open Notes" }
        controller.update { $0.app = "Notes" }
        controller.update { $0.phase = .done }
        controller.update { $0.phase = .working; $0.headline = "Open WeChat" }
        XCTAssertNil(controller.state.app)
        controller.update { $0.app = "WeChat" }
        XCTAssertEqual(controller.state.app, "WeChat")
    }

    /// No presentation of the Live Activity counts a run's steps: an agent changes its count as it
    /// goes, so "2/5", "Step 8" and "12 steps" read as broken promises. The line over the title names
    /// the app, the compact island shows the app or the time, the line under the title has no
    /// segments, and a finished run says where and how long, with or without a plan.
    func testNoPresentationCountsTheRunsSteps() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.app = "Messages"
        state.since = start
        state.stepCount = 7
        state.plan = .init(steps: ["Open Messages", "Open the chat", "Write it", "Check it", "Send it"], current: 2)
        for plan in [state.plan, nil] {
            state.plan = plan
            let face = state.face
            XCTAssertEqual(face.kicker, "Messages")
            XCTAssertEqual(face.compact, ActivityFace.workingTrailing == .icon ? .app("Messages", since: start) : .elapsed(start))
            XCTAssertEqual(face.bottom, .progress(line: true, stop: true))
        }

        state.phase = .done
        state.endedAt = start.addingTimeInterval(84)
        state.plan = .init(steps: ["Open Messages", "Send it"], current: 2, title: "Text Mom")
        XCTAssertEqual(state.face.content, "Text Mom")
        XCTAssertEqual(state.face.subtitle, "Done in Messages, took 1:24")
    }

    /// ESP-467: the island and the Lock Screen say what the task is doing, never the single tap under
    /// it. With the chat's plan, the step under way in the plan's words; without a plan, a line of
    /// Poki's own. The compact island never shows a tap either.
    func testTheIslandSaysThePlansStepNotTheTap() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.stepCount = 3
        state.plan = .init(steps: ["Open the chat with Mom", "Send “On my way”"], current: 2, title: "Text Mom", to: "Mom")
        var face = state.face
        XCTAssertEqual(face.content, "Send “On my way”")
        XCTAssertFalse(face.compact.says("Tap"))

        // An outside agent's run has no plan: no tap on any presentation.
        state.plan = nil
        state.caller = "Claude Code"
        face = state.face
        XCTAssertEqual(face.content, StatusWord.running.text)
        XCTAssertFalse(face.compact.says("Tap"))
    }

    /// The compact island's right side names where the run is without words: the icon of the app it
    /// is in, and the run's time while that app is not known. Before the run reaches an app there is
    /// no line under the title yet (the runner waking).
    func testTheCompactIslandShowsTheAppOrTheTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = PokiState(phase: .working, headline: "Open WeChat", thumbnailVersion: 0)
        state.since = start
        XCTAssertEqual(state.face.compact, .elapsed(start))
        XCTAssertEqual(state.face.bottom, .progress(line: false, stop: true))

        state.app = "WeChat"
        XCTAssertEqual(state.face.compact, ActivityFace.workingTrailing == .icon ? .app("WeChat", since: start) : .elapsed(start))
    }

    /// ESP-467: while the runner starts, every stage says one main line (Poki waking up) and names the
    /// stage in the small line under it, instead of a new main line per stage.
    func testTheStartUpStagesShareOneLineAndNameTheStageBelow() {
        let stages = ["Connecting", "Checking pairing", "Opening tunnel", "Preparing", "Starting"]
        let faces = stages.map { PokiState(phase: .idle, headline: $0, thumbnailVersion: 0).face }
        XCTAssertEqual(Set(faces.map(\.content)).count, 1)
        XCTAssertEqual(faces.map(\.subtitle), stages.map { ActivityWords.local($0) })
    }

    /// ESP-467: when iOS folds an approval's island back, the compact island says Poki waits for your
    /// answer, beside the time left, not a bare countdown.
    func testTheFoldedIslandSaysItWaitsForYourAnswer() {
        var state = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 0)
        state.approval = PendingApproval(id: "a", app: "Messages", summary: "Tap “Send”", reason: "sending a message (\"send\")", expires: .now.addingTimeInterval(60))
        XCTAssertTrue(state.face.compact.says("Allow?"))
    }
}

private extension ActivityFace.Compact {
    /// The compact island shows this text, in whichever form it draws it.
    func says(_ text: String) -> Bool {
        let words = Mirror(reflecting: self).children.first.map { String(describing: $0.value) } ?? ""
        return words.contains(text)
    }
}
