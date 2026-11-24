import AudioToolbox
import AVFoundation
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

    private final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval

        init(_ initial: TimeInterval) {
            value = initial
        }

        var now: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }

        func read() -> TimeInterval {
            lock.withLock { value }
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ initial: Value) {
            value = initial
        }

        func get() -> Value {
            lock.withLock { value }
        }

        func set(_ newValue: Value) {
            lock.withLock { value = newValue }
        }
    }

    private final class TestSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiters: [(id: UUID, target: Int, continuation: CheckedContinuation<Bool, Never>)] = []

        func signal() {
            let waking: [CheckedContinuation<Bool, Never>] = lock.withLock {
                count += 1
                let current = count
                let ready = waiters.filter { current >= $0.target }.map(\.continuation)
                waiters.removeAll { current >= $0.target }
                return ready
            }
            for continuation in waking {
                continuation.resume(returning: true)
            }
        }

        func wait(
            count target: Int = 1,
            timeout: Duration = .seconds(5),
            description: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Bool {
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired: CheckedContinuation<Bool, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                expired?.resume(returning: false)
            }
            let arrived = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    enum Registration { case immediate(Bool), registered }
                    let outcome: Registration = lock.withLock {
                        if count >= target { return .immediate(true) }
                        if Task.isCancelled { return .immediate(false) }
                        waiters.append((waiterID, target, continuation))
                        return .registered
                    }
                    if case .immediate(let result) = outcome {
                        continuation.resume(returning: result)
                    }
                }
            } onCancel: { [weak self] in
                guard let self else { return }
                let cancelled: CheckedContinuation<Bool, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                cancelled?.resume(returning: false)
            }
            timeoutTask.cancel()
            if !arrived {
                XCTFail("Timed out waiting for \(description) (target \(target))", file: file, line: line)
            }
            return arrived
        }
    }

    private final class TestEventQueue<Element: Sendable>: @unchecked Sendable {
        private enum Registration {
            case immediate(Element?)
            case registered
        }

        private let lock = NSLock()
        private var buffered: [Element] = []
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Element?, Never>)] = []

        func push(_ element: Element) {
            let waiter: CheckedContinuation<Element?, Never>? = lock.withLock {
                if !waiters.isEmpty {
                    return waiters.removeFirst().continuation
                }
                buffered.append(element)
                return nil
            }
            waiter?.resume(returning: element)
        }

        func next(
            timeout: Duration = .seconds(5),
            description: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Element? {
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired: CheckedContinuation<Element?, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                expired?.resume(returning: nil)
            }
            let event = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                    let outcome: Registration = lock.withLock {
                        if !buffered.isEmpty {
                            return .immediate(buffered.removeFirst())
                        }
                        if Task.isCancelled {
                            return .immediate(nil)
                        }
                        waiters.append((waiterID, continuation))
                        return .registered
                    }
                    if case .immediate(let result) = outcome {
                        continuation.resume(returning: result)
                    }
                }
            } onCancel: { [weak self] in
                guard let self else { return }
                let cancelled: CheckedContinuation<Element?, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                cancelled?.resume(returning: nil)
            }
            timeoutTask.cancel()
            if event == nil {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
            }
            return event
        }
    }

    private final class ControllableSleep: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private let startedSignal = TestSignal()
        private let cancelledSignal = TestSignal()

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let alreadyCancelled: Bool = lock.withLock {
                        if Task.isCancelled { return true }
                        waiters[id] = continuation
                        return false
                    }
                    startedSignal.signal()
                    if alreadyCancelled {
                        cancelledSignal.signal()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: { [weak self] in
                guard let self else { return }
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                if let waiter {
                    self.cancelledSignal.signal()
                    waiter.resume(throwing: CancellationError())
                }
            }
        }

        func waitForSleepStarted(
            count: Int = 1,
            timeout: Duration = .seconds(5),
            description: String = "controllable sleep start",
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Bool {
            await startedSignal.wait(count: count, timeout: timeout, description: description, file: file, line: line)
        }

        func waitForSleepCancelled(
            count: Int = 1,
            timeout: Duration = .seconds(5),
            description: String = "controllable sleep cancellation",
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Bool {
            await cancelledSignal.wait(count: count, timeout: timeout, description: description, file: file, line: line)
        }

        func releaseAll() {
            let pending = lock.withLock {
                let values = Array(waiters.values)
                waiters.removeAll()
                return values
            }
            for waiter in pending {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    private func awaitTask<T: Sendable>(
        _ task: Task<T, Never>,
        timeout: Duration = .seconds(5),
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> T? {
        let done = TestSignal()
        let resultBox = LockedBox<T?>(nil)
        let watcher = Task {
            resultBox.set(await task.value)
            done.signal()
        }
        defer { watcher.cancel() }
        guard await done.wait(timeout: timeout, description: description, file: file, line: line) else {
            task.cancel()
            return nil
        }
        return resultBox.get()
    }

    @MainActor
    func testExpiredBackgroundGrantPreservesRunningAudioUnitAcrossEveryTriggerAndForegroundRecovers() async throws {
        let session = RTCAudioSession.sharedInstance()
        let center = NotificationCenter()
        let clock = LockedClock(500.0)
        var inBackground = true
        var stopUnitOnNextQuery = false
        var simulateSelfRecoveryOnFollowUpQuery = false
        var overrideRunState: OpeningVoiceAudio.AudioUnitRunState?
        let lifecycleEvents = TestEventQueue<OpeningAudioRecoveryPolicy.RestartTrigger>()

        let probe = DelegateProbe()
        let audio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: { clock.read() },
            isInputMuted: { false },
            isInBackground: { inBackground },
            queryAudioUnitRunState: { unit in
                if let overrideRunState {
                    return overrideRunState
                }
                if stopUnitOnNextQuery {
                    stopUnitOnNextQuery = false
                    let stopStatus = AudioOutputUnitStop(unit)
                    XCTAssertEqual(stopStatus, noErr, "AudioOutputUnitStop must stop the real VPIO unit")
                    return OpeningVoiceAudio.queryCoreAudioRunState(unit)
                }
                if simulateSelfRecoveryOnFollowUpQuery {
                    return .running
                }
                return OpeningVoiceAudio.queryCoreAudioRunState(unit)
            },
            onLifecycleHandled: { trigger in
                lifecycleEvents.push(trigger)
            }
        )
        XCTAssertTrue(audio.initialize(with: probe))
        XCTAssertTrue(audio.initializeRecording())
        XCTAssertTrue(audio.startRecording())
        XCTAssertTrue(audio.allowSending(session: 1))
        try audio.startCapture()
        defer { _ = audio.stopCapture(session: 1) }

        let initialGeneration = try XCTUnwrap(audio.activeAudioUnitGeneration)
        XCTAssertTrue(audio.ensureRunning(), "startCapture must leave real VPIO running")
        XCTAssertTrue(session.isActive)
        let initialCallback = await probe.waitForRecordedCallback(after: 0)
        XCTAssertGreaterThan(initialCallback, 0)

        // Install grant expiring at 503.5 and advance monotonic clock past deadline.
        audio.setBackgroundRecordingGrant(BackgroundRecordingGrant(token: UUID(), deadline: 503.5))
        clock.now = 503.6

        // Entry 1: spatial playback capabilities changed (asynchronously isolated onto MainActor).
        let spatialMarker = addLogMarker("spatial-expired")
        center.post(name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        let handledSpatial = await lifecycleEvents.next(timeout: .seconds(5), description: "spatial notification completion")
        XCTAssertEqual(handledSpatial, .spatialCapabilitiesChanged)
        let spatialLogs = logs(after: spatialMarker)
        XCTAssertTrue(
            spatialLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for spatial playback capabilities changed: background recording grant expired; keeping existing unit") }),
            "Spatial notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(spatialLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(audio.activeAudioUnitGeneration, initialGeneration)
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        XCTAssertTrue(session.isActive)
        let spatialBaseline = probe.recordedCallbackCount
        let spatialNext = await probe.waitForRecordedCallback(after: spatialBaseline)
        XCTAssertGreaterThan(spatialNext, spatialBaseline)

        // Entry 2: audio session interruption ended (asynchronously isolated onto MainActor).
        let interruptionMarker = addLogMarker("interruption-expired")
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let handledInterruption = await lifecycleEvents.next(timeout: .seconds(5), description: "interruption notification completion")
        XCTAssertEqual(handledInterruption, .interruptionEnded)
        let interruptionLogs = logs(after: interruptionMarker)
        XCTAssertTrue(
            interruptionLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for interruption ended: background recording grant expired; keeping existing unit") }),
            "Interruption-ended notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(interruptionLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(audio.activeAudioUnitGeneration, initialGeneration)
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        let interruptionBaseline = probe.recordedCallbackCount
        let interruptionNext = await probe.waitForRecordedCallback(after: interruptionBaseline)
        XCTAssertGreaterThan(interruptionNext, interruptionBaseline)

        // Entry 3: media services were reset (asynchronously isolated onto MainActor).
        let resetMarker = addLogMarker("reset-expired")
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let handledReset = await lifecycleEvents.next(timeout: .seconds(5), description: "media services reset completion")
        XCTAssertEqual(handledReset, .mediaServicesReset)
        let resetLogs = logs(after: resetMarker)
        XCTAssertTrue(
            resetLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for media services reset: background recording grant expired; keeping existing unit") }),
            "Media-services-reset notification after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(resetLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(audio.activeAudioUnitGeneration, initialGeneration)
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)
        XCTAssertTrue(audio.ensureRunning())
        let resetBaseline = probe.recordedCallbackCount
        let resetNext = await probe.waitForRecordedCallback(after: resetBaseline)
        XCTAssertGreaterThan(resetNext, resetBaseline)

        // Entry 4a: ensureRunning() sees a genuinely stopped CoreAudio VPIO unit while grant is expired.
        // Even if a follow-up query would report .running (simulated platform self-recovery), ensureRunning()
        // must return false directly upon restart rejection without tearing down or replacing the existing unit.
        let ensureExpiredMarker = addLogMarker("ensure-expired")
        stopUnitOnNextQuery = true
        simulateSelfRecoveryOnFollowUpQuery = true
        XCTAssertFalse(
            audio.ensureRunning(),
            "ensureRunning must return false directly when background grant rejects restart, even if a follow-up query would report running"
        )
        simulateSelfRecoveryOnFollowUpQuery = false
        let ensureExpiredLogs = logs(after: ensureExpiredMarker)
        XCTAssertTrue(
            ensureExpiredLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for ensureRunning: background recording grant expired; keeping existing unit") }),
            "ensureRunning after grant expiry must log its own skip decision"
        )
        XCTAssertFalse(ensureExpiredLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(audio.activeAudioUnitGeneration, initialGeneration, "Expired ensureRunning must preserve the existing AudioUnit generation")
        XCTAssertEqual(probe.inputInterruptedCount, 0)
        XCTAssertEqual(probe.outputInterruptedCount, 0)

        // Entry 4b: moving to foreground allows ensureRunning() to recover the real stopped VPIO unit.
        inBackground = false
        let ensureForegroundMarker = addLogMarker("ensure-foreground")
        XCTAssertTrue(audio.ensureRunning(), "Foreground ensureRunning must restart a stopped VPIO unit and report running")
        let fgEnsureGeneration = try XCTUnwrap(audio.activeAudioUnitGeneration)
        XCTAssertGreaterThan(fgEnsureGeneration, initialGeneration, "Foreground ensureRunning must advance AudioUnit generation")
        let ensureForegroundLogs = logs(after: ensureForegroundMarker)
        XCTAssertTrue(ensureForegroundLogs.contains(where: { $0.contains("opening audio unit restarted after ensureRunning") }))
        XCTAssertTrue(ensureForegroundLogs.contains(where: { $0.contains("opening audio unit started:") }))
        XCTAssertEqual(probe.inputInterruptedCount, 1)
        XCTAssertEqual(probe.outputInterruptedCount, 1)
        XCTAssertTrue(session.isActive)
        let fgEnsureBaseline = probe.recordedCallbackCount
        let fgEnsureNext = await probe.waitForRecordedCallback(after: fgEnsureBaseline)
        XCTAssertGreaterThan(fgEnsureNext, fgEnsureBaseline)

        // Entry 4c: unknown CoreAudio status (status != noErr) must return false WITHOUT tearing down the running unit.
        let ensureUnknownMarker = addLogMarker("ensure-unknown")
        overrideRunState = .unknown(kAudioUnitErr_Uninitialized)
        XCTAssertFalse(audio.ensureRunning(), "Unknown CoreAudio run state must return false instead of reporting healthy")
        overrideRunState = nil
        let ensureUnknownLogs = logs(after: ensureUnknownMarker)
        XCTAssertTrue(ensureUnknownLogs.contains(where: { $0.contains("could not query VPIO state") && $0.contains("\(kAudioUnitErr_Uninitialized)") }))
        XCTAssertFalse(ensureUnknownLogs.contains(where: { $0.contains("opening audio unit started:") || $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(audio.activeAudioUnitGeneration, fgEnsureGeneration, "Unknown run state must preserve the existing AudioUnit generation")
        XCTAssertEqual(probe.inputInterruptedCount, 1, "Unknown run state must preserve the existing AudioUnit")
        XCTAssertTrue(audio.ensureRunning(), "Existing VPIO unit must still be running after an unknown-state query")
        let unknownBaseline = probe.recordedCallbackCount
        let unknownNext = await probe.waitForRecordedCallback(after: unknownBaseline)
        XCTAssertGreaterThan(unknownNext, unknownBaseline)

        // Foreground lifecycle notifications replace the real VPIO unit asynchronously and notify WebRTC.
        let fgInterruptionMarker = addLogMarker("fg-interruption")
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let handledFgInterruption = await lifecycleEvents.next(timeout: .seconds(5), description: "foreground interruption completion")
        XCTAssertEqual(handledFgInterruption, .interruptionEnded)
        let fgInterruptionLogs = logs(after: fgInterruptionMarker)
        XCTAssertTrue(fgInterruptionLogs.contains(where: { $0.contains("opening audio unit restarted after interruption ended") }))
        let fgInterruptionGeneration = try XCTUnwrap(audio.activeAudioUnitGeneration)
        XCTAssertGreaterThan(fgInterruptionGeneration, fgEnsureGeneration)
        XCTAssertEqual(probe.inputInterruptedCount, 2)
        XCTAssertTrue(audio.ensureRunning())
        let fgInterruptionBaseline = probe.recordedCallbackCount
        let fgInterruptionNext = await probe.waitForRecordedCallback(after: fgInterruptionBaseline)
        XCTAssertGreaterThan(fgInterruptionNext, fgInterruptionBaseline)

        let fgResetMarker = addLogMarker("fg-reset")
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let handledFgReset = await lifecycleEvents.next(timeout: .seconds(5), description: "foreground media services reset completion")
        XCTAssertEqual(handledFgReset, .mediaServicesReset)
        let fgResetLogs = logs(after: fgResetMarker)
        XCTAssertTrue(fgResetLogs.contains(where: { $0.contains("opening audio unit restarted after media services reset") }))
        let fgResetGeneration = try XCTUnwrap(audio.activeAudioUnitGeneration)
        XCTAssertGreaterThan(fgResetGeneration, fgInterruptionGeneration)
        XCTAssertEqual(probe.inputInterruptedCount, 3)
        XCTAssertTrue(audio.ensureRunning())
        let fgResetBaseline = probe.recordedCallbackCount
        let fgResetNext = await probe.waitForRecordedCallback(after: fgResetBaseline)
        XCTAssertGreaterThan(fgResetNext, fgResetBaseline)

        _ = audio.stopCapture(session: 1)
        XCTAssertNil(audio.activeAudioUnitGeneration)
        XCTAssertFalse(audio.ensureRunning())
        XCTAssertFalse(session.isActive, "stopCapture must balance all RTCAudioSession activations including real restarts")
    }

    private final class GenerationRenderTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var initialGeneration: UInt64?
        private var generations: Set<UInt64> = []
        private var waiters: [(id: UUID, after: UInt64, continuation: CheckedContinuation<UInt64?, Never>)] = []

        func record(_ generation: UInt64) -> Bool {
            let (isInitial, waking): (Bool, [CheckedContinuation<UInt64?, Never>]) = lock.withLock {
                if initialGeneration == nil {
                    initialGeneration = generation
                }
                generations.insert(generation)
                let ready = waiters.filter { generation > $0.after }.map(\.continuation)
                waiters.removeAll { generation > $0.after }
                return (generation == initialGeneration, ready)
            }
            for continuation in waking {
                continuation.resume(returning: generation)
            }
            return isInitial
        }

        var observedGenerations: Set<UInt64> {
            lock.withLock { generations }
        }

        func waitForGeneration(
            greaterThan prior: UInt64,
            timeout: Duration = .seconds(5),
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> UInt64? {
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired: CheckedContinuation<UInt64?, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                expired?.resume(returning: nil)
            }
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
                    enum Registration { case immediate(UInt64?), registered }
                    let outcome: Registration = lock.withLock {
                        if let existing = generations.filter({ $0 > prior }).max() {
                            return .immediate(existing)
                        }
                        if Task.isCancelled {
                            return .immediate(nil)
                        }
                        waiters.append((waiterID, prior, continuation))
                        return .registered
                    }
                    if case .immediate(let found) = outcome {
                        continuation.resume(returning: found)
                    }
                }
            } onCancel: { [weak self] in
                guard let self else { return }
                let cancelled: CheckedContinuation<UInt64?, Never>? = self.lock.withLock {
                    guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return self.waiters.remove(at: index).continuation
                }
                cancelled?.resume(returning: nil)
            }
            timeoutTask.cancel()
            if result == nil {
                XCTFail("Timed out waiting for render callback on AudioUnit generation > \(prior)", file: file, line: line)
            }
            return result
        }
    }

    @MainActor
    func testSustainedZeroInputThroughRealVPIOSkipsWhenGrantExpiredAndRecoversInForeground() async throws {
        let session = RTCAudioSession.sharedInstance()
        let center = NotificationCenter()
        let clock = LockedClock(500.0)

        // Part 1: Sustained zero input from real VPIO AudioUnitRender with expired background grant
        // skips restart and keeps the exact same generation delivering callbacks, independent of host room noise.
        let expiredTracker = GenerationRenderTracker()
        let expiredEvents = TestEventQueue<OpeningAudioRecoveryPolicy.RestartTrigger>()
        let expiredProbe = DelegateProbe()
        let expiredAudio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: { clock.read() },
            isInputMuted: { false },
            isInBackground: { true },
            renderAudioUnitInput: { unit, generation, flags, timestamp, bus, frames, bufferList in
                let status = OpeningVoiceAudio.renderCoreAudioInput(unit, flags, timestamp, bus, frames, bufferList)
                guard status == noErr else { return status }
                _ = expiredTracker.record(generation)
                if let data = bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    data.update(repeating: 0, count: Int(frames))
                }
                return noErr
            },
            onLifecycleHandled: { trigger in
                expiredEvents.push(trigger)
            }
        )
        expiredAudio.setBackgroundRecordingGrant(BackgroundRecordingGrant(token: UUID(), deadline: 503.5))
        clock.now = 503.6
        XCTAssertTrue(expiredAudio.initialize(with: expiredProbe))
        XCTAssertTrue(expiredAudio.initializeRecording())
        XCTAssertTrue(expiredAudio.startRecording())
        XCTAssertTrue(expiredAudio.allowSending(session: 1))
        let expiredMarker = addLogMarker("sustained-zero-expired")
        try expiredAudio.startCapture()
        defer { _ = expiredAudio.stopCapture(session: 1) }

        let expiredInitialGeneration = try XCTUnwrap(expiredAudio.activeAudioUnitGeneration)
        let expiredTrigger = await expiredEvents.next(timeout: .seconds(6), description: "expired sustained zero-input lifecycle completion")
        XCTAssertEqual(expiredTrigger, .sustainedZeroInput(attempt: 1))
        let expiredLogs = logs(after: expiredMarker)
        XCTAssertTrue(
            expiredLogs.contains(where: { $0.contains("opening audio skipped VPIO restart for sustained zero input (#1): background recording grant expired; keeping existing unit") })
        )
        XCTAssertFalse(expiredLogs.contains(where: { $0.contains("opening audio unit restarted") }))
        XCTAssertEqual(expiredAudio.activeAudioUnitGeneration, expiredInitialGeneration)
        XCTAssertEqual(expiredProbe.inputInterruptedCount, 0)
        XCTAssertEqual(expiredProbe.outputInterruptedCount, 0)
        XCTAssertTrue(expiredAudio.ensureRunning())
        let callbackAfterSkip = expiredProbe.recordedCallbackCount
        let nextCallbackAfterSkip = await expiredProbe.waitForRecordedCallback(after: callbackAfterSkip, timeout: .seconds(5))
        XCTAssertGreaterThan(nextCallbackAfterSkip, callbackAfterSkip)
        XCTAssertEqual(expiredTracker.observedGenerations, [expiredInitialGeneration], "Expired sustained zero input must keep rendering on the original AudioUnit generation")

        _ = expiredAudio.stopCapture(session: 1)
        XCTAssertNil(expiredAudio.activeAudioUnitGeneration)
        XCTAssertFalse(expiredAudio.ensureRunning())
        XCTAssertFalse(session.isActive)

        // Part 2: Sustained zero input from an already-running real VPIO unit in foreground
        // clears the stale 72,000-frame zero buffer, replaces the running VPIO unit with a new generation,
        // and resumes callbacks on the new generation.
        let recoveryTracker = GenerationRenderTracker()
        let recoveryEvents = TestEventQueue<OpeningAudioRecoveryPolicy.RestartTrigger>()
        let recoveryProbe = DelegateProbe()
        let recoveryAudio = OpeningVoiceAudio(
            session: 2,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            notificationCenter: center,
            uptime: { clock.read() },
            isInputMuted: { false },
            isInBackground: { false },
            renderAudioUnitInput: { unit, generation, flags, timestamp, bus, frames, bufferList in
                let status = OpeningVoiceAudio.renderCoreAudioInput(unit, flags, timestamp, bus, frames, bufferList)
                guard status == noErr else { return status }
                if recoveryTracker.record(generation),
                   let data = bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                    data.update(repeating: 0, count: Int(frames))
                }
                return noErr
            },
            onLifecycleHandled: { trigger in
                recoveryEvents.push(trigger)
            }
        )
        XCTAssertTrue(recoveryAudio.initialize(with: recoveryProbe))
        XCTAssertTrue(recoveryAudio.initializeRecording())
        XCTAssertTrue(recoveryAudio.startRecording())
        let recoveryMarker = addLogMarker("sustained-zero-foreground")
        try recoveryAudio.startCapture()
        defer { _ = recoveryAudio.stopCapture(session: 2) }

        let recoveryInitialGeneration = try XCTUnwrap(recoveryAudio.activeAudioUnitGeneration)
        let recoveryTrigger = await recoveryEvents.next(timeout: .seconds(6), description: "foreground sustained zero-input lifecycle completion")
        XCTAssertEqual(recoveryTrigger, .sustainedZeroInput(attempt: 1))
        let interruptedCount = await recoveryProbe.waitForInputInterrupted(after: 0, timeout: .seconds(5))
        XCTAssertEqual(interruptedCount, 1)
        let recoveredGeneration = try XCTUnwrap(recoveryAudio.activeAudioUnitGeneration)
        XCTAssertGreaterThan(recoveredGeneration, recoveryInitialGeneration, "Foreground sustained zero-input recovery must advance AudioUnit generation")
        let recoveryLogs = logs(after: recoveryMarker)
        XCTAssertTrue(
            recoveryLogs.contains(where: { $0.contains("opening audio unit restarted after sustained zero input (#1)") }),
            "Sustained zero input from real VPIO in foreground must replace the running audio unit"
        )
        XCTAssertTrue(recoveryAudio.ensureRunning())
        XCTAssertLessThan(recoveryAudio.bufferedFrameCount, 72_000, "Real zero-input recovery while buffering must clear the stale 72,000-frame zero prefix")

        XCTAssertTrue(recoveryAudio.allowSending(session: 2))
        let postRecoveryBaseline = recoveryProbe.recordedCallbackCount
        let postRecoveryCallbacks = await recoveryProbe.waitForRecordedCallback(after: postRecoveryBaseline, timeout: .seconds(5))
        XCTAssertGreaterThan(postRecoveryCallbacks, postRecoveryBaseline, "Replaced VPIO unit must continue delivering real AudioUnitRender callbacks")
        let renderedReplacement = await recoveryTracker.waitForGeneration(greaterThan: recoveryInitialGeneration, timeout: .seconds(5))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(renderedReplacement), recoveredGeneration, "Real AudioUnitRender callbacks after recovery must come from the new AudioUnit generation")

        _ = recoveryAudio.stopCapture(session: 2)
        XCTAssertNil(recoveryAudio.activeAudioUnitGeneration)
        XCTAssertFalse(recoveryAudio.ensureRunning())
        XCTAssertFalse(session.isActive, "stopCapture must release RTCAudioSession after sustained zero-input restart")
    }

    @MainActor
    func testWaitForLiveInputDeterministicWakeupTimeoutStopAndCancellation() async throws {
        var muted = false
        let sharedSleep = ControllableSleep()
        defer { sharedSleep.releaseAll() }
        let audio = OpeningVoiceAudio(
            session: 1,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: { try await sharedSleep.sleep($0) },
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
        let cancelledFastPath = await awaitTask(cancelledTask, timeout: .seconds(5), description: "already-cancelled fast path")
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

        // 5. stopCapture releases a registered waiter immediately with .stopped (never via timeout).
        let stopSleep = ControllableSleep()
        defer { stopSleep.releaseAll() }
        let stoppedAudio = OpeningVoiceAudio(
            session: 3,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: { try await stopSleep.sleep($0) },
            isInputMuted: { false },
            isInBackground: { false }
        )
        let stopWait = stoppedAudio.startLiveInputWait()
        _ = stoppedAudio.stopCapture(session: 3)
        let stoppedResult = await stoppedAudio.awaitLiveInputWait(stopWait, timeout: .seconds(60))
        XCTAssertEqual(stoppedResult, .stopped, "stopCapture must wake waiters immediately with .stopped")

        // 6. Cancelling an in-flight wait after it has suspended resolves with .cancelled and cancels its timeout task within a finite deadline.
        let cancelSleep = ControllableSleep()
        defer { cancelSleep.releaseAll() }
        let cancelAudio = OpeningVoiceAudio(
            session: 4,
            playReadyChime: false,
            zeroInputRecoveryEnabled: true,
            sleep: { try await cancelSleep.sleep($0) },
            isInputMuted: { false },
            isInBackground: { false }
        )
        let cancelWait = cancelAudio.startLiveInputWait()
        let inFlightTask = Task { @MainActor in
            await cancelAudio.awaitLiveInputWait(cancelWait, timeout: .seconds(60))
        }
        let enteredSleep = await cancelSleep.waitForSleepStarted(timeout: .seconds(5), description: "timeout sleep entry")
        XCTAssertTrue(enteredSleep)
        inFlightTask.cancel()
        let inFlightCancelled = await awaitTask(inFlightTask, timeout: .seconds(5), description: "in-flight live input wait cancellation")
        XCTAssertEqual(inFlightCancelled, .cancelled)
        let timeoutTaskCancelled = await cancelSleep.waitForSleepCancelled(timeout: .seconds(5), description: "timeout task cancellation")
        XCTAssertTrue(timeoutTaskCancelled, "Cancelling an in-flight wait must cancel its companion timeout task")
    }
}
