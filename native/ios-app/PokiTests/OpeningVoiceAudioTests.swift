import AudioToolbox
import AVFoundation
import Observation
import WebRTC
import XCTest
@testable import Poki

final class OpeningVoiceAudioTests: XCTestCase {
    private final class DelegateProbe: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
        let preferredInputSampleRate = 48_000.0
        let preferredOutputSampleRate = 48_000.0
        let preferredInputIOBufferDuration = 0.01
        let preferredOutputIOBufferDuration = 0.01
        private let lock = NSLock()
        private var _sent: [Int16] = []
        private var _chunkCounts: [Int] = []
        private var _deliveredSampleTimes: [Double] = []
        private var _recordedCallbackCount = 0
        private var _inputInterruptedCount = 0
        private var _outputInterruptedCount = 0
        private var _deliveryStatus: OSStatus = noErr
        private var _playoutSamples: [Int16] = []
        private var _playoutStatus: OSStatus = noErr
        private var _playoutSilent = false
        private var recordedWaiters: [(id: UUID, target: Int, continuation: CheckedContinuation<Int?, Never>)] = []
        private var inputInterruptedWaiters: [(id: UUID, target: Int, continuation: CheckedContinuation<Int?, Never>)] = []

        var sent: [Int16] { lock.withLock { _sent } }
        var chunkCounts: [Int] { lock.withLock { _chunkCounts } }
        var deliveredSampleTimes: [Double] { lock.withLock { _deliveredSampleTimes } }
        var recordedCallbackCount: Int { lock.withLock { _recordedCallbackCount } }
        var inputInterruptedCount: Int { lock.withLock { _inputInterruptedCount } }
        var outputInterruptedCount: Int { lock.withLock { _outputInterruptedCount } }
        var deliveryStatus: OSStatus {
            get { lock.withLock { _deliveryStatus } }
            set { lock.withLock { _deliveryStatus = newValue } }
        }
        var playoutSamples: [Int16] {
            get { lock.withLock { _playoutSamples } }
            set { lock.withLock { _playoutSamples = newValue } }
        }
        var playoutStatus: OSStatus {
            get { lock.withLock { _playoutStatus } }
            set { lock.withLock { _playoutStatus = newValue } }
        }
        var playoutSilent: Bool {
            get { lock.withLock { _playoutSilent } }
            set { lock.withLock { _playoutSilent = newValue } }
        }

