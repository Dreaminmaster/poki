#if DEBUG && targetEnvironment(simulator)
import Foundation

/// `-pokiTalkRehearsal 1`, in a simulator's development build: Talk with Poki connects to this instead of
/// OpenAI. It plays one turn of the Realtime API's events into VoiceModel, the way the unit tests'
/// FakeConnection does, so the talk's screens (the message field's talk row, the talk card, the Live
/// Activity, the lines left in the chat when it ends) can be seen without a key, a microphone or sound.
/// VoiceModel handles the events as it would OpenAI's: its phases, lines and the end after a quiet
/// while are the real ones. Nothing is sent anywhere and no step runs on the phone.
final class TalkRehearsal: VoiceConnection, @unchecked Sendable {
    static var asked: Bool { UserDefaults.standard.bool(forKey: "pokiTalkRehearsal") }

    /// The stand-in for the key exchange, which a rehearsal skips.
    static let token = VoiceBridge.Token(value: "rehearsal", model: "rehearsal", local_tools: [])

    private let onEvent: @MainActor ([String: Any]) -> Void
    private var script: Task<Void, Never>?

    init(onEvent: @escaping @MainActor ([String: Any]) -> Void, onClosed: @escaping @MainActor (String) -> Void) {
        self.onEvent = onEvent
    }

    func connect(secret: String, microphone: Bool, direct: Bool) async throws {
        try await Task.sleep(for: .milliseconds(600))
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let said = zh ? "明天早上八点提醒我带伞" : "Remind me to take an umbrella at eight tomorrow morning"
        let answer = zh ? "好的，明天早上八点提醒你带伞。" : "Sure, I’ll remind you at eight tomorrow morning to take an umbrella."
        // Seconds from the connection, and what OpenAI would send then.
        let turn: [(Double, [String: Any])] = [
            (0.3, ["type": "session.created"]),
            (1.5, ["type": "input_audio_buffer.speech_started"]),
            (4.0, ["type": "input_audio_buffer.speech_stopped"]),
            (4.4, ["type": "conversation.item.input_audio_transcription.completed", "transcript": said]),
            (5.2, ["type": "response.created", "response": ["id": "rehearsal-1"]]),
            (5.5, ["type": "output_audio_buffer.started"]),
            (5.6, ["type": "response.output_audio_transcript.done", "transcript": answer]),
            (8.5, ["type": "response.done", "response": ["id": "rehearsal-1"]]),
            (8.6, ["type": "output_audio_buffer.stopped"]),
        ]
        let onEvent = onEvent
        script = Task { @MainActor in
            var clock = 0.0
            for (at, event) in turn {
                try? await Task.sleep(for: .seconds(at - clock))
                guard !Task.isCancelled else { return }
                clock = at
                onEvent(event)
            }
        }
    }

    func send(_ event: [String: Any]) -> Bool { true }
    func setRemoteVolume(_ value: Double) {}
    func diagnose(_ write: @escaping @MainActor (String) -> Void) {}
    func close() { script?.cancel() }
}
#endif
