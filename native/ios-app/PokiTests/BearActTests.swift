import XCTest
import RealityKit
@testable import Poki

/// The bear's acts for Poki's states: every state was a flat picture over the bear but ready and at work.
final class BearActTests: XCTestCase {
    /// Every state is played by the bear itself, each with its own stance.
    func testEveryStateIsPlayedByTheBear() {
        for mood in PokiMood.allCases { XCTAssertTrue(mood.modelled, "\(mood)") }
        XCTAssertEqual(PokiMood.done.act, .done)
        XCTAssertEqual(PokiMood.tripped.act, .failed)
        let held: [BearAct] = [.thinking, .working, .asking, .waiting, .paused, .lost, .listening, .speaking, .hello]
        for act in held { XCTAssertNotEqual(BearStance.pose(act), BearIdle.Pose(), "\(act)") }
    }

    func testEachMouthExpressionFollowsItsState() throws {
        let stances: [(BearAct, BearFace?)] = [
            (.ready, nil), (.thinking, .think), (.working, nil), (.asking, .ask), (.waiting, nil),
            (.paused, .sleep), (.lost, nil), (.listening, nil), (.speaking, nil), (.hello, .surprise),
        ]
        for (act, face) in stances {
            let pose = BearStance.pose(act)
            for other in BearFace.allCases { XCTAssertEqual(pose[other], other == face ? 1 : 0, "\(act) \(other)") }
        }
        let reactions: [(BearAct, BearFace?)] = [(.done, nil), (.failed, .sad)]
        for (act, face) in reactions {
            let pose = try XCTUnwrap(BearReaction(act, at: 0)).pose(at: BearReaction.rise + 0.2)
            for other in BearFace.allCases { XCTAssertEqual(pose[other], other == face ? 1 : 0, "\(act) \(other)") }
        }
    }

    func testDoneAndAsleepKeepTheAuthoredEyeArcs() throws {
        let rig = try XCTUnwrap(BearIdleJoints(names: ["Body", "Head", "Eye_R", "Eye_L", "SmileEye_R", "SmileEye_L"]))
        let done = try XCTUnwrap(BearReaction(.done, at: 0)).pose(at: BearReaction.rise + 0.2)
        let asleep = BearStance.pose(.paused)
        let padDepth: Float = 0.31
        let pupil = Transform(translation: [0, 0, 0.42])
        let hiddenArc = Transform(scale: [1, 0, 1], translation: [0, 0, 0.20])
        for (state, pose) in [("done", done), ("asleep", asleep)] {
            var eyes = [Transform(), Transform(), pupil, pupil, hiddenArc, hiddenArc]
            rig.apply(pose, to: &eyes)
            for (pupil, arc) in zip(eyes[2...3], eyes[4...5]) {
                XCTAssertLessThan(pupil.translation.z, padDepth, "\(state) must hide the pupil behind the eye pad")
                XCTAssertGreaterThan(arc.translation.z, padDepth, "\(state) must bring the arc in front of the eye pad")
                XCTAssertGreaterThan(arc.scale.y, 0.1, "\(state) must open up the arc")
            }
        }
    }

    /// A reaction comes in, holds, and leaves the bear standing as it found it, in a few seconds.
    func testAReactionPlaysOnceAndEnds() throws {
        for act in [BearAct.done, .failed] {
            let reaction = try XCTUnwrap(BearReaction(act, at: 10))
            XCTAssertEqual(reaction.weight(at: 10), 0)
            XCTAssertEqual(reaction.weight(at: 10 + BearReaction.rise + 0.2), 1)
            XCTAssertLessThan(reaction.length, 3)
            XCTAssertEqual(reaction.pose(at: reaction.end), BearIdle.Pose())
        }
        XCTAssertNil(BearReaction(.ready, at: 0))
        XCTAssertNil(BearReaction(.thinking, at: 0))
    }

    /// A change of state goes from wherever the bear is to the new stance without a jump, also when the
    /// state changes again on the way.
    func testAChangeOfStanceNeverJumps() {
        var change = BearStanceChange(.ready, at: 0)
        XCTAssertEqual(change.pose(at: 1), BearIdle.Pose())
        change.go(to: .thinking, at: 1)
        XCTAssertEqual(change.pose(at: 1), BearIdle.Pose())
        let midway = change.pose(at: 1.2)
        change.go(to: .working, at: 1.2)
        let after = change.pose(at: 1.2)
        XCTAssertEqual(after.headPitch, midway.headPitch, accuracy: 1e-5)
        XCTAssertEqual(after.raise, midway.raise, accuracy: 1e-5)
        XCTAssertEqual(after.work, midway.work, accuracy: 1e-5)
        XCTAssertEqual(change.pose(at: 1.2 + BearStanceChange.length).work, 1, accuracy: 1e-5)
        XCTAssertEqual(change.pose(at: 1.2 + BearStanceChange.length).raise, 0, accuracy: 1e-5)
    }
}
