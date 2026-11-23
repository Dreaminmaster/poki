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
    func testOpeningCaptureConnectionActivatesWebRTCAudioSessionAndReleasesOnClose() async {
        let session = RTCAudioSession.sharedInstance()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        let capture = OpeningVoiceCapture(audio: audio)
        let link = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        link.useOpeningCapture(capture)
        defer { link.close() }

        await connectToUnavailableEndpoint(link)
        XCTAssertTrue(session.isActive, "VoiceLink with openingCapture must activate RTCAudioSession instead of leaving webrtc active false")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .voiceChat)

        link.close()
        XCTAssertFalse(session.isActive, "Closing VoiceLink must release its balanced RTCAudioSession activation")
    }

    @MainActor
    func testOpeningCaptureRetryKeepsAudioSessionActiveUntilCaptureReleases() async throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            session.unlockForConfiguration()
            throw error
        }
        session.unlockForConfiguration()
        defer {
            session.lockForConfiguration()
            try? session.setActive(false)
            session.unlockForConfiguration()
        }

        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        let capture = OpeningVoiceCapture(audio: audio)
        let first = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        first.useOpeningCapture(capture)
        defer { first.close() }

        await connectToUnavailableEndpoint(first)
        XCTAssertTrue(session.isActive)
        first.close()
        XCTAssertTrue(session.isActive, "Closing the first failed attempt during retry or dictation fallback must keep opening capture's audio session active")
    }

    @MainActor
    func testOpeningCaptureConnectionSurvivesRejectedWebRTCConfiguration() async {
        let audioSession = AVAudioSession.sharedInstance()
        let rtcSession = RTCAudioSession.sharedInstance()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        let savedCategory = configuration.category
        let invalidCategory = AVAudioSession.Category(rawValue: "InvalidOpeningCategory")
        XCTAssertThrowsError(try audioSession.setCategory(invalidCategory))
        configuration.category = invalidCategory.rawValue
        defer { configuration.category = savedCategory }

        let capture = OpeningVoiceCapture(audio: OpeningVoiceAudio(session: 1, playReadyChime: false))
        let link = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        link.useOpeningCapture(capture)
        defer { link.close() }

        await connectToUnavailableEndpoint(link)
        XCTAssertTrue(rtcSession.isActive, "Fallback audio configuration must still activate RTCAudioSession with openingCapture")
        link.close()
        XCTAssertFalse(rtcSession.isActive, "Closing VoiceLink must deactivate RTCAudioSession after fallback")
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
