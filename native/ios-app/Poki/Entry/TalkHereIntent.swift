import AppIntents
import AVFAudio
import UIKit

/// Talk with Poki without leaving the app you're in: from the Action Button, Shortcuts or Siri, Poki
/// stays in the background, so the app in front stays in front, and Poki looks at it and works in it
/// while you talk. The Live Activity shows the talk and carries End. Running this again stops a live
/// talk, or finishes and sends unconfirmed opening speech as text if voice could not connect or
/// disconnected before confirming it; End on the Live Activity always cancels.
///
/// iOS opens the microphone for an app in the background only from an AudioRecordingIntent, and only
/// with a Live Activity up: LiveActivityIntent lets this intent start one from the background. When
/// Poki cannot talk yet (no voice set up, the first run, pairing, a task under way, no microphone
/// permission) or the Live Activity does not start, Poki opens and Talk to Poki goes on from there.
struct TalkHereIntent: AudioRecordingIntent, LiveActivityIntent, ForegroundContinuableIntent {
    static let title = LocalizedStringResource("Poki Anytime", table: "Entry")
    static let description = IntentDescription(LocalizedStringResource("Starts talking with Poki without leaving the app you’re in. Poki can see that app and work in it. Run it again to end the talk, or to send unconfirmed opening speech as text if voice couldn’t connect or disconnected.", table: "Entry"))
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    // The Action Button works while the iPhone is locked: the talk starts once it is unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = AskPoki.app, let chat = AskPoki.chat else {
            return try await openPoki(LocalizedStringResource("Poki wasn’t ready. Try again in a moment.", table: "Entry"))
        }
        if app.voice.finishOpeningDictation() { return .result() }
        if app.voice.isOn {
            AppLog.shared.add("voice", "Poki Anytime ended the talk")
            app.stopFromOutside("Poki Anytime ended the talk")
            return .result()
        }
        if let why = Self.whyPokiOpens(app, chat) { return try await openPoki(why) }
        VoiceOpeningFeedback.vibrate()
        AppLog.shared.add("voice", "Talk Here: starting a talk with Poki in the background")
        app.prepareForTask()
        let outcome = await app.talkHere(presentSpeechPermission: presentSpeechPermission)
        switch outcome {
        case .liveActivityUnavailable:
            return try await openPoki(LocalizedStringResource("Poki couldn’t show the talk on the Lock Screen, so it opens to talk.", table: "Entry"))
        case .microphoneUnavailable:
            return try await handleBackgroundMicrophoneUnavailable()
        case .sessionEnded:
            if case .lost(let why) = app.voice.phase { throw TalkHereError(why: why) }
            return .result()
        case .started:
            if case .lost(let why) = app.voice.phase { throw TalkHereError(why: why) }
            if app.voice.isOn, !app.voice.ensureBackgroundAudioActive() {
                AppLog.shared.add("voice", "Talk Here: background audio session was not active when intent finished; stopping session")
                app.voice.stop()
                return try await handleBackgroundMicrophoneUnavailable()
            }
            return .result()
        }
    }

    @MainActor
    private func handleBackgroundMicrophoneUnavailable() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        let openWords = LocalizedStringResource("Poki couldn’t capture the microphone in the background, so it opens to talk.", table: "Entry")
        let errorWords = LocalizedStringResource("Poki couldn’t capture the microphone in the background. Open Poki to talk.", table: "Entry")
        if #available(iOS 26.0, *), systemContext.currentMode.canContinueInForeground {
            do {
                return try await openPoki(openWords)
            } catch {
                AppLog.shared.add("voice", "Talk Here could not open Poki after background microphone failure: \(error.localizedDescription)")
                throw TalkHereError(why: AppLocalization.text(errorWords))
            }
        }
        throw TalkHereError(why: AppLocalization.text(errorWords))
    }

    @MainActor
    private func presentSpeechPermission(_ request: @MainActor () async -> Bool) async -> Bool {
        if UIApplication.shared.applicationState == .active { return await request() }
        let dialog = IntentDialog(LocalizedStringResource("Open Poki to allow on-device speech recognition for when voice can’t connect.", table: "Entry"))
        do {
            if #available(iOS 26.0, *) {
                let mode = systemContext.currentMode
                if mode != .foreground {
                    guard mode.canContinueInForeground else { return false }
                    try await continueInForeground(dialog, alwaysConfirm: false)
                }
                return await request()
            }
            return try await requestToContinueInForeground(dialog, continuation: request)
        } catch {
            return false
        }
    }

    /// Why the talk has to start in Poki instead, in the words the shortcut shows; nil when it can start here.
    @MainActor
    private static func whyPokiOpens(_ app: AppModel, _ chat: ChatModel) -> LocalizedStringResource? {
        if FirstRun.isDue() || app.pairingUnderWay { return LocalizedStringResource("Finish setting up Poki first.", table: "Entry") }
        if !app.voice.canTalkLive { return LocalizedStringResource("Set up Poki’s voice first.", table: "Entry") }
        if chat.running || ChatModel.delegatedBusy != nil { return LocalizedStringResource("Poki is doing a task. Here it is.", table: "Entry") }
        if AVAudioApplication.shared.recordPermission != .granted { return LocalizedStringResource("Allow Poki to use the microphone first.", table: "Entry") }
        return nil
    }

    /// Opens Poki, where Talk to Poki takes over (PokiEntry): it starts the talk, or shows what stands in its way.
    @MainActor
    private func openPoki(_ words: LocalizedStringResource) async throws -> IntentResultContainer<Never, Never, Never, Never> {
        AppLog.shared.add("voice", "Talk Here opens Poki: \(String(localized: words))")
        PokiEntry.shared.ask(.talk)
        if #available(iOS 26.0, *) {
            try await continueInForeground(IntentDialog(words), alwaysConfirm: false)
        } else {
            throw needsToContinueInForegroundError(IntentDialog(words), continuation: nil)
        }
        return .result()
    }
}

/// The talk could not connect: the shortcut says why, in the talk's own words.
private struct TalkHereError: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}
