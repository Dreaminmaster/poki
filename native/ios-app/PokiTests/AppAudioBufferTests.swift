import XCTest
@testable import Poki

final class AppAudioBufferTests: XCTestCase {
    func testOnlyRecentAudioIsReadableAndStoppingDiscardsIt() {
        let buffer = AppAudioBuffer()
        for second in 0...60 {
            buffer.append(Data(repeating: UInt8(second), count: 32_000), at: Double(second))
        }

        let expected = (1...60).reduce(into: Data()) { pcm, second in
            pcm.append(Data(repeating: UInt8(second), count: 32_000))
        }
        XCTAssertEqual(buffer.snapshot(at: 60), expected)
        XCTAssertEqual(buffer.snapshot(at: 120), Data())

        buffer.stop()
        buffer.append(Data(repeating: 1, count: 32_000), at: 121)
        XCTAssertNil(buffer.snapshot(at: 121))
    }
}
