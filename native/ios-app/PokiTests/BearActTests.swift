import XCTest
@testable import Poki

/// The bear's acts for Poki's states: done and gone wrong were flat pictures over the bear.
final class BearActTests: XCTestCase {
    /// Done and gone wrong are played by the bear itself, as ready and at work were.
    func testDoneAndFailedArePlayedByTheBear() {
        XCTAssertEqual(PokiMood.done.act, .done)
        XCTAssertEqual(PokiMood.tripped.act, .failed)
        for mood in [PokiMood.ready, .thinking, .onYourPhone, .checking, .done, .tripped] { XCTAssertTrue(mood.modelled, "\(mood)") }
    }

    /// A reaction comes in, holds, and leaves the bear standing as it found it, in a few seconds.
    func testAReactionPlaysOnceAndEnds() throws {
        for act in [BearAct.done, .failed] {
            let reaction = try XCTUnwrap(BearReaction(act, at: 10))
            XCTAssertEqual(reaction.weight(at: 10), 0)
            XCTAssertEqual(reaction.weight(at: 10 + BearReaction.rise + 0.2), 1)
            XCTAssertLessThan(reaction.length, 3)
            let after = reaction.pose(at: reaction.end)
            XCTAssertEqual(after.headPitch, 0); XCTAssertEqual(after.arms, 0); XCTAssertEqual(after.smile, 0)
            XCTAssertEqual(reaction.face(at: reaction.end).mouth, 0)
        }
        XCTAssertNil(BearReaction(.ready, at: 0))
    }
}
