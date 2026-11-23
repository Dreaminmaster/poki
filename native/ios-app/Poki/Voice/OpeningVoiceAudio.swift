import AudioToolbox
import AVFoundation
import Foundation
import WebRTC

@MainActor
struct OpeningVoiceCapture {
    let audio: OpeningVoiceAudio
    let factory: RTCPeerConnectionFactory

    init(audio: OpeningVoiceAudio) {
        self.audio = audio
        factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
    }
}

/// Captures opening speech before WebRTC connects and feeds the same voice-processed engine
/// into WebRTC once ready, keeping a bounded recovery timeline for disconnect fallback.
final class OpeningVoiceAudio: NSObject, RTCAudioDevice, @unchecked Sendable {
    enum RecoveryKind: Equatable {
        case fullOpening
        case unconfirmedTail
    }

    struct RecoveryPlan {
        let kind: RecoveryKind
        let hasUncertainEarlierAudio: Bool
        let finished: AsyncStream<Void>
    }

    enum RecoveryOutcome {
        case dictation(RecoveryPlan)
        case uncertainPrefixUsed
        case confirmed
    }

    private static let sampleRate = 48_000.0
    private static let framesPerMillisecond = Int(sampleRate / 1_000)
    private static let deliveryChunkFrames = 480
    private static let maxFramesPerSlice: UInt32 = 4_096
    // Covers two connection attempts plus fallback dictation without unbounded memory growth.
    static let maxOpeningFrames = Int(sampleRate) * 180
    private static let channelFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private static let pcm16StreamDescription = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )

    @MainActor private var audioUnit: AudioComponentInstance?
    @MainActor private var audioUnitRunning = false
    @MainActor private var holdsAudioSession = false
    @MainActor private var interruptionObserver: NSObjectProtocol?
    @MainActor private var resetObserver: NSObjectProtocol?
    private let lock = NSLock()
    // Revocation waits only for a delivery already in progress; WebRTC is never called under `lock`.
    private let sendLock = NSLock()
    private let session: Int
    private var callbackAudioUnit: AudioComponentInstance?

    private enum State {
        case buffering
        case sending
        case waitingForOwner(AsyncStream<Void>.Continuation)
        case readyForDictation
        case stopped
    }

    private enum PlayoutSource {
        case chime(Range<Int>)
        case webrtc(RTCAudioDeviceDelegate)
        case silence
    }

    private enum Delivery {
        case none
        case live(RTCAudioDeviceDelegate)
        case queued(RTCAudioDeviceDelegate, [Int16])
    }

    private var delegate: RTCAudioDeviceDelegate?
    private var recording = false
    private var playing = false
    private var recordingInitialized = false
    private var playoutInitialized = false
    private var state = State.buffering
    private var chimeOffset = 0
    private var overflow = false
    private var queued: [Int16] = []
    private var readIndex = 0
    private var recovery: [Int16] = []
    private var recoveryOverflow = false
    private var openingEndFrame = 0
    private var lastNonZeroOpeningFrame = 0
    private var deliveredFrames = 0
    private var deliveredSampleTime = 0.0
    private var confirmedFrames = 0
    private var phoneActionStarted = false
    private var remoteReplied = false
    private var openingConfirmed = false
    private var tapCallbacks = 0
    private var nonZeroTapCallbacks = 0
    private var rawNonZeroTapCallbacks = 0
    private var rawMaxPeak: Float = 0
    private var renderErrors = 0
    private var deliveryErrors = 0

    let deviceInputSampleRate = OpeningVoiceAudio.sampleRate
    let deviceOutputSampleRate = OpeningVoiceAudio.sampleRate
    let inputNumberOfChannels = 1
    let outputNumberOfChannels = 1
    let inputIOBufferDuration = 0.01
    let outputIOBufferDuration = 0.01
    let inputLatency: TimeInterval = 0
    let outputLatency: TimeInterval = 0
    var isInitialized: Bool { lock.withLock { delegate != nil } }
    var isRecordingInitialized: Bool { lock.withLock { recordingInitialized } }
    var isPlayoutInitialized: Bool { lock.withLock { playoutInitialized } }
    var isRecording: Bool { lock.withLock { recording } }
    var isPlaying: Bool { lock.withLock { playing } }
    var bufferedDuration: Duration {
        lock.withLock { .seconds(Double(queued.count - readIndex) / Self.sampleRate) }
    }
    var bufferedFrameCount: Int {
        lock.withLock { queued.count - readIndex }
    }
    var hasOverflowed: Bool {
        lock.withLock { overflow }
    }

    init(session: Int, playReadyChime: Bool = true) {
        self.session = session
        chimeOffset = playReadyChime ? 0 : VoiceOpeningFeedback.readyChime.count
        super.init()
    }

    deinit {
        if let unit = lock.withLock({ () -> AudioComponentInstance? in
            let current = callbackAudioUnit
            callbackAudioUnit = nil
            return current
        }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    @MainActor func startCapture() throws {
        try VoiceLink.activateAudioSession(configure: true)
        holdsAudioSession = true
        do {
            try configureAndStartAudioUnit()
            observeAudioLifecycle()
        } catch {
            removeAudioLifecycleObservers()
            stopAudioUnit()
            if holdsAudioSession {
                holdsAudioSession = false
                VoiceLink.deactivateAudioSession()
            }
            throw error
        }
    }

    @MainActor func ensureRunning() -> Bool {
        guard audioUnit != nil || audioUnitRunning else { return false }
        if !audioUnitRunning {
            restartAudioUnit(reason: "ensureRunning")
        }
        return audioUnitRunning && RTCAudioSession.sharedInstance().isActive
    }

    @MainActor private func configureAndStartAudioUnit() throws {
        stopAudioUnit()
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            Self.logVoice("opening audio unit failed: VoiceProcessingIO component not found")
            throw VoiceError.noWebRTC
        }
        var created: AudioComponentInstance?
        let newStatus = AudioComponentInstanceNew(component, &created)
        guard newStatus == noErr, let unit = created else {
            Self.logVoice("opening audio unit failed: AudioComponentInstanceNew (\(newStatus))")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(newStatus))
        }
        do {
            try setupAudioUnit(unit)
            lock.withLock { callbackAudioUnit = unit }
            let startStatus = AudioOutputUnitStart(unit)
            guard startStatus == noErr else {
                lock.withLock { callbackAudioUnit = nil }
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(startStatus), userInfo: [
                    NSLocalizedDescriptionKey: "AudioOutputUnitStart failed (\(startStatus))",
                ])
            }
            audioUnit = unit
            audioUnitRunning = true
            let session = AVAudioSession.sharedInstance()
            Self.logVoice("opening audio unit started: 48000 Hz 1 ch Int16 VPIO, sessionRate=\(Int(session.sampleRate)), inputCh=\(session.inputNumberOfChannels), muted=\(AVAudioApplication.shared.isInputMuted)")
        } catch {
            lock.withLock { callbackAudioUnit = nil }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            Self.logVoice("opening audio unit start failed: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor private func setupAudioUnit(_ unit: AudioComponentInstance) throws {
        func check(_ status: OSStatus, _ step: String) throws {
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "VPIO \(step) failed (\(status))",
                ])
            }
        }
        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)), "enableInput")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)), "enableOutput")

        var zero: UInt32 = 0
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
        _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_MuteOutput, kAudioUnitScope_Global, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

        var format = Self.pcm16StreamDescription
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize), "inputStreamFormat")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize), "outputStreamFormat")

        var maxFrames = Self.maxFramesPerSlice
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var inputCallback = AURenderCallbackStruct(inputProc: openingAudioInputCallback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "setInputCallback")

        var playoutCallback = AURenderCallbackStruct(inputProc: openingAudioPlayoutCallback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &playoutCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "setRenderCallback")

        try check(AudioUnitInitialize(unit), "initialize")
    }

    @MainActor private func stopAudioUnit() {
        let unit = audioUnit
        audioUnit = nil
        audioUnitRunning = false
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        lock.withLock { callbackAudioUnit = nil }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    @MainActor private func observeAudioLifecycle() {
        removeAudioLifecycleObservers()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.restartAudioUnit(reason: "interruption ended") }
        }
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAudioUnit(reason: "media services reset") }
        }
    }

    @MainActor private func removeAudioLifecycleObservers() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        interruptionObserver = nil
        resetObserver = nil
    }

    @MainActor private func restartAudioUnit(reason: String) {
        let stopped: Bool = lock.withLock {
            if case .stopped = state { return true }
            return false
        }
        guard !stopped else { return }
        stopAudioUnit()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try configureAndStartAudioUnit()
            Self.logVoice("opening audio unit restarted after \(reason)")
            let currentDelegate = lock.withLock { delegate }
            currentDelegate?.dispatchAsync {
                currentDelegate?.notifyAudioInputInterrupted()
                currentDelegate?.notifyAudioOutputInterrupted()
            }
        } catch {
            Self.logVoice("opening audio unit restart failed after \(reason): \(error.localizedDescription)")
        }
    }

    func allowSending(session: Int) -> Bool {
        let result: (allowed: Bool, summary: String?) = lock.withLock {
            guard session == self.session, !overflow else { return (false, nil) }
            switch state {
            case .buffering:
                recovery = queued
                openingEndFrame = queued.count
                state = .sending
                let seconds = String(format: "%.2f", Double(queued.count) / Self.sampleRate)
                let peak = String(format: "%.5f", rawMaxPeak)
                let summary = "opening audio handoff: queued \(queued.count) frames (\(seconds) s), taps \(tapCallbacks), nonZeroTaps \(nonZeroTapCallbacks), rawNonZero \(rawNonZeroTapCallbacks), rawPeak \(peak), renderErrors \(renderErrors), deliveryErrors \(deliveryErrors)"
                return (true, summary)
            case .sending:
                return (true, nil)
            case .waitingForOwner, .readyForDictation, .stopped:
                return (false, nil)
            }
        }
        if let summary = result.summary { Self.logVoice(summary) }
        return result.allowed
    }

    func confirmRemoteAudio(session: Int, endMilliseconds: Int) {
        guard endMilliseconds > 0 else { return }
        lock.withLock {
            guard session == self.session, case .sending = state, deliveredFrames > 0 else { return }
            let frames = min(deliveredFrames, endMilliseconds * Self.framesPerMillisecond)
            confirmedFrames = max(confirmedFrames, frames)
            evaluateOpeningConfirmedLocked()
        }
    }

    func markRemoteReplied(session: Int) {
        lock.withLock {
            guard session == self.session, case .sending = state, deliveredFrames > 0 else { return }
            remoteReplied = true
            evaluateOpeningConfirmedLocked()
        }
    }

    func markPhoneActionStarted(session: Int) {
        lock.withLock {
            guard session == self.session, case .sending = state, deliveredFrames > 0 else { return }
            phoneActionStarted = true
            evaluateOpeningConfirmedLocked()
        }
    }

    func prepareForOwnerDictation(session: Int) -> RecoveryOutcome? {
        sendLock.withLock {
            lock.withLock {
                guard session == self.session else { return nil }
                let kind: RecoveryKind
                var hasUncertainEarlierAudio = false
                switch state {
                case .buffering:
                    guard !overflow else { return nil }
                    kind = .fullOpening
                case .sending:
                    evaluateOpeningConfirmedLocked()
                    guard !openingConfirmed else { return .confirmed }
                    guard !overflow, !recoveryOverflow else { return nil }
                    if confirmedFrames > 0, remoteReplied || phoneActionStarted {
                        let tailStart = min(confirmedFrames, deliveredFrames)
                        let hasUnconfirmedSpeech = tailStart < lastNonZeroOpeningFrame
                        let hasUnsentAudio = deliveredFrames < recovery.count
                        guard tailStart < recovery.count, hasUnconfirmedSpeech || hasUnsentAudio else { return .confirmed }
                        queued = Array(recovery[tailStart...])
                        kind = .unconfirmedTail
                    } else if phoneActionStarted || remoteReplied {
                        guard deliveredFrames < recovery.count else { return .uncertainPrefixUsed }
                        queued = Array(recovery[deliveredFrames...])
                        kind = .unconfirmedTail
                        hasUncertainEarlierAudio = true
                    } else {
                        queued = recovery
                        kind = .fullOpening
                    }
                    recovery.removeAll(keepingCapacity: false)
                    readIndex = 0
                case .waitingForOwner, .readyForDictation, .stopped:
                    return nil
                }
                let (finished, continuation) = AsyncStream<Void>.makeStream()
                state = .waitingForOwner(continuation)
                return .dictation(RecoveryPlan(kind: kind, hasUncertainEarlierAudio: hasUncertainEarlierAudio, finished: finished))
            }
        }
    }

    @discardableResult
    func finishForDictation(session: Int, discard: Bool = false) -> Bool {
        lock.withLock {
            guard session == self.session, case .waitingForOwner(let completion) = state else { return false }
            if discard { overflow = true }
            state = .readyForDictation
            completion.finish()
            return true
        }
    }

    /// Revokes the media callback immediately before stopping the engine or waiting for protocol close.
    @MainActor func stopCapture(session: Int, forDictation: Bool = false) -> AVAudioPCMBuffer? {
        guard session == self.session else { return nil }
        let stopped: (wasRunning: Bool, completeRecording: [Int16]?) = sendLock.withLock {
            lock.withLock {
                if case .stopped = state { return (false, nil) }
                let samples: [Int16]?
                if forDictation, case .readyForDictation = state, !overflow { samples = queued }
                else { samples = nil }
                let previous = state
                state = .stopped
                delegate = nil
                queued.removeAll()
                recovery.removeAll()
                readIndex = 0
                if case .waitingForOwner(let completion) = previous { completion.finish() }
                return (true, samples)
            }
        }
        guard stopped.wasRunning else { return nil }
        removeAudioLifecycleObservers()
        stopAudioUnit()
        if holdsAudioSession {
            holdsAudioSession = false
            VoiceLink.deactivateAudioSession()
        }
        guard let samples = stopped.completeRecording, !samples.isEmpty,
              let audio = AVAudioPCMBuffer(pcmFormat: Self.channelFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = audio.int16ChannelData?[0] else { return nil }
        audio.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: $0.count) }
        return audio
    }

    func handleAudioUnitInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let unit = lock.withLock({ callbackAudioUnit }) else { return noErr }
        let count = Int(inNumberFrames)
        guard count > 0 else { return noErr }
        return withUnsafeTemporaryAllocation(of: Int16.self, capacity: count) { storage in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(count * MemoryLayout<Int16>.stride),
                    mData: storage.baseAddress
                )
            )
            let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
            guard status == noErr else {
                let errCount = lock.withLock { () -> Int in
                    renderErrors += 1
                    return renderErrors
                }
                if errCount <= 3 || errCount % 100 == 0 {
                    Self.logVoice("opening audio unit render error (#\(errCount)): OSStatus \(status)")
                }
                return status
            }
            let samples = UnsafeBufferPointer(start: storage.baseAddress, count: count)
            var maxSample: Int32 = 0
            for sample in samples {
                let magnitude = abs(Int32(sample))
                if magnitude > maxSample { maxSample = magnitude }
            }
            let peak = Float(maxSample) / 32_768.0
            lock.withLock {
                tapCallbacks += 1
                if maxSample > 0 {
                    nonZeroTapCallbacks += 1
                    rawNonZeroTapCallbacks += 1
                }
                if peak > rawMaxPeak { rawMaxPeak = peak }
            }
            inputSamples(samples, timestamp: inTimeStamp.pointee)
            return noErr
        }
    }

    func handleAudioUnitPlayout(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData, let destination = ioData.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) else {
            return kAudio_ParamError
        }
        let count = Int(inNumberFrames)
        switch selectPlayoutSource(count: count) {
        case .chime(let range):
            let chime = VoiceOpeningFeedback.readyChime
            var write = 0
            for index in range {
                let scaled = max(-1.0 as Float, min(1.0 as Float, chime[index])) * 32_767.0
                destination[write] = Int16(scaled)
                write += 1
            }
            if write < count {
                destination.advanced(by: write).update(repeating: 0, count: count - write)
            }
            return noErr
        case .silence:
            ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            destination.update(repeating: 0, count: count)
            return noErr
        case .webrtc(let delegate):
            var flags: AudioUnitRenderActionFlags = []
            var audio = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * UInt32(MemoryLayout<Int16>.stride),
                mData: destination
            ))
            let status = delegate.getPlayoutData(&flags, inTimeStamp, 0, inNumberFrames, &audio)
            guard status == noErr else {
                ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
                destination.update(repeating: 0, count: count)
                return status
            }
            if flags.contains(.unitRenderAction_OutputIsSilence) {
                ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
                destination.update(repeating: 0, count: count)
            }
            return noErr
        }
    }

    private static func logVoice(_ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppLog.shared.add("voice", message) }
        } else {
            Task { @MainActor in AppLog.shared.add("voice", message) }
        }
    }

    func input(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let source = pcm.int16ChannelData?[0] else { return }
        let sourceFrames = UnsafeBufferPointer(start: source, count: Int(pcm.frameLength))
        inputSamples(sourceFrames, timestamp: time.audioTimeStamp)
    }

    private func inputSamples(_ sourceFrames: UnsafeBufferPointer<Int16>, timestamp: AudioTimeStamp) {
        let count = sourceFrames.count
        guard count > 0 else { return }
        sendLock.withLock {
            let delivery: Delivery = lock.withLock {
                switch state {
                case .buffering:
                    let previousEnd = queued.count
                    bufferLocked(sourceFrames)
                    if !overflow {
                        openingEndFrame = queued.count
                        if let nonZeroEnd = lastNonZeroOffset(in: sourceFrames) {
                            lastNonZeroOpeningFrame = max(lastNonZeroOpeningFrame, previousEnd + nonZeroEnd)
                        }
                    }
                    return .none
                case .waitingForOwner(let completion):
                    bufferLocked(sourceFrames)
                    if overflow {
                        state = .readyForDictation
                        completion.finish()
                    }
                    return .none
                case .sending:
                    rememberForRecoveryLocked(sourceFrames)
                    guard recording, let delegate else {
                        bufferLocked(sourceFrames)
                        return .none
                    }
                    guard !overflow else { return .none }
                    if readIndex < queued.count {
                        queued.append(contentsOf: sourceFrames)
                        let pending = readIndex == 0 ? queued : Array(queued[readIndex...])
                        queued.removeAll(keepingCapacity: false)
                        readIndex = 0
                        if !openingConfirmed, !recoveryOverflow {
                            openingEndFrame = recovery.count
                        }
                        deliveredFrames += pending.count
                        evaluateOpeningConfirmedLocked()
                        return .queued(delegate, pending)
                    }
                    deliveredFrames += count
                    evaluateOpeningConfirmedLocked()
                    return .live(delegate)
                case .readyForDictation, .stopped:
                    return .none
                }
            }
            switch delivery {
            case .none:
                return
            case .live(let delegate):
                deliverChunked(sourceFrames, to: delegate, timestamp: timestamp)
            case .queued(let delegate, let pending):
                pending.withUnsafeBufferPointer { deliverChunked($0, to: delegate, timestamp: timestamp) }
            }
        }
    }

    private func evaluateOpeningConfirmedLocked() {
        guard !openingConfirmed, case .sending = state, deliveredFrames > 0 else { return }
        guard readIndex == queued.count, deliveredFrames >= openingEndFrame else { return }
        guard confirmedFrames >= lastNonZeroOpeningFrame, remoteReplied || phoneActionStarted else { return }
        openingConfirmed = true
        recovery.removeAll(keepingCapacity: false)
    }

    private func rememberForRecoveryLocked(_ frames: UnsafeBufferPointer<Int16>) {
        guard !openingConfirmed, !recoveryOverflow else { return }
        guard frames.count <= Self.maxOpeningFrames - recovery.count else {
            recoveryOverflow = true
            return
        }
        let previousEnd = recovery.count
        recovery.append(contentsOf: frames)
        if let nonZeroEnd = lastNonZeroOffset(in: frames) {
            lastNonZeroOpeningFrame = max(lastNonZeroOpeningFrame, previousEnd + nonZeroEnd)
        }
    }

    private func lastNonZeroOffset(in frames: UnsafeBufferPointer<Int16>) -> Int? {
        for index in stride(from: frames.count - 1, through: 0, by: -1) where frames[index] != 0 {
            return index + 1
        }
        return nil
    }

    private func bufferLocked(_ frames: UnsafeBufferPointer<Int16>) {
        let available = Self.maxOpeningFrames - (queued.count - readIndex)
        guard frames.count <= available else {
            overflow = true
            return
        }
        queued.append(contentsOf: frames)
    }

    private func deliverChunked(_ samples: UnsafeBufferPointer<Int16>, to delegate: RTCAudioDeviceDelegate, timestamp initialTimestamp: AudioTimeStamp) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        var timestamp = initialTimestamp
        var offset = 0
        while offset < samples.count {
            let chunkCount = min(Self.deliveryChunkFrames, samples.count - offset)
            timestamp.mSampleTime = deliveredSampleTime
            timestamp.mFlags.insert(.sampleTimeValid)
            var flags: AudioUnitRenderActionFlags = []
            var audio = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(chunkCount * MemoryLayout<Int16>.stride),
                mData: UnsafeMutableRawPointer(mutating: base.advanced(by: offset))
            ))
            let status = delegate.deliverRecordedData(&flags, &timestamp, 0, UInt32(chunkCount), &audio, nil, nil)
            if status != noErr {
                let count = lock.withLock { () -> Int in
                    deliveryErrors += 1
                    return deliveryErrors
                }
                if count <= 3 || count % 100 == 0 {
                    Self.logVoice("opening audio deliverRecordedData error (#\(count)): OSStatus \(status)")
                }
            }
            deliveredSampleTime += Double(chunkCount)
            offset += chunkCount
        }
    }

    private func selectPlayoutSource(count: Int) -> PlayoutSource {
        lock.withLock {
            if case .stopped = state { return .silence }
            if chimeOffset < VoiceOpeningFeedback.readyChime.count {
                let start = chimeOffset
                let end = min(start + count, VoiceOpeningFeedback.readyChime.count)
                chimeOffset = end
                return .chime(start..<end)
            }
            if case .sending = state, playing, let delegate {
                return .webrtc(delegate)
            }
            return .silence
        }
    }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { self.delegate = delegate }
        return true
    }
    func terminateDevice() -> Bool {
        lock.withLock {
            delegate = nil
            recording = false
            playing = false
            recordingInitialized = false
            playoutInitialized = false
        }
        return true
    }
    func initializeRecording() -> Bool { lock.withLock { recordingInitialized = true }; return true }
    func initializePlayout() -> Bool { lock.withLock { playoutInitialized = true }; return true }
    func startRecording() -> Bool { lock.withLock { recording = true }; return true }
    func stopRecording() -> Bool { lock.withLock { recording = false }; return true }
    func startPlayout() -> Bool { lock.withLock { playing = true }; return true }
    func stopPlayout() -> Bool { lock.withLock { playing = false }; return true }
}

private func openingAudioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let audio = Unmanaged<OpeningVoiceAudio>.fromOpaque(inRefCon).takeUnretainedValue()
    return audio.handleAudioUnitInput(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
}

private func openingAudioPlayoutCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let audio = Unmanaged<OpeningVoiceAudio>.fromOpaque(inRefCon).takeUnretainedValue()
    return audio.handleAudioUnitPlayout(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inNumberFrames: inNumberFrames,
        ioData: ioData
    )
}
