import AVFoundation
import XCTest
@testable import Poki

final class DictationAudioTests: XCTestCase {
    @MainActor
    func testFinishingDictationDeactivatesTheRecordingSession() async throws {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("Audio session lifecycle notifications require iOS 27") }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant microphone access on the simulator to run this test")
        }
        let audio = AVAudioSession.sharedInstance()
        let dictation = Dictation()
        try dictation.listen()
        defer { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
        XCTAssertEqual(audio.category, .playAndRecord)

        let inactive = expectation(forNotification: AVAudioSession.didBecomeInactiveNotification, object: audio)
        _ = await dictation.finish()
        await fulfillment(of: [inactive], timeout: 2)
        #else
        throw XCTSkip("Audio session lifecycle notifications require the iOS 27 SDK")
        #endif
    }
}
