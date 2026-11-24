import Foundation

/// Monotonic authorization lease tying background VPIO restart permission to one AudioRecordingIntent.
struct BackgroundRecordingGrant: Equatable, Sendable {
    let token: UUID
    let deadline: TimeInterval

    func isActive(at now: TimeInterval) -> Bool {
        now < deadline
    }

    func remainingTime(at now: TimeInterval) -> TimeInterval {
        max(0, deadline - now)
    }
}

/// Explicit outcome of waiting for the first live non-zero microphone callback on opening capture.
enum LiveInputWaitResult: Equatable, Sendable {
    case live
    case skippedMuted
    case skippedDisabled
    case timedOut
    case stopped
    case cancelled
}

/// Pure value-type state machine governing VPIO recovery decisions and monotonic background restart gating.
struct OpeningAudioRecoveryPolicy: Sendable {
    enum RestartTrigger: Equatable, Sendable {
        case sustainedZeroInput(attempt: Int)
        case spatialCapabilitiesChanged
        case appBecameActive
        case interruptionEnded
        case mediaServicesReset
        case ensureRunning

        var logDescription: String {
            switch self {
            case .sustainedZeroInput(let attempt):
                return "sustained zero input (#\(attempt))"
            case .spatialCapabilitiesChanged:
                return "spatial playback capabilities changed"
            case .appBecameActive:
                return "app became active"
            case .interruptionEnded:
                return "interruption ended"
            case .mediaServicesReset:
                return "media services reset"
            case .ensureRunning:
                return "ensureRunning"
            }
        }

        var isZeroInputRecovery: Bool {
            switch self {
            case .sustainedZeroInput, .spatialCapabilitiesChanged, .appBecameActive:
                return true
            case .interruptionEnded, .mediaServicesReset, .ensureRunning:
                return false
            }
        }

        var requiresExistingZeroInput: Bool {
            switch self {
            case .spatialCapabilitiesChanged, .appBecameActive:
                return true
            case .sustainedZeroInput, .interruptionEnded, .mediaServicesReset, .ensureRunning:
                return false
            }
        }
    }

    enum SkipReason: Equatable, Sendable {
        case disabled
        case stopped
        case alreadyObservedNonZero
        case noTapCallbacksYet
        case inputMuted
        case backgroundGrantExpired
        case spatialThrottled
        case attemptLimitReached
    }

    enum InputObservation: Equatable, Sendable {
        case none
        case requestZeroInputRecovery(attempt: Int)
        case recoveredNonZero(attempts: Int)
    }

    enum RestartDecision: Equatable, Sendable {
        case restart(attempt: Int, clearZeroBuffer: Bool)
        case restartLifecycle
        case skip(SkipReason)
    }

    /// Leaves a 1.5 s safety margin inside iOS 27.3's 5.0 s AudioRecordingIntent window so an ~0.8 s
    /// VPIO restart finishes before iOS rejects background recording with OSStatus 2003329396.
    static let defaultBackgroundGrantDuration: TimeInterval = 3.5
    /// Cumulative exact-zero frames (every 1.5 s from 1.5 s to 12.0 s at 48 kHz) before restarting
    /// VPIO to recover from sticky remote-control input mute without an interruption notice.
    static let defaultZeroInputThresholds = [72_000, 144_000, 216_000, 288_000, 360_000, 432_000, 504_000, 576_000]
    static let defaultMaxRecoveryRestarts = 10
    static let defaultMinSpatialNotificationInterval: TimeInterval = 0.5
    static let defaultLiveInputWaitTimeoutSeconds: TimeInterval = 8.0

    let enabled: Bool
    let thresholds: [Int]
    let maxRestarts: Int
    let minSpatialInterval: TimeInterval

    private(set) var backgroundGrant: BackgroundRecordingGrant?
    private(set) var isInputMuted = false
    private(set) var tapCallbacks = 0
    private(set) var rawNonZeroTapCallbacks = 0
    private(set) var zeroInputFrames = 0
    private(set) var thresholdRecoveryCount = 0
    private(set) var totalRecoveryRestarts = 0
    private(set) var pendingThresholdDispatch = false
    private(set) var suppressedUntilForegroundOrNewGrant = false
    private(set) var loggedNonZeroRecovery = false
    private(set) var lastSpatialRestartUptime: TimeInterval?

    var hasObservedNonZeroInput: Bool { rawNonZeroTapCallbacks > 0 }

