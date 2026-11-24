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

    func testRecoveryPolicyEnforcesMonotonicBackgroundGrantAndAllowsForeground() {
        var policy = OpeningAudioRecoveryPolicy(enabled: true)
        for _ in 0..<75 {
            _ = policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false)
        }

        // Background with no grant must deny every restart trigger.
        let allTriggers: [OpeningAudioRecoveryPolicy.RestartTrigger] = [
            .sustainedZeroInput(attempt: 1),
            .spatialCapabilitiesChanged,
            .interruptionEnded,
            .mediaServicesReset,
            .ensureRunning,
        ]
        for trigger in allTriggers {
            XCTAssertEqual(
                policy.evaluateRestart(trigger: trigger, isStopped: false, isInputMuted: false, inBackground: true, now: 100.0),
                .skip(.backgroundGrantExpired),
                "Background restart for \(trigger.logDescription) must be denied without an active grant"
            )
        }

        // Active monotonic grant (100.0 ..< 103.5) allows restarts before deadline.
        let grantToken = UUID()
        policy.setBackgroundGrant(BackgroundRecordingGrant(token: grantToken, deadline: 103.5))
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .sustainedZeroInput(attempt: 1), isStopped: false, isInputMuted: false, inBackground: true, now: 101.5),
            .restart(attempt: 1, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: true, now: 102.0),
            .restart(attempt: 2, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .interruptionEnded, isStopped: false, isInputMuted: false, inBackground: true, now: 103.49),
            .restartLifecycle
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .mediaServicesReset, isStopped: false, isInputMuted: false, inBackground: true, now: 103.49),
            .restartLifecycle
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .ensureRunning, isStopped: false, isInputMuted: false, inBackground: true, now: 103.49),
            .restartLifecycle
        )

        // At or past monotonic deadline (103.5), every background restart entry is denied and
        // further zero-input callbacks do not repeatedly schedule recovery while still in background.
        for trigger in allTriggers {
            XCTAssertEqual(
                policy.evaluateRestart(trigger: trigger, isStopped: false, isInputMuted: false, inBackground: true, now: 103.5),
                .skip(.backgroundGrantExpired),
                "Expired background grant at exact deadline must deny \(trigger.logDescription)"
            )
        }
        for _ in 0..<200 {
            XCTAssertEqual(
                policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false),
                .none,
                "Expired background grant must suppress repeated zero-input callback dispatches"
            )
        }

        // Wrong token cannot clear the current grant; matching token clears it.
        policy.clearBackgroundGrant(token: UUID())
        XCTAssertEqual(policy.backgroundGrant?.token, grantToken)
        policy.clearBackgroundGrant(token: grantToken)
        XCTAssertNil(policy.backgroundGrant)

        // Foreground always permits recovery and lifecycle restarts even with no background grant.
        policy.noteForeground()
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .appBecameActive, isStopped: false, isInputMuted: false, inBackground: false, now: 105.0),
            .restart(attempt: 3, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .interruptionEnded, isStopped: false, isInputMuted: false, inBackground: false, now: 105.0),
            .restartLifecycle
        )
    }

    func testRecoveryPolicySkipsMutedWithoutRepeatDispatchCapsAtTenAndLatchesFirstNonZero() {
        var policy = OpeningAudioRecoveryPolicy(enabled: true)

        // Reaching threshold and observing muted input suppresses subsequent zero callbacks until unmuted.
        var triggered = 0
        for _ in 0..<75 {
            if case .requestZeroInputRecovery = policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false) {
                triggered += 1
            }
        }
        XCTAssertEqual(triggered, 1)
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .sustainedZeroInput(attempt: 1), isStopped: false, isInputMuted: true, inBackground: false, now: 200.0),
            .skip(.inputMuted)
        )
        for _ in 0..<150 {
            XCTAssertEqual(
                policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false),
                .none,
                "Active input mute must stop repeated main-actor recovery dispatches on every callback"
            )
        }

        // Unmuting starts a fresh 72,000-frame zero window.
        policy.setInputMuted(false)
        for _ in 0..<74 {
            XCTAssertEqual(policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false), .none)
        }
        XCTAssertEqual(
            policy.recordInput(frameCount: 960, maxSample: 0, isStopped: false),
            .requestZeroInputRecovery(attempt: 1)
        )

        // Spatial notification enforces a 0.5 s monotonic throttle.
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 201.0),
            .restart(attempt: 1, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 201.49),
            .skip(.spatialThrottled)
        )
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 201.5),
            .restart(attempt: 2, clearZeroBuffer: true)
        )

        // Concrete total restart cap is 10 (2 already used, 8 more allowed, 11th rejected).
        var now = 202.0
        for expectedAttempt in 3...10 {
            XCTAssertEqual(
                policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: now),
                .restart(attempt: expectedAttempt, clearZeroBuffer: true)
            )
            now += 1.0
        }
        XCTAssertEqual(
            policy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: now),
            .skip(.attemptLimitReached),
            "Recovery restarts must stop at the concrete cap of 10"
        )

        // First non-zero frame latches recovery once and permanently disables subsequent zero-input restarts.
        var latchPolicy = OpeningAudioRecoveryPolicy(enabled: true)
        _ = latchPolicy.recordInput(frameCount: 960, maxSample: 0, isStopped: false)
        XCTAssertEqual(
            latchPolicy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 10.0),
            .restart(attempt: 1, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            latchPolicy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 11.0),
            .restart(attempt: 2, clearZeroBuffer: true)
        )
        XCTAssertEqual(
            latchPolicy.recordInput(frameCount: 960, maxSample: 1_800, isStopped: false),
            .recoveredNonZero(attempts: 2)
        )
        XCTAssertTrue(latchPolicy.hasObservedNonZeroInput)
        XCTAssertEqual(latchPolicy.recordInput(frameCount: 960, maxSample: 1_600, isStopped: false), .none)
        for _ in 0..<200 {
            XCTAssertEqual(latchPolicy.recordInput(frameCount: 960, maxSample: 0, isStopped: false), .none)
        }
        XCTAssertEqual(
            latchPolicy.evaluateRestart(trigger: .spatialCapabilitiesChanged, isStopped: false, isInputMuted: false, inBackground: false, now: 20.0),
            .skip(.alreadyObservedNonZero)
        )
    }

    @MainActor
    func testExpiredBackgroundGrantPreservesRunningAudioUnitAndForegroundRecoveryRestartsAndDeliversSpeech() async throws {
        let priorLogs = Set(AppLog.shared.lines)
        let session = RTCAudioSession.sharedInstance()
        let center = NotificationCenter()
        let clockLock = NSLock()
        var currentUptime: TimeInterval = 500.0
        let readUptime: @Sendable () -> TimeInterval = { clockLock.withLock { currentUptime } }
        var inBackground = true

        let audio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: readUptime,
            isInputMuted: { false },
            isInBackground: { inBackground }
        )
        try audio.startCapture()
        defer { _ = audio.stopCapture(session: 1) }

        let originalUnit = try XCTUnwrap(audio.audioUnitIdentity, "startCapture must create a real VPIO AudioComponentInstance")
        XCTAssertTrue(audio.ensureRunning())
        XCTAssertTrue(session.isActive)

        // Install grant expiring at 503.5 and advance monotonic clock past deadline.
        audio.setBackgroundRecordingGrant(BackgroundRecordingGrant(token: UUID(), deadline: 503.5))
        clockLock.withLock { currentUptime = 503.6 }

        let zeroChunk = try makeMonoPCM16Buffer(frames: 960, value: 0)
        for index in 0..<75 {
            audio.input(zeroChunk, at: AVAudioTime(sampleTime: AVAudioFramePosition(index * 960), atRate: 48_000))
        }
        center.post(name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        // Drain main-queue notification observer tasks.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            audio.audioUnitIdentity,
            originalUnit,
            "Expired background grant must never tear down or replace a running VPIO audioUnit"
        )
        XCTAssertTrue(audio.ensureRunning(), "Running audioUnit must remain alive after skipped background restarts")
        XCTAssertTrue(session.isActive)
        let skippedLogs = AppLog.shared.lines.filter {
            !priorLogs.contains($0) && $0.contains("background recording grant expired; keeping existing unit")
        }
        XCTAssertFalse(skippedLogs.isEmpty, "Skipping background restart after grant expiry must be logged")
        XCTAssertGreaterThanOrEqual(audio.bufferedFrameCount, 75 * 960, "Skipped restart must leave buffered state untouched until real recovery runs")

        // Moving to foreground allows a real lifecycle VPIO restart and keeps RTCAudioSession balanced.
        inBackground = false
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let restartDeadline = Date().addingTimeInterval(2.0)
        while Date() < restartDeadline {
            if AppLog.shared.lines.contains(where: { !priorLogs.contains($0) && $0.contains("opening audio unit restarted after interruption ended") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            AppLog.shared.lines.contains(where: { !priorLogs.contains($0) && $0.contains("opening audio unit restarted after interruption ended") }),
            "Foreground interruption-end recovery must run the real VPIO restart path"
        )
        XCTAssertTrue(audio.ensureRunning(), "Real VPIO restart must leave the audio unit and RTCAudioSession active")

        _ = audio.stopCapture(session: 1)
        XCTAssertNil(audio.audioUnitIdentity)
        XCTAssertFalse(audio.ensureRunning())
        XCTAssertFalse(session.isActive, "stopCapture must balance all RTCAudioSession activations including real restarts")

        // Sustained exact-zero input (before any non-zero hardware audio) clears the dead 72,000-frame
        // leading silence buffer, runs real VPIO recovery, delivers subsequent speech cleanly, and balances stop.
        let recoveryPriorLogs = Set(AppLog.shared.lines)
        let zeroRecoveryAudio = OpeningVoiceAudio(
            session: 2,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: readUptime,
            isInputMuted: { false },
            isInBackground: { false }
        )
        defer { _ = zeroRecoveryAudio.stopCapture(session: 2) }
        for index in 0..<75 {
            zeroRecoveryAudio.input(zeroChunk, at: AVAudioTime(sampleTime: AVAudioFramePosition(index * 960), atRate: 48_000))
        }
        let zeroRecoveryDeadline = Date().addingTimeInterval(2.0)
        while Date() < zeroRecoveryDeadline {
            if AppLog.shared.lines.contains(where: { !recoveryPriorLogs.contains($0) && $0.contains("opening audio unit restarted after sustained zero input (#1)") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            AppLog.shared.lines.contains(where: { !recoveryPriorLogs.contains($0) && $0.contains("opening audio unit restarted after sustained zero input (#1)") }),
            "Sustained zero input in foreground must run real VPIO restart"
        )
        XCTAssertNotNil(zeroRecoveryAudio.audioUnitIdentity)
        XCTAssertTrue(zeroRecoveryAudio.ensureRunning())
        XCTAssertLessThan(zeroRecoveryAudio.bufferedFrameCount, 75 * 960, "Real zero-input recovery while buffering must clear the stale 72,000-frame zero prefix")

        let probe = DelegateProbe()
        XCTAssertTrue(zeroRecoveryAudio.initialize(with: probe))
        XCTAssertTrue(zeroRecoveryAudio.initializeRecording())
        XCTAssertTrue(zeroRecoveryAudio.startRecording())
        let openingSpeech = try makeMonoPCM16Buffer(frames: 480, value: 2_400)
        zeroRecoveryAudio.input(openingSpeech, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        XCTAssertTrue(zeroRecoveryAudio.allowSending(session: 2))
        let liveSpeech = try makeMonoPCM16Buffer(frames: 480, value: -1_200)
        zeroRecoveryAudio.input(liveSpeech, at: AVAudioTime(sampleTime: 480, atRate: 48_000))
        XCTAssertTrue(probe.sent.contains(2_400), "Buffered speech after real recovery must reach WebRTC")
        XCTAssertTrue(probe.sent.contains(-1_200), "Live speech after real recovery must reach WebRTC")
        XCTAssertLessThan(probe.sent.count, 75 * 960, "Handoff after real recovery must not include the cleared 72,000-frame dead silence prefix")

        _ = zeroRecoveryAudio.stopCapture(session: 2)
        XCTAssertNil(zeroRecoveryAudio.audioUnitIdentity)
        XCTAssertFalse(zeroRecoveryAudio.ensureRunning())
        XCTAssertFalse(session.isActive, "stopCapture must release RTCAudioSession after sustained zero-input restart")
    }

    @MainActor
    func testWaitForLiveInputDeterministicWakeupTimeoutStopAndCancellation() async throws {
        var muted = false
        let neverFinishSleep: @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(60))
        }
        let audio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: neverFinishSleep,
            isInputMuted: { muted },
            isInBackground: { false }
        )

        // 1. Muted fast path.
        muted = true
        let mutedResult = await audio.waitForLiveInput(timeout: .seconds(60))
        XCTAssertEqual(mutedResult, .skippedMuted)
        muted = false

        // 2. Deterministic synchronous registration of two concurrent waiters (no Task.yield polling).
        let wait1 = audio.startLiveInputWait()
        let wait2 = audio.startLiveInputWait()
        let nonZeroChunk = try makeMonoPCM16Buffer(frames: 480, value: 2_400)
        audio.input(nonZeroChunk, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        let result1 = await audio.awaitLiveInputWait(wait1, timeout: .seconds(60))
        let result2 = await audio.awaitLiveInputWait(wait2, timeout: .seconds(60))
        XCTAssertEqual(result1, .live)
        XCTAssertEqual(result2, .live)

        // 3. Already-live fast path vs already-cancelled fast path.
        let alreadyLive = await audio.waitForLiveInput(timeout: .seconds(60))
        XCTAssertEqual(alreadyLive, .live)
        let cancelledTask = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await audio.waitForLiveInput(timeout: .seconds(60))
        }
        let cancelledFastPath = await cancelledTask.value
        XCTAssertEqual(cancelledFastPath, .cancelled, "Cancelled task must report .cancelled instead of conflating with .live")

        // 4. Controllable timeout returns .timedOut immediately without wall-clock waiting.
        let immediateTimeoutAudio = OpeningVoiceAudio(
            session: 2,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: { _ in },
            isInputMuted: { false },
            isInBackground: { true }
        )
        let timedOut = await immediateTimeoutAudio.waitForLiveInput(timeout: .seconds(8))
        XCTAssertEqual(timedOut, .timedOut)

        // 5. stopCapture releases a registered waiter immediately with .stopped (never via 60 s timeout).
        let stoppedAudio = OpeningVoiceAudio(
            session: 3,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: neverFinishSleep,
            isInputMuted: { false },
            isInBackground: { false }
        )
        let stopWait = stoppedAudio.startLiveInputWait()
        _ = stoppedAudio.stopCapture(session: 3)
        let stoppedResult = await stoppedAudio.awaitLiveInputWait(stopWait, timeout: .seconds(60))
        XCTAssertEqual(stoppedResult, .stopped, "stopCapture must wake waiters immediately with .stopped")

        // 6. Cancelling an in-flight wait resolves immediately with .cancelled.
        let cancelAudio = OpeningVoiceAudio(
            session: 4,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: neverFinishSleep,
            isInputMuted: { false },
            isInBackground: { false }
        )
        let cancelWait = cancelAudio.startLiveInputWait()
        let inFlightTask = Task { @MainActor in
            await cancelAudio.awaitLiveInputWait(cancelWait, timeout: .seconds(60))
        }
        inFlightTask.cancel()
        let inFlightCancelled = await inFlightTask.value
        XCTAssertEqual(inFlightCancelled, .cancelled)
    }
}
