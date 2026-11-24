import AVFoundation
import WebRTC
import XCTest
@testable import Poki

final class VoiceLinkAudioTests: XCTestCase {
    @MainActor
    func testClosingTalkReleasesAudioAfterRejectedConfiguration() async {
        // Warm up one-time WebRTC audio defaults first so injecting an invalid category exercises
        // the fallback branch reliably even when this test runs alone.
        let warmup = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        await connectToUnavailableEndpoint(warmup)
        warmup.close()

        let priorLogs = Set(AppLog.shared.lines)
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
        XCTAssertEqual(audio.category, .playAndRecord)
        XCTAssertEqual(audio.mode, .voiceChat)
        let fallbackLogs = AppLog.shared.lines.filter {
            !priorLogs.contains($0) && $0.contains("RTCAudioSession configuration fallback:")
        }
        XCTAssertFalse(fallbackLogs.isEmpty, "Rejected WebRTC configuration must enter and log the fallback branch")
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
        let first = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        let capture = try XCTUnwrap(try first.startOpeningCapture(session: 1))
        defer {
            first.close()
            _ = capture.audio.stopCapture(session: 1)
        }
        XCTAssertTrue(session.isActive, "Starting opening capture must activate RTCAudioSession")

        await connectToUnavailableEndpoint(first)
        XCTAssertTrue(session.isActive)
        first.close()
        XCTAssertTrue(session.isActive, "Closing the first failed attempt must keep opening capture's audio session active for retry")

        let second = VoiceLink(onEvent: { _ in }, onClosed: { _ in })
        second.useOpeningCapture(capture)
        defer { second.close() }
        await connectToUnavailableEndpoint(second)
        XCTAssertTrue(session.isActive)
        second.close()
        XCTAssertTrue(session.isActive, "Closing the failed retry must keep opening capture's audio session active until capture releases")

        _ = capture.audio.stopCapture(session: 1)
        XCTAssertFalse(session.isActive, "Stopping opening capture must release the final RTCAudioSession activation")
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