    init(
        enabled: Bool,
        thresholds: [Int] = OpeningAudioRecoveryPolicy.defaultZeroInputThresholds,
        maxRestarts: Int = OpeningAudioRecoveryPolicy.defaultMaxRecoveryRestarts,
        minSpatialInterval: TimeInterval = OpeningAudioRecoveryPolicy.defaultMinSpatialNotificationInterval
    ) {
        self.enabled = enabled
        self.thresholds = thresholds
        self.maxRestarts = maxRestarts
        self.minSpatialInterval = minSpatialInterval
    }

    mutating func setBackgroundGrant(_ grant: BackgroundRecordingGrant?) {
        let changedToken = backgroundGrant?.token != grant?.token
        backgroundGrant = grant
        if grant != nil && changedToken {
            suppressedUntilForegroundOrNewGrant = false
            pendingThresholdDispatch = false
        }
    }

    mutating func clearBackgroundGrant(token: UUID) {
        guard backgroundGrant?.token == token else { return }
        backgroundGrant = nil
    }

    mutating func setInputMuted(_ muted: Bool) {
        isInputMuted = muted
        pendingThresholdDispatch = false
        zeroInputFrames = 0
    }

    mutating func noteForeground() {
        suppressedUntilForegroundOrNewGrant = false
        pendingThresholdDispatch = false
    }

    func canRestartInEnvironment(inBackground: Bool, now: TimeInterval) -> Bool {
        guard inBackground else { return true }
        return backgroundGrant?.isActive(at: now) == true
    }

    mutating func recordInput(frameCount: Int, maxSample: Int32, isStopped: Bool) -> InputObservation {
        tapCallbacks += 1
        if maxSample > 0 {
            rawNonZeroTapCallbacks += 1
            zeroInputFrames = 0
            pendingThresholdDispatch = false
            suppressedUntilForegroundOrNewGrant = false
            if totalRecoveryRestarts > 0, !loggedNonZeroRecovery {
                loggedNonZeroRecovery = true
                return .recoveredNonZero(attempts: totalRecoveryRestarts)
            }
            return .none
        }
        guard enabled,
              rawNonZeroTapCallbacks == 0,
              !isStopped,
              !isInputMuted,
              !suppressedUntilForegroundOrNewGrant else {
            return .none
        }
        zeroInputFrames += frameCount
        guard !pendingThresholdDispatch,
              totalRecoveryRestarts < maxRestarts,
              thresholdRecoveryCount < thresholds.count,
              zeroInputFrames >= thresholds[thresholdRecoveryCount] else {
            return .none
        }
        pendingThresholdDispatch = true
        return .requestZeroInputRecovery(attempt: totalRecoveryRestarts + 1)
    }

    mutating func evaluateRestart(
        trigger: RestartTrigger,
        isStopped: Bool,
        isInputMuted: Bool,
        inBackground: Bool,
        now: TimeInterval
    ) -> RestartDecision {
        if isStopped {
            pendingThresholdDispatch = false
            return .skip(.stopped)
        }
        if !trigger.isZeroInputRecovery {
            guard canRestartInEnvironment(inBackground: inBackground, now: now) else {
                return .skip(.backgroundGrantExpired)
            }
            return .restartLifecycle
        }

        pendingThresholdDispatch = false
        if !inBackground || trigger == .appBecameActive {
            suppressedUntilForegroundOrNewGrant = false
        }
        guard enabled else {
            return .skip(.disabled)
        }
        if isInputMuted {
            self.isInputMuted = true
            zeroInputFrames = 0
            return .skip(.inputMuted)
        }
        if self.isInputMuted {
            self.isInputMuted = false
        }
        guard canRestartInEnvironment(inBackground: inBackground, now: now) else {
            suppressedUntilForegroundOrNewGrant = true
            return .skip(.backgroundGrantExpired)
        }
        guard rawNonZeroTapCallbacks == 0 else {
            return .skip(.alreadyObservedNonZero)
        }
        if trigger.requiresExistingZeroInput, tapCallbacks == 0 {
            return .skip(.noTapCallbacksYet)
        }
        if trigger == .spatialCapabilitiesChanged,
           let last = lastSpatialRestartUptime,
           now - last < minSpatialInterval {
            return .skip(.spatialThrottled)
        }
        guard totalRecoveryRestarts < maxRestarts else {
            return .skip(.attemptLimitReached)
        }
        totalRecoveryRestarts += 1
        if case .sustainedZeroInput = trigger {
            thresholdRecoveryCount += 1
        }
        if trigger == .spatialCapabilitiesChanged {
            lastSpatialRestartUptime = now
        }
        return .restart(attempt: totalRecoveryRestarts, clearZeroBuffer: true)
    }
}
