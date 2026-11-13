import XCTest
@testable import Poki

/// The bear standing on its own: it was a still picture between blinks, and only a tap moved it.
final class BearIdleTests: XCTestCase {
    /// How far the head is turned, tilted or nodded, in radians.
    private func headTurn(_ pose: BearIdle.Pose) -> Float { max(abs(pose.headYaw), abs(pose.headPitch), abs(pose.headRoll)) }

    /// Thirty seconds without a touch, at the rate it is drawn: it breathes all along and looks
    /// somewhere more than once.
    func testTheBearMovesByItselfWhileItStands() {
        var idle = BearIdle(now: 0)
        var lifts: [Float] = [], looks = 0, looking = false
        for frame in 0..<900 {
            let pose = idle.pose(at: Double(frame) / 30)
            lifts.append(pose.bodyLift)
            let turned = headTurn(pose) > 0.1
            if turned, !looking { looks += 1 }
            looking = turned
        }
        XCTAssertGreaterThan(lifts.max()! - lifts.min()!, 0.008, "it breathes")
        XCTAssertGreaterThanOrEqual(looks, 2, "it looks about")
    }

    /// A tap while it looks away: the head comes back before the hi.
    func testAHiBringsTheHeadBackFirst() throws {
        var idle = BearIdle(now: 0)
        var t = 0.0
        while headTurn(idle.pose(at: t)) < 0.12 {
            t += 1.0 / 30
            try XCTSkipIf(t > 30, "no look in thirty seconds")
        }
        idle.attend(at: t)
        let back = idle.pose(at: t + 0.35)
        // What is left is the sway and the breath, a few hundredths of a radian.
        XCTAssertLessThan(headTurn(back), 0.06)
    }

    /// It did one thing only, a look somewhere. Now the small things take turns: each once in every
    /// four, in a new order, never the same twice in a row.
    func testTheSmallThingsTakeTurns() {
        var idle = BearIdle(now: 0)
        let done = (0..<40).map { _ in idle.nextGesture() }
        for (a, b) in zip(done, done.dropFirst()) { XCTAssertNotEqual(a, b) }
        for start in stride(from: 0, to: 40, by: 4) {
            XCTAssertEqual(Set(done[start..<start + 4]), Set(BearIdle.Gesture.allCases), "turn from \(start)")
        }
    }
}
