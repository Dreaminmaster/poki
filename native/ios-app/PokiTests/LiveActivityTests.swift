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

    /// One step count on every presentation of the Live Activity (the inventory of state machines,
    /// item 2): with a plan from the chat's model, the compact island, the line above the title and
    /// the row of segments all say the plan's step, however many actions lie under it; without a
    /// plan they all count actions, and no total is made up.
    func testEveryPresentationShowsTheSameStep() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.stepCount = 7
        state.plan = .init(steps: ["Open Messages", "Open the chat", "Write it", "Check it", "Send it"], current: 2)
        var face = state.face
        XCTAssertEqual(face.kicker, "Step 2 of 5")
        XCTAssertTrue(face.compact.counts("2/5"))
        XCTAssertEqual(face.bottom, .progress(step: 2, total: 5, stop: true))

        state.plan = nil
        face = state.face
        XCTAssertEqual(face.kicker, "Step 8")
        XCTAssertTrue(face.compact.counts("Step 8"))
        XCTAssertEqual(face.bottom, .progress(step: 8, total: nil, stop: true))
    }

    /// ESP-467: the island and the Lock Screen say what the task is doing, never the single tap under
    /// it. With the chat's plan, the step under way in the plan's words (and the one before it, ticked);
    /// without a plan, a line of Poki's own. The compact island never shows a tap either.
    func testTheIslandSaysThePlansStepNotTheTap() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.stepCount = 3
        state.previous = "Tap “Messages”"
        state.plan = .init(steps: ["Open the chat with Mom", "Send “On my way”"], current: 2, title: "Text Mom", to: "Mom")
        var face = state.face
        XCTAssertEqual(face.content, "Send “On my way”")
        XCTAssertEqual(face.previous, "Open the chat with Mom")
        XCTAssertFalse(face.compact.says("Tap"))
        XCTAssertTrue(face.compact.counts("2/2"))

        // An outside agent's run has no plan: no tap on any presentation.
        state.plan = nil
        state.caller = "Claude Code"
        face = state.face
        XCTAssertEqual(face.content, StatusWord.running.text)
        XCTAssertFalse(face.compact.says("Tap"))
        XCTAssertTrue(face.compact.counts("Step 4"))
    }

    /// ESP-467: the compact island's 52 points cut a plan's step to a few characters, so it names the app
    /// the step is in over the count ("Messages" over "2/2"), and with no app the count alone.
    func testTheCompactIslandNamesTheAppOverTheCount() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.app = "Messages"
        state.plan = .init(steps: ["Open the chat with Mom", "Send “On my way”"], current: 2, title: "Text Mom", to: "Mom")
        var face = state.face
        XCTAssertTrue(face.compact.says("Messages"))
        XCTAssertFalse(face.compact.says("On my way"))
        XCTAssertTrue(face.compact.counts("2/2"))

        state.app = nil
        face = state.face
        XCTAssertFalse(face.compact.says("Mom"))
        XCTAssertTrue(face.compact.counts("2/2"))
    }

    /// ESP-467: while the runner starts, every stage says one main line (Poki waking up) and names the
    /// stage in the small line under it, instead of a new main line per stage.
    func testTheStartUpStagesShareOneLineAndNameTheStageBelow() {
        let stages = ["Connecting", "Checking pairing", "Opening tunnel", "Preparing", "Starting"]
        let faces = stages.map { PokiState(phase: .idle, headline: $0, thumbnailVersion: 0).face }
        XCTAssertEqual(Set(faces.map(\.content)).count, 1)
        XCTAssertEqual(faces.map(\.subtitle), stages.map { ActivityWords.local($0) })
    }

    /// A batch the rules saw as a payment and a deletion (a cart's Clear, then Check out) names both
    /// wherever it is asked, also when the agent wrote no sentence: in the rules' sentence, the
    /// notification's line, the alert and the tags.
    func testABatchOfTwoKindsNamesBoth() {
        let approval = PendingApproval(id: "a", app: "Lunch", summary: "Tap “Clear”, then tap “Check out”",
                                       reason: "multiple sensitive actions: action 1: deleting (\"clear\"); action 2: a payment (\"check out\")",
                                       expires: .distantFuture, ask: "In Lunch, pay and delete something", kinds: ["payment", "deleting"])
        XCTAssertEqual(approval.sentence, "In Lunch, about to pay and delete something")
        XCTAssertEqual(approval.kindLine, "Payment and Deletion")
        XCTAssertEqual(approval.alertLine, "Payment and Deletion: In Lunch, about to pay and delete something")
        XCTAssertEqual(approval.tags.map(\.word), ["Payment", "Deletion"])
    }

    /// An agent can word a payment as nothing to approve. On the island and the Lock Screen the rules'
    /// kind stands over its sentence as a tag in the warning colour, and the sentence is only the
    /// title, never in the kind's place.
    func testTheRulesKindStandsOverTheAgentsSentence() {
        var state = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 0)
        state.approval = PendingApproval(id: "a", app: "Lunch", summary: "Tap “Pay”", reason: "a payment (\"pay\")",
                                         expires: .now.addingTimeInterval(60), ask: "Payment cancelled, nothing to approve",
                                         byAgent: true, kinds: ["payment"])
        let face = state.face
        XCTAssertEqual(face.tags, [ApprovalTag(word: "Payment", warning: true)])
        XCTAssertEqual(face.content, "Payment cancelled, nothing to approve")
        XCTAssertNil(face.subtitle)
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
    func counts(_ count: String) -> Bool { says(count) }
}
