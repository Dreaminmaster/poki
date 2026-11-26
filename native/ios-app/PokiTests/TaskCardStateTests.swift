import XCTest
@testable import Poki

/// The task card reads how the whole task ended, not one step on the way: Poki ran a skill named
/// “打开微信” that was not there, then opened WeChat itself, and the card said 微信，未完成 with a cross.
@MainActor
final class TaskCardStateTests: XCTestCase {
    private let skillThenLaunch = [PlanStep("Run “打开微信”", state: .failed), PlanStep("Open 微信", state: .done)]

    func testAStepDoneAnotherWayDoesNotFailTheTask() {
        XCTAssertTrue(PlanStep.recovered(skillThenLaunch, at: 0))
        XCTAssertFalse(PlanStep.recovered(skillThenLaunch, at: 1))
        XCTAssertEqual(TaskCardState(steps: skillThenLaunch, live: false, waiting: false, handedOver: false), .done)
    }

    func testTheModelsVerdictDecides() {
        XCTAssertEqual(TaskCardState(steps: skillThenLaunch, live: false, waiting: false, handedOver: false, succeeded: true), .done)
        let tripped = [PlanStep("Open 微信", state: .done), PlanStep("Tap “Send”", state: .failed)]
        XCTAssertEqual(TaskCardState(steps: tripped, live: false, waiting: false, handedOver: false, succeeded: true), .done)
        XCTAssertEqual(TaskCardState(steps: skillThenLaunch, live: false, waiting: false, handedOver: false, succeeded: false), .failed)
    }

    func testTheLastFailureStillFailsWithoutAVerdict() {
        let tripped = [PlanStep("Open 微信", state: .done), PlanStep("Tap “Send”", state: .failed)]
        XCTAssertFalse(PlanStep.recovered(tripped, at: 1))
        XCTAssertEqual(TaskCardState(steps: tripped, live: false, waiting: false, handedOver: false), .failed)
    }

    func testStoppedAndLiveTasksKeepTheirState() {
        XCTAssertEqual(TaskCardState(steps: skillThenLaunch, live: false, waiting: false, handedOver: false, stopped: true, succeeded: true), .stopped)
        XCTAssertEqual(TaskCardState(steps: skillThenLaunch, live: true, waiting: false, handedOver: false, succeeded: false), .running)
    }

    func testTheVerdictIsSavedWithTheConversation() throws {
        var plan = ChatEntry(.plan(skillThenLaunch))
        plan.succeeded = true
        let restored = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored.succeeded, true)
        let old = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(ChatEntry(.plan([]))))
        XCTAssertNil(old.succeeded)
    }
}
