import AVFoundation
import XCTest
@testable import Poki

final class DictationAudioTests: XCTestCase {
    @MainActor
    func testFinishingDictationDeactivatesTheRecordingSession() async throws {
        #if targetEnvironment(simulator)
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant microphone access on the simulator to run this test")
        }
        let audio = AVAudioSession.sharedInstance()
        // The simulator can change the active state without posting lifecycle notifications.
        guard audio.responds(to: NSSelectorFromString("isActive")) else {
            throw XCTSkip("The simulator does not expose the active audio session state")
        }
        let dictation = Dictation()
        try dictation.listen()
        defer { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
        XCTAssertEqual(audio.category, .playAndRecord)
        XCTAssertEqual(audio.value(forKey: "active") as? Bool, true)

        _ = await dictation.finish()
        XCTAssertEqual(audio.value(forKey: "active") as? Bool, false)
        #else
        throw XCTSkip("The audio session state probe is simulator-only")
        #endif
    }
}
