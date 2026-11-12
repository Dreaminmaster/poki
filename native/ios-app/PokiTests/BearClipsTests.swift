import XCTest
@testable import Poki

/// The bear's blink on the model's timeline: the eyes are swapped from one frame to the next (open,
/// a line, a smile), and between two frames neither shows, so the eye pads were blank and white for a
/// moment in every blink.
final class BearClipsTests: XCTestCase {
    private let clips = try! BearClips(json: Data("""
    {"fps": 30, "clips": {"idle": [95, 105], "wave": [20, 94], "blink": [5, 12]}, "design_hello_frame": 42}
    """.utf8))

    func testTheBlinkShowsWholeFramesOnly() {
        // 2.5 frames in: between the line (frame 7) and the smile (frame 8), where the eyes are gone.
        XCTAssertEqual(clips.time(.blink, after: 2.5 / 30) * 30, 7, accuracy: 1e-9)
        for step in 0...40 {
            let frame = clips.time(.blink, after: Double(step) / 160) * 30
            XCTAssertEqual(frame, frame.rounded(), accuracy: 1e-6, "after \(step)/160 s")
        }
        XCTAssertEqual(clips.time(.blink, after: 1) * 30, 12, accuracy: 1e-9)
    }
}