        func waitForRecordedCallback(
            after priorCount: Int,
            timeout: Duration = .seconds(5),
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Int {
            let target = priorCount + 1
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired: CheckedContinuation<Int?, Never>? = self.lock.withLock {
                    guard let index = self.recordedWaiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.recordedWaiters.remove(at: index).continuation
                }
                expired?.resume(returning: nil)
            }
            let result: Int? = await withCheckedContinuation { continuation in
                let immediate: Int? = lock.withLock {
                    if _recordedCallbackCount >= target {
                        return _recordedCallbackCount
                    }
                    recordedWaiters.append((waiterID, target, continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
            timeoutTask.cancel()
            guard let result else {
                XCTFail("Timed out waiting for recorded callback after \(priorCount)", file: file, line: line)
                return priorCount
            }
            return result
        }

        func waitForInputInterrupted(
            after priorCount: Int,
            timeout: Duration = .seconds(5),
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Int {
            let target = priorCount + 1
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired: CheckedContinuation<Int?, Never>? = self.lock.withLock {
                    guard let index = self.inputInterruptedWaiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.inputInterruptedWaiters.remove(at: index).continuation
                }
                expired?.resume(returning: nil)
            }
            let result: Int? = await withCheckedContinuation { continuation in
                let immediate: Int? = lock.withLock {
                    if _inputInterruptedCount >= target {
                        return _inputInterruptedCount
                    }
                    inputInterruptedWaiters.append((waiterID, target, continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
            timeoutTask.cancel()
            guard let result else {
                XCTFail("Timed out waiting for input interruption notification after \(priorCount)", file: file, line: line)
                return priorCount
            }
            return result
        }

        var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
            { [weak self] _, timestamp, _, count, buffer, _, _ in
                guard let self else { return noErr }
                let (status, waking, total): (OSStatus, [CheckedContinuation<Int?, Never>], Int) = self.lock.withLock {
                    self._recordedCallbackCount += 1
                    self._chunkCounts.append(Int(count))
                    self._deliveredSampleTimes.append(timestamp.pointee.mSampleTime)
                    if let data = buffer?.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                        self._sent.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(count)))
                    }
                    let countNow = self._recordedCallbackCount
                    let ready = self.recordedWaiters.filter { countNow >= $0.target }.map(\.continuation)
                    self.recordedWaiters.removeAll { countNow >= $0.target }
                    return (self._deliveryStatus, ready, countNow)
                }
                for waiter in waking {
                    waiter.resume(returning: total)
                }
                return status
            }
        }
        var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
            { [weak self] flags, _, _, count, buffer in
                guard let self else { return noErr }
                let (status, silent, samples) = self.lock.withLock {
                    (self._playoutStatus, self._playoutSilent, self._playoutSamples)
                }
                if status != noErr { return status }
                if silent {
                    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                    return noErr
                }
                if let destination = buffer.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    let n = min(Int(count), samples.count)
                    for i in 0..<n { destination[i] = samples[i] }
                    if n < Int(count) {
                        destination.advanced(by: n).update(repeating: 0, count: Int(count) - n)
                    }
                }
                return noErr
            }
        }
        func notifyAudioInputParametersChange() {}
        func notifyAudioOutputParametersChange() {}
        func notifyAudioInputInterrupted() {
            let (waking, total): ([CheckedContinuation<Int?, Never>], Int) = lock.withLock {
                _inputInterruptedCount += 1
                let countNow = _inputInterruptedCount
                let ready = inputInterruptedWaiters.filter { countNow >= $0.target }.map(\.continuation)
                inputInterruptedWaiters.removeAll { countNow >= $0.target }
                return (ready, countNow)
            }
            for waiter in waking {
                waiter.resume(returning: total)
            }
        }
        func notifyAudioOutputInterrupted() {
            lock.withLock { _outputInterruptedCount += 1 }
        }
        func dispatchAsync(_ block: @escaping () -> Void) { block() }
        func dispatchSync(_ block: @escaping () -> Void) { block() }
    }

    @MainActor
    private func addLogMarker(_ label: String) -> String {
        let marker = "opening-audio-test-\(label)-\(UUID().uuidString)"
        AppLog.shared.add("test", marker)
        return marker
    }

    @MainActor
    private func logs(after marker: String) -> [String] {
        Array(AppLog.shared.lines.drop(while: { !$0.hasSuffix(marker) }).dropFirst())
    }

    @MainActor
    private func waitForLogLine(
        after marker: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        matching predicate: @escaping @MainActor (String) -> Bool
    ) async -> String? {
        if let existing = logs(after: marker).first(where: predicate) {
            return existing
        }
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            continuation.yield(false)
            continuation.finish()
        }
        defer {
            timeoutTask.cancel()
            continuation.finish()
        }
        func armObservation() {
            withObservationTracking {
                _ = AppLog.shared.lines
            } onChange: {
                Task { @MainActor in
                    continuation.yield(true)
                }
            }
        }
        armObservation()
        for await changed in stream {
            if let match = logs(after: marker).first(where: predicate) {
                return match
            }
            if !changed {
                XCTFail("Timed out waiting for expected log line after \(marker)", file: file, line: line)
                return nil
            }
            armObservation()
        }
        XCTFail("Log observation ended before expected log line after \(marker)", file: file, line: line)
        return nil
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
    func testExpiredBackgroundGrantPreservesRunningAudioUnitAcrossEveryTriggerAndForegroundRecovers() async throws {
        let session = RTCAudioSession.sharedInstance()
        let center = NotificationCenter()
        let clockLock = NSLock()
        var currentUptime: TimeInterval = 500.0
        let readUptime: @Sendable () -> TimeInterval = { clockLock.withLock { currentUptime } }
        var inBackground = true
        var stopUnitOnNextQuery = false
        var overrideRunState: OpeningVoiceAudio.AudioUnitRunState?
        var queriedUnits: [AudioComponentInstance] = []

        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: readUptime,
            isInputMuted: { false },
            isInBackground: { inBackground },
            queryAudioUnitRunState: { unit in
                queriedUnits.append(unit)
                if let overrideRunState {
                    return overrideRunState
                }
                if stopUnitOnNextQuery {
                    stopUnitOnNextQuery = false
                    let stopStatus = AudioOutputUnitStop(unit)
                    XCTAssertEqual(stopStatus, noErr, "AudioOutputUnitStop must stop the real VPIO unit")
                }
                return OpeningVoiceAudio.queryCoreAudioRunState(unit)
            }
        )
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())
        XCTAssertTrue(audio.allowSending(session: 1))
        try audio.startCapture()
        defer { _ = audio.stopCapture(session: 1) }

