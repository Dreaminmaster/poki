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
        let finished: AsyncStream<Void>
    }

    private static let sampleRate = 48_000.0
    private static let framesPerMillisecond = Int(sampleRate / 1_000)
    // Covers two connection attempts plus fallback dictation without unbounded memory growth.
    static let maxOpeningFrames = Int(sampleRate) * 180
    private static let maxReplayBurst = Int(sampleRate / 10)
    private static let channelFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!

    private let engine = AVAudioEngine()
    @MainActor private var engineRunning = false
    private let lock = NSLock()
    // Revocation waits only for a delivery already in progress; WebRTC is never called under `lock`.
    private let sendLock = NSLock()
    private let session: Int

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
    private var confirmedFrames = 0
    private var hasServerFrameProgress = false
    private var phoneActionStarted = false
    private var remoteReplied = false
    private var openingConfirmed = false

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

    @MainActor func startCapture() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
        var tapInstalled = false
        do {
            let microphone = engine.inputNode
            try microphone.setVoiceProcessingEnabled(true)
            microphone.isVoiceProcessingBypassed = false
            let inputFormat = microphone.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: inputFormat, to: Self.channelFormat) else {
                throw VoiceError.noWebRTC
            }
            let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
            let player = makePlayer(format: playbackFormat)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            installTap(on: microphone, format: inputFormat, converter: converter)
            tapInstalled = true
            engine.prepare()
            try engine.start()
            engineRunning = true
        } catch {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func allowSending(session: Int) -> Bool {
        lock.withLock {
            guard session == self.session, !overflow else { return false }
            switch state {
            case .buffering:
                recovery = queued
                openingEndFrame = queued.count
                state = .sending
                return true
            case .sending:
                return true
            case .waitingForOwner, .readyForDictation, .stopped:
                return false
            }
        }
    }

    func confirmRemoteAudio(session: Int, endMilliseconds: Int) {
        guard endMilliseconds > 0 else { return }
        lock.withLock {
            guard session == self.session, case .sending = state, deliveredFrames > 0 else { return }
            hasServerFrameProgress = true
            let frames = min(deliveredFrames, endMilliseconds * Self.framesPerMillisecond)
            confirmedFrames = max(confirmedFrames, frames)
            evaluateOpeningConfirmedLocked()
        }
    }

    func confirmRemoteTranscription(session: Int) {
        lock.withLock {
            guard session == self.session, case .sending = state, deliveredFrames > 0 else { return }
            if !hasServerFrameProgress {
                confirmedFrames = max(confirmedFrames, deliveredFrames)
            }
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

    func prepareForOwnerDictation(session: Int) -> RecoveryPlan? {
        sendLock.withLock {
            lock.withLock {
                guard session == self.session else { return nil }
                let kind: RecoveryKind
                switch state {
                case .buffering:
                    guard !overflow else { return nil }
                    kind = .fullOpening
                case .sending:
                    evaluateOpeningConfirmedLocked()
                    guard !openingConfirmed else { return nil }
                    guard !overflow, !recoveryOverflow else { return nil }
                    if phoneActionStarted {
                        let tailStart = hasServerFrameProgress ? min(confirmedFrames, deliveredFrames) : deliveredFrames
                        let hasUnconfirmedSpeech = tailStart < lastNonZeroOpeningFrame
                        let hasUnsentAudio = deliveredFrames < recovery.count
                        guard tailStart < recovery.count, hasUnconfirmedSpeech || hasUnsentAudio else { return nil }
                        queued = Array(recovery[tailStart...])
                        kind = .unconfirmedTail
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
                return RecoveryPlan(kind: kind, finished: finished)
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
        if engineRunning {
            engineRunning = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        guard let samples = stopped.completeRecording, !samples.isEmpty,
              let audio = AVAudioPCMBuffer(pcmFormat: Self.channelFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = audio.int16ChannelData?[0] else { return nil }
        audio.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: $0.count) }
        return audio
    }

    private func installTap(on microphone: AVAudioInputNode, format: AVAudioFormat, converter: AVAudioConverter) {
        microphone.installTap(onBus: 0, bufferSize: 480, format: format) { [weak self] buffer, time in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Self.sampleRate / format.sampleRate)) + 64
            guard let self, let pcm = AVAudioPCMBuffer(pcmFormat: Self.channelFormat, frameCapacity: capacity) else { return }
            var supplied = false
            let status = converter.convert(to: pcm, error: nil) { _, inputStatus in
                inputStatus.pointee = supplied ? .noDataNow : .haveData
                defer { supplied = true }
                return supplied ? nil : buffer
            }
            guard status != .error, pcm.frameLength > 0 else { return }
            self.input(pcm, at: time)
        }
    }

    func input(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let source = pcm.int16ChannelData?[0] else { return }
        let count = Int(pcm.frameLength)
        let sourceFrames = UnsafeBufferPointer(start: source, count: count)
        sendLock.withLock {
            let (delegate, audio): (RTCAudioDeviceDelegate?, [Int16]?) = lock.withLock {
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
                    return (nil, nil)
                case .waitingForOwner(let completion):
                    bufferLocked(sourceFrames)
                    if overflow {
                        state = .readyForDictation
                        completion.finish()
                    }
                    return (nil, nil)
                case .sending:
                    rememberForRecoveryLocked(sourceFrames)
                    guard recording, let delegate else {
                        bufferLocked(sourceFrames)
                        return (nil, nil)
                    }
                    guard !overflow else { return (nil, nil) }
                    let drainingQueue = readIndex < queued.count
                    let packet = drainingQueue ? drainLocked(with: sourceFrames) : nil
                    if drainingQueue, !openingConfirmed, !recoveryOverflow {
                        openingEndFrame = recovery.count
                    }
                    deliveredFrames += packet?.count ?? count
                    evaluateOpeningConfirmedLocked()
                    return (delegate, packet)
                case .readyForDictation, .stopped:
                    return (nil, nil)
                }
            }
            guard let delegate else { return }
            if let audio {
                audio.withUnsafeBufferPointer { deliver($0, to: delegate, at: time) }
            } else {
                deliver(sourceFrames, to: delegate, at: time)
            }
        }
    }

    private func evaluateOpeningConfirmedLocked() {
        guard !openingConfirmed, case .sending = state, deliveredFrames > 0 else { return }
        guard readIndex == queued.count, deliveredFrames >= openingEndFrame else { return }
        let inputCovered = hasServerFrameProgress
            ? confirmedFrames >= lastNonZeroOpeningFrame
            : (confirmedFrames >= lastNonZeroOpeningFrame || phoneActionStarted)
        if inputCovered && (remoteReplied || phoneActionStarted) {
            openingConfirmed = true
            recovery.removeAll(keepingCapacity: false)
        }
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

    private func drainLocked(with frames: UnsafeBufferPointer<Int16>) -> [Int16] {
        queued.append(contentsOf: frames)
        let burst = min(frames.count, Self.maxReplayBurst)
        let end = min(readIndex + frames.count + burst, queued.count)
        let packet = Array(queued[readIndex..<end])
        readIndex = end
        if readIndex == queued.count {
            queued.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= Int(Self.sampleRate), readIndex >= queued.count / 2 {
            queued.removeFirst(readIndex)
            readIndex = 0
        }
        return packet
    }

    private func deliver(_ samples: UnsafeBufferPointer<Int16>, to delegate: RTCAudioDeviceDelegate, at time: AVAudioTime) {
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = time.audioTimeStamp
        var audio = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(samples.count * MemoryLayout<Int16>.stride),
            mData: UnsafeMutableRawPointer(mutating: samples.baseAddress)
        ))
        _ = delegate.deliverRecordedData(&flags, &timestamp, 0, UInt32(samples.count), &audio, nil, nil)
    }

    func renderPlayout(silent: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                       frameCount: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let destination = output.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return kAudio_ParamError
        }
        let count = Int(frameCount)
        let source: PlayoutSource = lock.withLock {
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
        switch source {
        case .chime(let range):
            let chime = VoiceOpeningFeedback.readyChime
            var write = 0
            for index in range {
                destination[write] = chime[index]
                write += 1
            }
            if write < count {
                destination.advanced(by: write).update(repeating: 0, count: count - write)
            }
            return noErr
        case .silence:
            silent.pointee = true
            destination.update(repeating: 0, count: count)
            return noErr
        case .webrtc(let delegate):
            return withUnsafeTemporaryAllocation(of: Int16.self, capacity: count) { samples in
                var flags: AudioUnitRenderActionFlags = []
                var audio = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: frameCount * UInt32(MemoryLayout<Int16>.stride), mData: samples.baseAddress
                ))
                let status = delegate.getPlayoutData(&flags, timestamp, 0, frameCount, &audio)
                guard status == noErr else { return status }
                if flags.contains(.unitRenderAction_OutputIsSilence) {
                    silent.pointee = true
                    destination.update(repeating: 0, count: count)
                } else {
                    for index in samples.indices { destination[index] = Float(samples[index]) / 32_768 }
                }
                return noErr
            }
        }
    }

    private func makePlayer(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [weak self] silent, timestamp, count, output in
            guard let self else {
                silent.pointee = true
                return noErr
            }
            return self.renderPlayout(silent: silent, timestamp: timestamp, frameCount: count, output: output)
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
