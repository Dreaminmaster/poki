import AVFoundation
import WebRTC
import XCTest
@testable import Poki

final class VoiceLinkAudioTests: XCTestCase {
    @MainActor
    func testClosingTalkReleasesAudioAfterRejectedConfiguration() async {
        let warmup = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        await connectToUnavailableEndpoint(warmup)
        warmup.close()

        let audio = AVAudioSession.sharedInstance()
        let session = RTCAudioSession.sharedInstance()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        let category = configuration.category
        let invalidCategory = AVAudioSession.Category(rawValue: "InvalidRecordingCategory")
        XCTAssertThrowsError(try audio.setCategory(invalidCategory))
        configuration.category = invalidCategory.rawValue
        defer { configuration.category = category }

        let link = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        defer { link.close() }
        await connectToUnavailableEndpoint(link)
        XCTAssertTrue(session.isActive)
        link.close()
        XCTAssertFalse(session.isActive, "Closing the talk should release the recording session")
    }

    @MainActor
    private func connectToUnavailableEndpoint(_ link: VoiceLink) async {
        do {
            try await link.connect(secret: "test", base: URL(string: "poki-test://realtime")!)
            XCTFail("The call request should fail locally")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .unsupportedURL)
        }
    }
}
