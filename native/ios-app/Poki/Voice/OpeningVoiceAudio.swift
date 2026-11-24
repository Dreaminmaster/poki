import AudioToolbox
import AVFoundation
import Foundation
import UIKit
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
    static let defaultLiveInputWaitTimeout: Duration = .seconds(OpeningAudioRecoveryPolicy.defaultLiveInputWaitTimeoutSeconds)
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

    enum AudioUnitRunState: Equatable, Sendable {
        case running
        case stopped
        case unknown(OSStatus)
    }

    typealias CoreAudioInputRenderer = @Sendable (
        AudioComponentInstance,
        UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        UnsafePointer<AudioTimeStamp>,
        UInt32,
        UInt32,
        UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus

    static func renderCoreAudioInput(
        _ unit: AudioComponentInstance,
        _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
        _ inBusNumber: UInt32,
        _ inNumberFrames: UInt32,
        _ ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData)
    }

    @MainActor static func queryCoreAudioRunState(_ unit: AudioComponentInstance) -> AudioUnitRunState {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global,
            0,
            &isRunning,
            &size
        )
        guard status == noErr else { return .unknown(status) }
        return isRunning != 0 ? .running : .stopped
    }

    @MainActor private var audioUnit: AudioComponentInstance?
    @MainActor private var audioSessionActivations = 0
    @MainActor private var interruptionObserver: NSObjectProtocol?
    @MainActor private var resetObserver: NSObjectProtocol?
    @MainActor private var spatialObserver: NSObjectProtocol?
    @MainActor private var foregroundObserver: NSObjectProtocol?
    @MainActor private var inputMuteObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    private let uptime: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private let isInputMuted: @MainActor () -> Bool
    private let isInBackground: @MainActor () -> Bool
    private let queryAudioUnitRunState: @MainActor (AudioComponentInstance) -> AudioUnitRunState
    private let renderAudioUnitInput: CoreAudioInputRenderer
    private let lock = NSLock()
    // Revocation waits only for a delivery already in progress; WebRTC is never called under `lock`.
    private let sendLock = NSLock()
    private let session: Int
    private var callbackAudioUnit: AudioComponentInstance?
    private var recoveryPolicy: OpeningAudioRecoveryPolicy
    private var observedLiveInput = false

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
    private var nonZeroTapCallbacks = 0
    private var rawMaxPeak: Float = 0
    private var liveInputWaiters: [UUID: AsyncStream<LiveInputWaitResult>.Continuation] = [:]
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
    var hasObservedNonZeroInput: Bool {
        lock.withLock { observedLiveInput || recoveryPolicy.hasObservedNonZeroInput }
    }

    init(
        session: Int,
        playReadyChime: Bool = true,
        zeroInputRecoveryEnabled: Bool? = nil,
        notificationCenter: NotificationCenter = .default,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isInputMuted: @escaping @MainActor () -> Bool = { AVAudioApplication.shared.isInputMuted },
        isInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background },
        queryAudioUnitRunState: @escaping @MainActor (AudioComponentInstance) -> AudioUnitRunState = OpeningVoiceAudio.queryCoreAudioRunState,
        renderAudioUnitInput: @escaping CoreAudioInputRenderer = OpeningVoiceAudio.renderCoreAudioInput
    ) {
        self.session = session
        #if targetEnvironment(simulator)
        let recoveryEnabled = zeroInputRecoveryEnabled ?? false
        #else
        let recoveryEnabled = zeroInputRecoveryEnabled ?? true
        #endif
        self.recoveryPolicy = OpeningAudioRecoveryPolicy(enabled: recoveryEnabled)
        self.notificationCenter = notificationCenter
        self.uptime = uptime
        self.sleep = sleep
        self.isInputMuted = isInputMuted
        self.isInBackground = isInBackground
        self.queryAudioUnitRunState = queryAudioUnitRunState
        self.renderAudioUnitInput = renderAudioUnitInput
        chimeOffset = playReadyChime ? 0 : VoiceOpeningFeedback.readyChime.count
        super.init()
    }

    deinit {
        let (unit, waiters): (AudioComponentInstance?, [AsyncStream<LiveInputWaitResult>.Continuation]) = lock.withLock {
            let current = callbackAudioUnit
            callbackAudioUnit = nil
            let pending = Array(liveInputWaiters.values)
            liveInputWaiters.removeAll()
            return (current, pending)
        }
        for waiter in waiters {
            waiter.yield(.stopped)
            waiter.finish()
        }
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    @MainActor func setBackgroundRecordingGrant(_ grant: BackgroundRecordingGrant?) {
        lock.withLock { recoveryPolicy.setBackgroundGrant(grant) }
    }

    @MainActor func clearBackgroundRecordingGrant(token: UUID) {
        lock.withLock { recoveryPolicy.clearBackgroundGrant(token: token) }
    }

    @MainActor func startCapture() throws {
        let muted = isInputMuted()
        lock.withLock { recoveryPolicy.setInputMuted(muted) }
        try VoiceLink.activateAudioSession(configure: true)
        audioSessionActivations += 1
        do {
            try configureAndStartAudioUnit()
            observeAudioLifecycle()
        } catch {
            removeAudioLifecycleObservers()
            stopAudioUnit()
            releaseAudioSessionActivations()
            throw error
        }
    }

    @MainActor private func releaseAudioSessionActivations() {
        while audioSessionActivations > 0 {
            audioSessionActivations -= 1
            VoiceLink.deactivateAudioSession()
        }
    }

    @MainActor func ensureRunning() -> Bool {
        guard let unit = audioUnit else { return false }
        switch queryAudioUnitRunState(unit) {
        case .running:
            return RTCAudioSession.sharedInstance().isActive
        case .stopped:
            restartAudioUnit(trigger: .ensureRunning)
            guard let currentUnit = audioUnit else { return false }
            return queryAudioUnitRunState(currentUnit) == .running && RTCAudioSession.sharedInstance().isActive
        case .unknown(let status):
            Self.logVoice("opening audio ensureRunning could not query VPIO state (OSStatus \(status)); keeping existing unit")
            return false
        }
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
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        lock.withLock { callbackAudioUnit = nil }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    @MainActor private func observeAudioLifecycle() {
        removeAudioLifecycleObservers()
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated { self?.restartAudioUnit(trigger: .interruptionEnded) }
        }
        resetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudioUnit(trigger: .mediaServicesReset) }
        }
        spatialObserver = notificationCenter.addObserver(
            forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverFromZeroInput(trigger: .spatialCapabilitiesChanged)
            }
        }
        foregroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppBecameActive()
            }
        }
        inputMuteObserver = notificationCenter.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let muted = self.isInputMuted()
                self.lock.withLock { self.recoveryPolicy.setInputMuted(muted) }
            }
        }
    }

    @MainActor private func handleAppBecameActive() {
        lock.withLock { recoveryPolicy.noteForeground() }
        recoverFromZeroInput(trigger: .appBecameActive)
    }

    @MainActor private func removeAudioLifecycleObservers() {
        if let interruptionObserver { notificationCenter.removeObserver(interruptionObserver) }
        if let resetObserver { notificationCenter.removeObserver(resetObserver) }
        if let spatialObserver { notificationCenter.removeObserver(spatialObserver) }
        if let foregroundObserver { notificationCenter.removeObserver(foregroundObserver) }
        if let inputMuteObserver { notificationCenter.removeObserver(inputMuteObserver) }
        interruptionObserver = nil
        resetObserver = nil
        spatialObserver = nil
        foregroundObserver = nil
        inputMuteObserver = nil
    }

    struct LiveInputWait {
        fileprivate enum Backing {
            case immediate(LiveInputWaitResult)
            case stream(UUID, AsyncStream<LiveInputWaitResult>)
        }
        fileprivate let backing: Backing
    }

    /// Synchronously registers a waiter before suspension so callers can deterministically observe
    /// wakeup, stop release, cancellation, or timeout without scheduling races.
    @MainActor func startLiveInputWait() -> LiveInputWait {
        if Task.isCancelled {
            return LiveInputWait(backing: .immediate(.cancelled))
        }
        let muted = isInputMuted()
        let immediateOrStream: LiveInputWait.Backing = lock.withLock {
            if !recoveryPolicy.enabled { return .immediate(.skippedDisabled) }
            if muted {
                recoveryPolicy.setInputMuted(true)
                return .immediate(.skippedMuted)
            }
            if observedLiveInput || recoveryPolicy.hasObservedNonZeroInput { return .immediate(.live) }
            if case .stopped = state { return .immediate(.stopped) }
            let waiterID = UUID()
            let (stream, continuation) = AsyncStream<LiveInputWaitResult>.makeStream()
            liveInputWaiters[waiterID] = continuation
            return .stream(waiterID, stream)
        }
        return LiveInputWait(backing: immediateOrStream)
    }

    @MainActor func awaitLiveInputWait(
        _ wait: LiveInputWait,
        timeout: Duration = defaultLiveInputWaitTimeout
    ) async -> LiveInputWaitResult {
        switch wait.backing {
        case .immediate(let result):
            return Task.isCancelled ? .cancelled : result
        case .stream(let waiterID, let stream):
            if Task.isCancelled {
                finishLiveInputWaiter(id: waiterID, result: .cancelled)
                return .cancelled
            }
            let timeoutTask = Task { [weak self, sleep] in
                do {
                    try await sleep(timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.finishLiveInputWaiter(id: waiterID, result: .timedOut)
            }
            defer {
                timeoutTask.cancel()
                finishLiveInputWaiter(id: waiterID, result: .cancelled)
            }
            return await withTaskCancellationHandler {
                var result: LiveInputWaitResult = .cancelled
                for await outcome in stream {
                    result = outcome
                    break
                }
                return result
            } onCancel: { [weak self] in
                self?.finishLiveInputWaiter(id: waiterID, result: .cancelled)
            }
        }
    }

    @MainActor func waitForLiveInput(timeout: Duration = defaultLiveInputWaitTimeout) async -> LiveInputWaitResult {
        let wait = startLiveInputWait()
        return await awaitLiveInputWait(wait, timeout: timeout)
    }

    private func finishLiveInputWaiter(id: UUID, result: LiveInputWaitResult) {
        let waiter = lock.withLock { liveInputWaiters.removeValue(forKey: id) }
        waiter?.yield(result)
        waiter?.finish()
    }

    @MainActor private func recoverFromZeroInput(trigger: OpeningAudioRecoveryPolicy.RestartTrigger) {
        let muted = isInputMuted()
        let inBackground = isInBackground()
        let now = uptime()
        let evaluated: (decision: OpeningAudioRecoveryPolicy.RestartDecision, taps: Int, zeroFrames: Int) = lock.withLock {
            let isStopped: Bool
            if case .stopped = state { isStopped = true } else { isStopped = false }
            let decision = recoveryPolicy.evaluateRestart(
                trigger: trigger,
                isStopped: isStopped,
                isInputMuted: muted,
                inBackground: inBackground,
                now: now
            )
            return (decision, recoveryPolicy.tapCallbacks, recoveryPolicy.zeroInputFrames)
        }
        switch evaluated.decision {
        case .restart(let attempt, let clearZeroBuffer):
            Self.logVoice("opening audio restarting VPIO for \(trigger.logDescription) (attempt \(attempt), taps=\(evaluated.taps), zeroFrames=\(evaluated.zeroFrames))")
            restartAudioUnit(trigger: trigger, alreadyAuthorized: true, clearZeroBuffer: clearZeroBuffer)
        case .restartLifecycle:
            restartAudioUnit(trigger: trigger, alreadyAuthorized: true)
        case .skip(.backgroundGrantExpired):
            Self.logVoice("opening audio skipped VPIO restart for \(trigger.logDescription): background recording grant expired; keeping existing unit")
        case .skip:
            break
        }
    }

    @MainActor private func restartAudioUnit(
        trigger: OpeningAudioRecoveryPolicy.RestartTrigger,
        alreadyAuthorized: Bool = false,
        clearZeroBuffer: Bool = false
    ) {
        let inBackground = isInBackground()
        let now = uptime()
        let allowed: OpeningAudioRecoveryPolicy.RestartDecision = lock.withLock {
            let isStopped: Bool
            if case .stopped = state { isStopped = true } else { isStopped = false }
            if isStopped { return .skip(.stopped) }
            let decision: OpeningAudioRecoveryPolicy.RestartDecision
            if alreadyAuthorized {
                guard recoveryPolicy.canRestartInEnvironment(inBackground: inBackground, now: now) else {
                    return .skip(.backgroundGrantExpired)
                }
                decision = .restartLifecycle
            } else {
                decision = recoveryPolicy.evaluateRestart(
                    trigger: trigger,
                    isStopped: false,
                    isInputMuted: false,
                    inBackground: inBackground,
                    now: now
                )
            }
            switch decision {
            case .restart, .restartLifecycle:
                if clearZeroBuffer, case .buffering = state, lastNonZeroOpeningFrame == 0 {
                    queued.removeAll(keepingCapacity: true)
                    readIndex = 0
                    openingEndFrame = 0
                }
            case .skip:
                break
            }
            return decision
        }
        switch allowed {
        case .restart, .restartLifecycle:
            break
        case .skip(.backgroundGrantExpired):
            Self.logVoice("opening audio skipped VPIO restart for \(trigger.logDescription): background recording grant expired; keeping existing unit")
            return
        case .skip:
            return
        }
        stopAudioUnit()
        do {
            try VoiceLink.activateAudioSession(configure: false)
            audioSessionActivations += 1
            try configureAndStartAudioUnit()
            Self.logVoice("opening audio unit restarted after \(trigger.logDescription)")
            let currentDelegate = lock.withLock { delegate }
            currentDelegate?.dispatchAsync {
                currentDelegate?.notifyAudioInputInterrupted()
                currentDelegate?.notifyAudioOutputInterrupted()
            }
        } catch {
            Self.logVoice("opening audio unit restart failed after \(trigger.logDescription): \(error.localizedDescription)")
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
                let summary = "opening audio handoff: queued \(queued.count) frames (\(seconds) s), taps \(recoveryPolicy.tapCallbacks), nonZeroTaps \(nonZeroTapCallbacks), rawNonZero \(recoveryPolicy.rawNonZeroTapCallbacks), rawPeak \(peak), renderErrors \(renderErrors), deliveryErrors \(deliveryErrors)"
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
        let stopped: (wasRunning: Bool, completeRecording: [Int16]?, waiters: [AsyncStream<LiveInputWaitResult>.Continuation]) = sendLock.withLock {
            lock.withLock {
                if case .stopped = state { return (false, nil, []) }
                let samples: [Int16]?
                if forDictation, case .readyForDictation = state, !overflow { samples = queued }
                else { samples = nil }
                let previous = state
                state = .stopped
                delegate = nil
                queued.removeAll()
                recovery.removeAll()
                readIndex = 0
                recoveryPolicy.setBackgroundGrant(nil)
                let waiters = Array(liveInputWaiters.values)
                liveInputWaiters.removeAll()
                if case .waitingForOwner(let completion) = previous { completion.finish() }
                return (true, samples, waiters)
            }
        }
        for waiter in stopped.waiters {
            waiter.yield(.stopped)
            waiter.finish()
        }
        guard stopped.wasRunning else { return nil }
        removeAudioLifecycleObservers()
        stopAudioUnit()
        releaseAudioSessionActivations()
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
            let status = renderAudioUnitInput(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
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
            recordRawInputMetrics(frameCount: count, maxSample: maxSample, peak: peak)
            inputSamples(samples, timestamp: inTimeStamp.pointee)
            return noErr
        }
    }

    private func recordRawInputMetrics(frameCount: Int, maxSample: Int32, peak: Float) {
        let observation: OpeningAudioRecoveryPolicy.InputObservation = lock.withLock {
            let isStopped: Bool
            if case .stopped = state { isStopped = true } else { isStopped = false }
            if maxSample > 0 {
                nonZeroTapCallbacks += 1
            }
            if peak > rawMaxPeak { rawMaxPeak = peak }
            return recoveryPolicy.recordInput(frameCount: frameCount, maxSample: maxSample, isStopped: isStopped)
        }
        switch observation {
        case .none:
            break
        case .requestZeroInputRecovery(let attempt):
            Task { @MainActor [weak self] in
                self?.recoverFromZeroInput(trigger: .sustainedZeroInput(attempt: attempt))
            }
        case .recoveredNonZero(let attempts):
            let formatted = String(format: "%.5f", peak)
            Self.logVoice("opening audio recovered non-zero input after \(attempts) VPIO restart(s): peak=\(formatted)")
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
        let count = Int(pcm.frameLength)
        guard count > 0 else { return }
        let sourceFrames = UnsafeBufferPointer(start: source, count: count)
        inputSamples(sourceFrames, timestamp: time.audioTimeStamp)
    }

    private func inputSamples(_ sourceFrames: UnsafeBufferPointer<Int16>, timestamp: AudioTimeStamp) {
        let count = sourceFrames.count
        guard count > 0 else { return }
        let nonZeroEnd = lastNonZeroOffset(in: sourceFrames)
        let liveWaiters: [AsyncStream<LiveInputWaitResult>.Continuation] = sendLock.withLock {
            let (delivery, waiters): (Delivery, [AsyncStream<LiveInputWaitResult>.Continuation]) = lock.withLock {
                var waking: [AsyncStream<LiveInputWaitResult>.Continuation] = []
                if nonZeroEnd != nil {
                    observedLiveInput = true
                    if !liveInputWaiters.isEmpty {
                        waking = Array(liveInputWaiters.values)
                        liveInputWaiters.removeAll()
                    }
                }
                switch state {
                case .buffering:
                    let previousEnd = queued.count
                    bufferLocked(sourceFrames)
                    if !overflow {
                        openingEndFrame = queued.count
                        if let nonZeroEnd {
                            lastNonZeroOpeningFrame = max(lastNonZeroOpeningFrame, previousEnd + nonZeroEnd)
                        }
                    }
                    return (.none, waking)
                case .waitingForOwner(let completion):
                    bufferLocked(sourceFrames)
                    if overflow {
                        state = .readyForDictation
                        completion.finish()
                    }
                    return (.none, waking)
                case .sending:
                    rememberForRecoveryLocked(sourceFrames)
                    guard recording, let delegate else {
                        bufferLocked(sourceFrames)
                        return (.none, waking)
                    }
                    guard !overflow else { return (.none, waking) }
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
                        return (.queued(delegate, pending), waking)
                    }
                    deliveredFrames += count
                    evaluateOpeningConfirmedLocked()
                    return (.live(delegate), waking)
                case .readyForDictation, .stopped:
                    return (.none, waking)
                }
            }
            switch delivery {
            case .none:
                break
            case .live(let delegate):
                deliverChunked(sourceFrames, to: delegate, timestamp: timestamp)
            case .queued(let delegate, let pending):
                pending.withUnsafeBufferPointer { deliverChunked($0, to: delegate, timestamp: timestamp) }
            }
            return waiters
        }
        for waiter in liveWaiters {
            waiter.yield(.live)
            waiter.finish()
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
