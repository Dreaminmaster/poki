import AVFoundation
import WebRTC
import XCTest
@testable import Poki

final class OpeningVoiceAudioTests: XCTestCase {
    private final class DelegateProbe: NSObject, RTCAudioDeviceDelegate {
        let preferredInputSampleRate = 48_000.0
        let preferredOutputSampleRate = 48_000.0
        let preferredInputIOBufferDuration = 0.01
        let preferredOutputIOBufferDuration = 0.01
        private(set) var sent: [Int16] = []

        var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
            { [weak self] _, _, _, count, buffer, _, _ in
                if let data = buffer?.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    self?.sent.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(count)))
                }
                return noErr
            }
        }
        var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
            { _, _, _, _, _ in noErr }
        }
        func notifyAudioInputParametersChange() {}
        func notifyAudioOutputParametersChange() {}
        func notifyAudioInputInterrupted() {}
        func notifyAudioOutputInterrupted() {}
        func dispatchAsync(_ block: @escaping () -> Void) { block() }
        func dispatchSync(_ block: @escaping () -> Void) { block() }
    }

    private func makeFourChannelFloatBuffer(
        sampleRate: Double,
        frames: AVAudioFrameCount,
        layoutTag: AudioChannelLayoutTag,
        channelValues: [Float]
    ) throws -> AVAudioPCMBuffer {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for ch in 0..<4 {
            let value = ch < channelValues.count ? channelValues[ch] : 0
            for frame in 0..<Int(frames) {
                channels[ch][frame] = value
            }
        }
        return buffer
    }

    func testFourChannelDiscreteFloatBufferConvertsToNonZeroMonoPCM16AndDeliversToWebRTC() throws {
        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())

        let opening = try makeFourChannelFloatBuffer(
            sampleRate: 48_000,
            frames: 480,
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4,
            channelValues: [0.25, 0.25, 0.25, 0.25]
        )
        XCTAssertTrue(audio.ingestCapturedBuffer(opening, at: AVAudioTime(sampleTime: 0, atRate: 48_000)))
        XCTAssertEqual(audio.bufferedFrameCount, 480)

        XCTAssertTrue(audio.allowSending(session: 1))
        let liveChannel2Only = try makeFourChannelFloatBuffer(
            sampleRate: 48_000,
            frames: 480,
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4,
            channelValues: [0.0, 0.0, 0.4, 0.0]
        )
        XCTAssertTrue(audio.ingestCapturedBuffer(liveChannel2Only, at: AVAudioTime(sampleTime: 480, atRate: 48_000)))

        XCTAssertEqual(probe.sent.count, 960)
        let openingPeak = probe.sent.prefix(480).map { abs(Int($0)) }.max() ?? 0
        let livePeak = probe.sent.suffix(480).map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(openingPeak, 4_000, "4-channel DiscreteInOrder Float32 opening audio must not convert to all-zero Int16 samples")
        XCTAssertGreaterThan(livePeak, 1_500, "4-channel audio with speech on a non-zero channel must be downmixed instead of dropped")
    }

    func testFourChannelUnknownLayoutAt44100HzResamplesToNonZero48kHzMonoPCM16() throws {
        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())
        XCTAssertTrue(audio.allowSending(session: 1))

        let buffer = try makeFourChannelFloatBuffer(
            sampleRate: 44_100,
            frames: 441,
            layoutTag: kAudioChannelLayoutTag_Unknown | 4,
            channelValues: [0.3, 0.1, 0.2, 0.2]
        )
        XCTAssertTrue(audio.ingestCapturedBuffer(buffer, at: AVAudioTime(sampleTime: 0, atRate: 44_100)))

        XCTAssertGreaterThan(probe.sent.count, 400)
        let peak = probe.sent.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 2_000, "4-channel Unknown layout at 44.1 kHz must resample to non-zero 48 kHz mono Int16")
    }

    @MainActor
    func testUnconvertibleOrEmptyBufferLogsErrorAndDoesNotEmitZeroSamples() throws {
        let priorLogs = Set(AppLog.shared.lines)
        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())
        XCTAssertTrue(audio.allowSending(session: 1))

        var invalidASBD = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let invalidFormat = try XCTUnwrap(AVAudioFormat(streamDescription: &invalidASBD))
        let invalidBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: invalidFormat, frameCapacity: 480))
        invalidBuffer.frameLength = 480

        XCTAssertFalse(audio.ingestCapturedBuffer(invalidBuffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000)))
        XCTAssertEqual(audio.bufferedFrameCount, 0)
        XCTAssertTrue(probe.sent.isEmpty, "Invalid audio formats must never emit silent zero buffers")

        let newLogs = AppLog.shared.lines.filter { !priorLogs.contains($0) }
        XCTAssertTrue(
            newLogs.contains { $0.contains("opening audio") && ($0.contains("error") || $0.contains("failed") || $0.contains("invalid")) },
            "Conversion failure must be logged explicitly instead of swallowed silently; got \(newLogs)"
        )
    }
}
