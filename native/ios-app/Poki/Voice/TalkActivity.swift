import Foundation

/// The Live Activity during a talk with Poki (stub: the tests come first).
@MainActor
final class TalkActivity {
    init(voice: VoiceModel, activity: ActivityController, deviceName: @escaping @MainActor () -> String,
         keepsActivity: @escaping @MainActor () -> Bool) {}
}
