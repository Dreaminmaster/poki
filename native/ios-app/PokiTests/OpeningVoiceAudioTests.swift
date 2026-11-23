import AudioToolbox
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
        private(set) var chunkCounts: [Int] = []
        private(set) var deliveredSampleTimes: [Double] = []
        var deliveryStatus: OSStatus = noErr
        var playoutSamples: [Int16] = []
        var playoutStatus: OSStatus = noErr
        var playoutSilent = false

        var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
            { [weak self] _, timestamp, _, count, buffer, _, _ in
                guard let self else { return noErr }
                self.chunkCounts.append(Int(count))
                self.deliveredSampleTimes.append(timestamp.pointee.mSampleTime)
                if let data = buffer?.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    self.sent.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(count)))
                }
                return self.deliveryStatus
            }
        }
        var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
            { [weak self] flags, _, _, count, buffer in
                guard let self else { return noErr }
                if self.playoutStatus != noErr { return self.playoutStatus }
                if self.playoutSilent {
                    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                    return noErr
                }
                if let destination = buffer.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    let n = min(Int(count), self.playoutSamples.count)
                    for i in 0..<n { destination[i] = self.playoutSamples[i] }
                    if n < Int(count) {
                        destination.advanced(by: n).update(repeating: 0, count: Int(count) - n)
                    }
                }
                return noErr
            }
        }
        func notifyAudioInputParametersChange() {}
        func notifyAudioOutputParametersChange() {}
        func notifyAudioInputInterrupted() {}
        func notifyAudioOutputInterrupted() {}
        func dispatchAsync(_ block: @escaping () -> Void) { block() }
        func dispatchSync(_ block: @escaping () -> Void) { block() }
    }

    private func makeMonoPCM16Buffer(frames: Int, value: Int16) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.int16ChannelData?[0])
        data.update(repeating: value, count: frames)
        return buffer
    }

    @MainActor
    func testAudioUnitRenderErrorLogsExplicitlyAndReleasesSessionOnStop() throws {
        let priorLogs = Set(AppLog.shared.lines)
        let session = RTCAudioSession.sharedInstance()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        try audio.startCapture()
        defer { _ = audio.stopCapture(session: 1) }

        XCTAssertTrue(audio.ensureRunning(), "startCapture must leave the VPIO audio unit and RTCAudioSession running")
        XCTAssertTrue(session.isActive)

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        let status = audio.handleAudioUnitInput(
            ioActionFlags: &flags,
            inTimeStamp: &timestamp,
            inBusNumber: 99,
            inNumberFrames: 480
        )
        XCTAssertNotEqual(status, noErr, "Rendering from an invalid AudioUnit bus must return a real CoreAudio OSStatus error")

        let errorLogs = AppLog.shared.lines.filter {
            !priorLogs.contains($0) && $0.contains("opening audio unit render error") && $0.contains("\(status)")
        }
        XCTAssertFalse(errorLogs.isEmpty, "AudioUnitRender failure must be logged explicitly instead of swallowed silently")

        _ = audio.stopCapture(session: 1)
        XCTAssertFalse(audio.ensureRunning())
        XCTAssertFalse(session.isActive, "Stopping opening capture must release RTCAudioSession")
    }

    func testAudioUnitPlayoutCallbackWritesWebRTCInt16PCMAndHandlesErrors() {
        let probe = DelegateProbe()
        probe.playoutSamples = [1_234, -5_678, 9_012, -3_456]
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializePlayout())
        XCTAssertTrue(audio.startPlayout())
        XCTAssertTrue(audio.allowSending(session: 1))

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        XCTAssertEqual(
            audio.handleAudioUnitPlayout(ioActionFlags: &flags, inTimeStamp: &timestamp, inNumberFrames: 4, ioData: nil),
            kAudio_ParamError
        )

        var output = [Int16](repeating: 99, count: 4)
        flags = []
        let okStatus = output.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(buffer.count * MemoryLayout<Int16>.stride),
                mData: buffer.baseAddress
            ))
            return audio.handleAudioUnitPlayout(ioActionFlags: &flags, inTimeStamp: &timestamp, inNumberFrames: 4, ioData: &list)
        }
        XCTAssertEqual(okStatus, noErr)
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(output, [1_234, -5_678, 9_012, -3_456])

        probe.playoutStatus = -50
        output = [Int16](repeating: 77, count: 4)
        flags = []
        let errStatus = output.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(buffer.count * MemoryLayout<Int16>.stride),
                mData: buffer.baseAddress
            ))
            return audio.handleAudioUnitPlayout(ioActionFlags: &flags, inTimeStamp: &timestamp, inNumberFrames: 4, ioData: &list)
        }
        XCTAssertEqual(errStatus, -50)
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(output, [0, 0, 0, 0], "Failed WebRTC playout must zero the output buffer and mark silence")
    }

    @MainActor
    func testOpeningCaptureDeliversChunkedInt16AudioAndLogsDeliveryErrors() throws {
        let priorLogs = Set(AppLog.shared.lines)
        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(session: 1, playReadyChime: false)
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())

        let opening = try makeMonoPCM16Buffer(frames: 960, value: 4_200)
        audio.input(opening, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        XCTAssertEqual(audio.bufferedFrameCount, 960)
        XCTAssertTrue(probe.sent.isEmpty, "Opening audio must stay buffered until WebRTC handoff")

        XCTAssertTrue(audio.allowSending(session: 1))
        let live = try makeMonoPCM16Buffer(frames: 480, value: -2_100)
        audio.input(live, at: AVAudioTime(sampleTime: 960, atRate: 48_000))

        XCTAssertEqual(probe.chunkCounts, [480, 480, 480])
        XCTAssertEqual(probe.deliveredSampleTimes, [0, 480, 960])
        XCTAssertEqual(probe.sent, [Int16](repeating: 4_200, count: 960) + [Int16](repeating: -2_100, count: 480))

        probe.deliveryStatus = -50
        let failing = try makeMonoPCM16Buffer(frames: 480, value: 1_500)
        audio.input(failing, at: AVAudioTime(sampleTime: 1_440, atRate: 48_000))
        let deliveryLogs = AppLog.shared.lines.filter {
            !priorLogs.contains($0) && $0.contains("opening audio deliverRecordedData error") && $0.contains("-50")
        }
        XCTAssertFalse(deliveryLogs.isEmpty, "WebRTC deliverRecordedData failure must be logged explicitly")
    }
}
