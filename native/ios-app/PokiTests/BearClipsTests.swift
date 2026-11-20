import XCTest
@testable import Poki

/// The bear's blink on the model's timeline: brisk asymmetric close/open, whole-frame swaps between
/// pupils and closed arcs (never flashing blank eye pads), randomized intervals, and occasional
/// natural double-blinks.
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

    /// Asymmetric organic blink: closes briskly, opens more gently, shuts to a flat line, and returns open.
    func testTheBlinkIsAsymmetricAndShutsToALine() throws {
        XCTAssertLessThan(BearBlink.closing, BearBlink.opening)
        XCTAssertEqual(clips.length(.blink), BearBlink.length, accuracy: 1e-9)
        let beforeSwap = BearBlink.at(BearBlink.closing - 0.001), shut = BearBlink.at(BearBlink.closing + 0.015)
        XCTAssertLessThan(try XCTUnwrap(beforeSwap.pupils), 0.15)
        XCTAssertLessThanOrEqual(try XCTUnwrap(shut.arcs), 0.3)
        let end = BearBlink.at(BearBlink.length)
        XCTAssertEqual(end.frame, 7, accuracy: 1e-9)
        XCTAssertEqual(end.pupils, 1)
        XCTAssertNil(end.arcs)
    }

    /// Ten minutes standing, with the head turning for a second every five: blinks occur at randomized
    /// gaps with occasional double-blinks, and regular single blinks wait while the head turns.
    func testItBlinksAtRandomIntervalsWithOccasionalDoubleBlinks() {
        var playback = BearPlayback()
        playback.play([.idle], at: 0)
        var starts: [TimeInterval] = [], last: BearMove = .idle
        for frame in 0..<(600 * 30) {
            let now = Double(frame) / 30
            let turning = now.truncatingRemainder(dividingBy: 5) < 1
            let wasFollowUp = playback.blinkCycle == .pendingFollowUp
            _ = playback.time(at: now, clips: clips, steady: !turning)
            if playback.move == .blink, last != .blink {
                if !wasFollowUp {
                    XCTAssertFalse(turning, "a regular blink at \(now) s while the head turns")
                }
                starts.append(now)
            }
            last = playback.move
        }
        XCTAssertGreaterThan(starts.count, 50)
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 - BearBlink.length }
        let doubleBlinks = gaps.filter { $0 < 0.30 }
        let normalBlinks = gaps.filter { $0 >= 1.9 }
        XCTAssertGreaterThanOrEqual(doubleBlinks.count, 3, "expected occasional natural double blinks")
        XCTAssertGreaterThan(normalBlinks.count, 45, "expected randomized single-blink gaps")
    }

    /// The bear blinks as fast and as often as it did before the idle life was added: 0.14 s down, 0.06 s
    /// shut and 0.2 s up (0.4 s in all), and one blink every 5.9 s on average (4 to 7 s of open eyes
    /// plus the blink), double blinks included. Over 20000 s, 3400 blinks, the mean is within 0.3 s of that.
    func testTheBlinkKeepsTheSpeedAndTheRateItAlwaysHad() {
        XCTAssertEqual(BearBlink.closing, 0.14, accuracy: 1e-9)
        XCTAssertEqual(BearBlink.shut, 0.06, accuracy: 1e-9)
        XCTAssertEqual(BearBlink.opening, 0.2, accuracy: 1e-9)
        XCTAssertEqual(clips.length(.blink), 0.4, accuracy: 1e-9)
        var playback = BearPlayback()
        playback.play([.idle], at: 0)
        var starts: [TimeInterval] = [], last: BearMove = .idle
        for frame in 0..<(20_000 * 60) {
            _ = playback.time(at: Double(frame) / 60, clips: clips)
            if playback.move == .blink, last != .blink { starts.append(Double(frame) / 60) }
            last = playback.move
        }
        let mean = (starts.last! - starts.first!) / Double(starts.count - 1)
        XCTAssertEqual(mean, 5.9, accuracy: 0.3, "mean time from one blink's start to the next")
    }
}