        XCTAssertTrue(audio.ensureRunning(), "startCapture must leave real VPIO running")
        XCTAssertTrue(session.isActive)
        var lastCallbackCount = await probe.waitForRecordedCallback(after: 0)

        // Install grant expiring at 503.5 and advance monotonic clock past deadline.
        audio.setBackgroundRecordingGrant(BackgroundRecordingGrant(token: UUID(), deadline: 503.5))
        clockLock.withLock { currentUptime = 503.6 }

        // Entry 1: spatial playback capabilities changed (synchronous on main queue).
        let spatialMarker = addLogMarker("spatial-expired")
        center.post(name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        let spatialLogs = logs(after: spatialMarker)
        XCTAssertTrue(
            spatialLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for spatial playback capabilities changed: background recording grant expired; keeping existing unit") }),
            "Spatial notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(spatialLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        XCTAssertTrue(session.isActive)
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        // Entry 2: audio session interruption ended (synchronous on main queue).
        let interruptionMarker = addLogMarker("interruption-expired")
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let interruptionLogs = logs(after: interruptionMarker)
        XCTAssertTrue(
            interruptionLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for interruption ended: background recording grant expired; keeping existing unit") }),
            "Interruption-ended notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(interruptionLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        // Entry 3: media services were reset (synchronous on main queue).
        let resetMarker = addLogMarker("reset-expired")
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let resetLogs = logs(after: resetMarker)
        XCTAssertTrue(
            resetLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for media services reset: background recording grant expired; keeping existing unit") }),
            "Media-services-reset notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(resetLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        // Entry 4a: ensureRunning() sees a genuinely stopped CoreAudio VPIO unit while grant is expired.
        // It must NOT tear down or replace the existing unit, and must return false.
        let ensureExpiredMarker = addLogMarker("ensure-expired")
        queriedUnits.removeAll()
        stopUnitOnNextQuery = true
        XCTAssertFalse(
            audio.ensureRunning(),
            "ensureRunning must return false when CoreAudio reports the VPIO unit stopped and background grant is expired"
        )
        let ensureExpiredLogs = logs(after: ensureExpiredMarker)
        XCTAssertTrue(
            ensureExpiredLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for ensureRunning: background recording grant expired; keeping existing unit") }),
            "ensureRunning after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(ensureExpiredLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertEqual(queriedUnits.count, 2, "ensureRunning must query before and after skipping restart")
        XCTAssertEqual(queriedUnits.first, queriedUnits.last, "Expired ensureRunning must keep the exact existing AudioUnit")

        // Entry 4b: moving to foreground allows ensureRunning() to recover the real stopped VPIO unit.
        inBackground = false
        let ensureForegroundMarker = addLogMarker("ensure-foreground")
        XCTAssertTrue(audio.ensureRunning(), "Foreground ensureRunning must restart a stopped VPIO unit and report running")
        let ensureForegroundLogs = logs(after: ensureForegroundMarker)
        XCTAssertTrue(ensureForegroundLogs.contains(where: { $0.contains("opening audio unit restarted after ensureRunning") }))
        XCTAssertTrue(ensureForegroundLogs.contains(where: { $0.contains("opening audio unit started:") }))
        XCTAssertEqual(probe.inputInterruptedCount, 1)
        XCTAssertEqual(probe.outputInterruptedCount, 1)
        XCTAssertTrue(session.isActive)
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        // Entry 4c: unknown CoreAudio status (status != noErr) must return false WITHOUT tearing down the running unit.
        let ensureUnknownMarker = addLogMarker("ensure-unknown")
        overrideRunState = .unknown(kAudioUnitErr_Uninitialized)
        XCTAssertFalse(audio.ensureRunning(), "Unknown CoreAudio run state must return false instead of reporting healthy")
        overrideRunState = nil
        let ensureUnknownLogs = logs(after: ensureUnknownMarker)
        XCTAssertTrue(ensureUnknownLogs.contains(where: { $0.contains("could not query VPIO state") && $0.contains("\(kAudioUnitErr_Uninitialized)") }))
        XCTAssertFalse(ensureUnknownLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(probe.inputInterruptedCount, 1, "Unknown run state must preserve the existing AudioUnit")
        XCTAssertTrue(audio.ensureRunning(), "Existing VPIO unit must still be running after an unknown-state query")
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        // Foreground lifecycle notifications replace the real VPIO unit and notify WebRTC synchronously.
        let fgInterruptionMarker = addLogMarker("fg-interruption")
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let fgInterruptionLogs = logs(after: fgInterruptionMarker)
        XCTAssertTrue(fgInterruptionLogs.contains(where: { $0.contains("opening audio unit restarted after interruption ended") }))
        XCTAssertEqual(probe.inputInterruptedCount, 2)
        XCTAssertTrue(audio.ensureRunning())
        lastCallbackCount = await probe.waitForRecordedCallback(after: lastCallbackCount)

        let fgResetMarker = addLogMarker("fg-reset")
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let fgResetLogs = logs(after: fgResetMarker)
        XCTAssertTrue(fgResetLogs.contains(where: { $0.contains("opening audio unit restarted after media services reset") }))
        XCTAssertEqual(probe.inputInterruptedCount, 3)
        XCTAssertTrue(audio.ensureRunning())
        _ = await probe.waitForRecordedCallback(after: lastCallbackCount)

        _ = audio.stopCapture(session: 1)
        XCTAssertFalse(audio.ensureRunning())
        XCTAssertFalse(session.isActive, "stopCapture must balance all RTCAudioSession activations including real restarts")
    }

    private final class RenderTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var initialUnit: AudioComponentInstance?
        private var replacedUnitObserved = false

        func record(_ unit: AudioComponentInstance) -> Bool {
            lock.withLock {
                if initialUnit == nil {
                    initialUnit = unit
                    return true
                }
                if unit == initialUnit {
                    return true
                }
                replacedUnitObserved = true
                return false
            }
        }

        var sawReplacedUnit: Bool {
            lock.withLock { replacedUnitObserved }
        }
    }

    @MainActor
    func testSustainedZeroInputThroughRealVPIOSkipsWhenGrantExpiredAndRecoversInForeground() async throws {
        let session = RTCAudioSession.sharedInstance()
        let center = NotificationCenter()
        let clockLock = NSLock()
        var currentUptime: TimeInterval = 500.0
        let readUptime: @Sendable () -> TimeInterval = { clockLock.withLock { currentUptime } }

        // Part 1: Sustained zero input from real VPIO AudioUnitRender with expired background grant
        // skips restart and keeps the exact same running unit delivering callbacks, independent of host room noise.
        let expiredTracker = RenderTracker()
        let expiredProbe = DelegateProbe()
        let expiredAudio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: readUptime,
            isInputMuted: { false },
            isInBackground: { true },
            renderAudioUnitInput: { unit, flags, timestamp, bus, frames, bufferList in
                let status = OpeningVoiceAudio.renderCoreAudioInput(unit, flags, timestamp, bus, frames, bufferList)
                guard status == noErr else { return status }
                _ = expiredTracker.record(unit)
                if let data = bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    data.update(repeating: 0, count: Int(frames))
                }
                return noErr
            }
        )
        expiredAudio.setBackgroundRecordingGrant(BackgroundRecordingGrant(token: UUID(), deadline: 503.5))
        clockLock.withLock { currentUptime = 503.6 }
        XCTAssertTrue(expiredAudio.initialize(with: expiredProbe))
        XCTAssertTrue(expiredAudio.initializeRecording())
        XCTAssertTrue(expiredAudio.startRecording())
        XCTAssertTrue(expiredAudio.allowSending(session: 1))
        let expiredMarker = addLogMarker("sustained-zero-expired")
        try expiredAudio.startCapture()
        defer { _ = expiredAudio.stopCapture(session: 1) }

        let skipLine = await waitForLogLine(after: expiredMarker, timeout: .seconds(6)) {
            $0.contains("opening audio skipped VPIO restart for sustained zero input (#1): background recording grant expired; keeping existing unit")
        }
        XCTAssertNotNil(skipLine)
        let expiredLogs = logs(after: expiredMarker)
        XCTAssertFalse(expiredLogs.contains(where: { $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(expiredProbe.inputInterruptedCount, 0)
        XCTAssertEqual(expiredProbe.outputInterruptedCount, 0)
        XCTAssertTrue(expiredAudio.ensureRunning())
        let callbackAfterSkip = expiredProbe.recordedCallbackCount
        let nextCallbackAfterSkip = await expiredProbe.waitForRecordedCallback(after: callbackAfterSkip, timeout: .seconds(5))
        XCTAssertGreaterThan(nextCallbackAfterSkip, callbackAfterSkip)
        XCTAssertFalse(expiredTracker.sawReplacedUnit, "Expired sustained zero input must keep rendering on the original AudioUnit")

        _ = expiredAudio.stopCapture(session: 1)
        XCTAssertFalse(expiredAudio.ensureRunning())
        XCTAssertFalse(session.isActive)

        // Part 2: Sustained zero input from an already-running real VPIO unit in foreground
        // clears the stale 72,000-frame zero buffer, replaces the running VPIO unit, and resumes callbacks on the new unit.
        let recoveryTracker = RenderTracker()
        let recoveryProbe = DelegateProbe()
        let recoveryAudio = OpeningVoiceAudio(
            session: 2,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: readUptime,
            isInputMuted: { false },
            isInBackground: { false },
            renderAudioUnitInput: { unit, flags, timestamp, bus, frames, bufferList in
                let status = OpeningVoiceAudio.renderCoreAudioInput(unit, flags, timestamp, bus, frames, bufferList)
                guard status == noErr else { return status }
                if recoveryTracker.record(unit),
                   let data = bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    data.update(repeating: 0, count: Int(frames))
                }
                return noErr
            }
        )
        XCTAssertTrue(recoveryAudio.initialize(with: recoveryProbe))
        XCTAssertTrue(recoveryAudio.initializeRecording())
        XCTAssertTrue(recoveryAudio.startRecording())
        let recoveryMarker = addLogMarker("sustained-zero-foreground")
        try recoveryAudio.startCapture()
        defer { _ = recoveryAudio.stopCapture(session: 2) }

        let interruptedCount = await recoveryProbe.waitForInputInterrupted(after: 0, timeout: .seconds(6))
        XCTAssertEqual(interruptedCount, 1)
        let recoveryLogs = logs(after: recoveryMarker)
        XCTAssertTrue(
            recoveryLogs.contains(where: { $0.contains("opening audio unit restarted after sustained zero input (#1)") }),
            "Sustained zero input from real VPIO in foreground must replace the running audio unit"
        )
        XCTAssertTrue(recoveryAudio.ensureRunning())
        XCTAssertLessThan(recoveryAudio.bufferedFrameCount, 72_000, "Real zero-input recovery while buffering must clear the stale 72,000-frame zero prefix")

        XCTAssertTrue(recoveryAudio.allowSending(session: 2))
        let postRecoveryCallbacks = await recoveryProbe.waitForRecordedCallback(after: 0, timeout: .seconds(5))
        XCTAssertGreaterThan(postRecoveryCallbacks, 0, "Replaced VPIO unit must continue delivering real AudioUnitRender callbacks")
        XCTAssertTrue(recoveryTracker.sawReplacedUnit, "Real AudioUnitRender callbacks after recovery must come from the replaced AudioUnit")

        _ = recoveryAudio.stopCapture(session: 2)
        XCTAssertFalse(recoveryAudio.ensureRunning())
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

        // 6. Cancelling an in-flight wait after it has actually suspended resolves immediately with .cancelled.
        let (enteredSleep, sleepEntered) = AsyncStream<Void>.makeStream()
        let (sleepCancelled, markSleepCancelled) = AsyncStream<Void>.makeStream()
        let cancelAudio = OpeningVoiceAudio(
            session: 4,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: { _ in
                sleepEntered.yield(())
                sleepEntered.finish()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    markSleepCancelled.yield(())
                    markSleepCancelled.finish()
                    throw CancellationError()
                }
            },
            isInputMuted: { false },
            isInBackground: { false }
        )
        let cancelWait = cancelAudio.startLiveInputWait()
        let inFlightTask = Task { @MainActor in
            await cancelAudio.awaitLiveInputWait(cancelWait, timeout: .seconds(60))
        }
        for await _ in enteredSleep {}
        await Task.yield()
        inFlightTask.cancel()
        let inFlightCancelled = await inFlightTask.value
        XCTAssertEqual(inFlightCancelled, .cancelled)
        for await _ in sleepCancelled {}
    }
}
