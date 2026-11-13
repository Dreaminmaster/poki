import XCTest
@testable import Poki

/// The bear's blink on the model's timeline: the eyes are swapped from one frame to the next (open,
/// a line, a smile), and between two frames neither shows, so the eye pads were blank and white for a
/// moment in every blink. And it was over in a quarter of a second, the closed eye's arc there at once,
/// and now and then it blinked twice.
final class BearClipsTests: XCTestCase {
    private let clips = try! BearClips(json: Data("""
    {"fps": 30, "clips": {"idle": [95, 105], "wave": [20, 94], "blink": [5, 12]}, "design_hello_frame": 42}
    """.utf8))

    /// Between two frames only where no eye is swapped: while it shuts (5 to 7) and opens (10 to 12).
    func testTheEyesAreSwappedAtWholeFramesOnly() {
        for step in 0...200 {
            let frame = clips.time(.blink, after: Double(step) / 300) * 30
            let whole = abs(frame - frame.rounded()) < 1e-6
            XCTAssertTrue(whole || (5...7).contains(frame) || (10...12).contains(frame), "frame \(frame) after \(step)/300 s")
        }
        XCTAssertEqual(clips.time(.blink, after: 1) * 30, 12, accuracy: 1e-9)
    }

    /// One pace: 0.14 s down, 0.06 s shut, 0.2 s up. Shut, the eye is a low arc out of the line the pupil
    /// has become, not the smile.
    func testTheBlinkIsFourTenthsOfASecondAndShutsToALine() throws {
        XCTAssertEqual(clips.length(.blink), 0.4, accuracy: 1e-9)
        let beforeSwap = BearBlink.at(BearBlink.closing - 0.001), shut = BearBlink.at(BearBlink.closing + 0.03)
        XCTAssertLessThan(try XCTUnwrap(beforeSwap.pupils), 0.15)
        XCTAssertLessThanOrEqual(try XCTUnwrap(shut.arcs), 0.3)
        XCTAssertEqual(BearBlink.at(BearBlink.length), BearBlink.Moment(frame: 7, pupils: 1, arcs: nil))
    }

    /// Ten minutes standing, with the head turning for a second every five: it blinks once at a time,
    /// 4 to 7 seconds apart, and never while the head turns. It used to blink twice in a row now and then.
    func testItBlinksOnceAtATimeAndNotWhileTurning() {
        var playback = BearPlayback()
        playback.play([.idle], at: 0)
        var starts: [TimeInterval] = [], last: BearMove = .idle
        for frame in 0..<(600 * 30) {
            let now = Double(frame) / 30
            let turning = now.truncatingRemainder(dividingBy: 5) < 1
            _ = playback.time(at: now, clips: clips, steady: !turning)
            if playback.move == .blink, last != .blink {
                XCTAssertFalse(turning, "a blink at \(now) s while the head turns")
                starts.append(now)
            }
            last = playback.move
        }
        XCTAssertGreaterThan(starts.count, 60)
        for (a, b) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a - BearBlink.length, 3.9, "blinks at \(a) s and \(b) s")
        }
    }
}
