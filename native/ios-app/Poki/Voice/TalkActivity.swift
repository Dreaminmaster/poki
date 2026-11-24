import Foundation

// A talk that shows on the Live Activity and can be ended there is the interaction of pull request #250;
// the code is written here. The talk goes into the state's existing `voice` field, follows the talk's
// phase, and takes the Live Activity with it when it ends only if nothing else is on it.

/// Result of attempting to start Talk Here in the background.
enum TalkHereOutcome: Equatable {
    case started
    case liveActivityUnavailable
    case microphoneUnavailable
    case sessionEnded
}

/// The Live Activity during a talk with Poki, in front and while a step of the talk has Poki in another
/// app: it says whether Poki is listening, working or speaking, and its End ends the talk.
@MainActor
final class TalkActivity {
    private let voice: VoiceModel
    private let activity: ActivityController
    private let deviceName: @MainActor () -> String
    /// Poki is on: its Live Activity stays when the talk ends.
    private let keepsActivity: @MainActor () -> Bool
    /// The talk went off.
    private let ended: @MainActor () -> Void
    /// End on the Live Activity: what stops with the talk.
    private let endFromLiveActivityAction: (@MainActor () -> Void)?
    private var shown: PokiState.Voice?
    private var wasMidTurn = false
    private var activeIntentToken: UUID?
    /// What EndTalkIntent's notification reaches; it holds this weakly, so an ended TalkActivity hears nothing.
    private let mailbox: Mailbox

    init(voice: VoiceModel, activity: ActivityController, deviceName: @escaping @MainActor () -> String,
         keepsActivity: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void = {},
         endFromLiveActivity: (@MainActor () -> Void)? = nil) {
        self.voice = voice
        self.activity = activity
        self.deviceName = deviceName
        self.keepsActivity = keepsActivity
        self.ended = ended
        endFromLiveActivityAction = endFromLiveActivity
        mailbox = Mailbox()
        mailbox.owner = self
        mailbox.listen()
        follow()
    }

    /// The talk's state as the Live Activity says it: nil while no talk is on.
    static func state(of voice: VoiceModel) -> PokiState.Voice? {
        guard voice.isOn else { return nil }
        if voice.waitsForOpeningDictation { return .finishingOpening }
        switch voice.phase {
        case .off, .lost: return nil
        case .connecting: return voice.isCapturingOpening ? .listening : .connecting
        case .listening, .hearing: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    private func follow() {
        withObservationTracking { show(Self.state(of: voice)); turn(voice.midTurn) } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func show(_ talk: PokiState.Voice?, fromIntent: Bool = false) {
        guard talk != shown else { return }
        let started = shown == nil
        shown = talk
        activity.update { $0.voice = talk }
        // Started from a tap in Poki, or from Talk Here's intent: the times iOS lets a Live Activity start.
        if started, talk != nil { activity.start(deviceName: deviceName(), fromIntent: fromIntent) }
        // Only a Live Activity that shows nothing else goes with the talk: an approval, a hand-off, a
        // problem, pairing or setup stays.
        if talk == nil, !keepsActivity(), activity.state.phase == .idle { activity.end() }
        if talk == nil, !started { ended() }
    }

    /// The talk's turn is over: Poki has answered and has nothing left to do for the request. A run of
    /// steps the turn took finishes now, with what Poki said, as the chat finishes its task's run. A talk
    /// that ends mid-turn leaves its run to the Live Activity's quiet wait.
    private func turn(_ mid: Bool) {
        defer { wasMidTurn = mid }
        guard wasMidTurn, !mid, voice.isOn, activity.state.stepCount > 0 else { return }
        let asked = voice.lines.lastIndex { $0.role == .you }
        let said = voice.lines[(asked.map { $0 + 1 } ?? 0)...].last { $0.role == .poki }?.text
        activity.finishNow(alert: false, result: said, task: asked.map { voice.lines[$0].text })
    }

    /// Talk Here (TalkHereIntent), with Poki in the background: the Live Activity starts first in
    /// Connecting while the intent runs, and switches to Listening once background capture starts,
    /// because iOS ends an app that records in the background without an active Live Activity.
    func startHere(
        presentSpeechPermission: SpeechPermissionPresenter = { request in await request() },
        liveInputWaitTimeout: Duration? = nil
    ) async -> TalkHereOutcome {
        let intentToken = UUID()
        activeIntentToken = intentToken
        show(.connecting, fromIntent: true)
        guard activity.isRunning else {
            if activeIntentToken == intentToken {
                activeIntentToken = nil
                show(nil)
            }
            return .liveActivityUnavailable
        }
        let grant = voice.beginBackgroundRecordingGrant(token: intentToken)
        defer {
            voice.endBackgroundRecordingGrant(token: intentToken)
            if activeIntentToken == intentToken {
                activeIntentToken = nil
            }
        }
        guard let startedSession = await voice.start(
            captureOpening: true,
            backgroundRecordingGrant: grant,
            presentSpeechPermission: presentSpeechPermission
        ) else {
            if activeIntentToken == intentToken {
                show(Self.state(of: voice))
            }
            return .sessionEnded
        }
        guard activeIntentToken == intentToken, voice.ownsSession(startedSession) else {
            return .sessionEnded
        }
        show(Self.state(of: voice))
        guard voice.isOn else {
            return .sessionEnded
        }
        // Keep AudioRecordingIntent active long enough for VPIO zero-input recovery within the safe
        // monotonic window; returns immediately once live audio arrives or if capture stops.
        let timeout = liveInputWaitTimeout ?? voice.recommendedLiveInputWaitTimeout(for: grant)
        let waitResult = await voice.waitForOpeningLiveInput(session: startedSession, timeout: timeout)
        guard activeIntentToken == intentToken, voice.ownsSession(startedSession) else {
            return .sessionEnded
        }
        show(Self.state(of: voice))
        guard voice.isOn else {
            return .sessionEnded
        }
        switch waitResult {
        case .live, .skippedMuted, .skippedDisabled:
            guard voice.ensureBackgroundAudioActive(session: startedSession) else {
                AppLog.shared.add("voice", "Talk Here: background audio inactive for session \(startedSession); stopping silent session")
                voice.stop(ifOwningSession: startedSession)
                show(Self.state(of: voice))
                return .microphoneUnavailable
            }
            return .started
        case .timedOut:
            AppLog.shared.add("voice", "Talk Here: opening microphone stayed silent for session \(startedSession); stopping silent session")
            voice.stop(ifOwningSession: startedSession)
            show(Self.state(of: voice))
            return .microphoneUnavailable
        case .stopped, .cancelled:
            return .sessionEnded
        }
    }

    fileprivate func endFromLiveActivity() {
        guard voice.isOn else { return }
        AppLog.shared.add("voice", "the talk was ended from the Live Activity")
        if let endFromLiveActivityAction { endFromLiveActivityAction() } else { voice.stop() }
    }

    private final class Mailbox {
        weak var owner: TalkActivity?

        func listen() {
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
                guard let observer else { return }
                let mailbox = Unmanaged<Mailbox>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in mailbox.owner?.endFromLiveActivity() }
            }, TalkSignal.end as CFString, nil, .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                               CFNotificationName(TalkSignal.end as CFString), nil)
        }
    }
}
