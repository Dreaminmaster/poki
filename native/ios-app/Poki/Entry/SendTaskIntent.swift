import AppIntents

/// Starts a task in Poki's chat without opening Poki, the way a reply from Poki's notification does.
/// When Poki has to be in front for it (Poki is off, or the task did not start), or Poki is already
/// doing something, Poki opens on the chat instead and the task under way keeps running.
struct SendTaskToPokiIntent: AppIntent {
    static let title = LocalizedStringResource("Send Task to Poki", table: "Entry")
    static let description = IntentDescription(LocalizedStringResource("Poki starts the task on this iPhone and tells you when it is done.", table: "Entry"))
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    // The Action Button and the Lock Screen work while the iPhone is locked: no task starts before it is unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: LocalizedStringResource("Task", table: "Entry"),
               requestValueDialog: IntentDialog(LocalizedStringResource("What should Poki do?", table: "Entry")))
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$task) to Poki", table: "Entry") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let chat = AskPoki.chat, let app = AskPoki.app else {
            return try await showPoki(LocalizedStringResource("Poki wasn’t ready. Try again in a moment.", table: "Entry"))
        }
        if chat.running || ChatModel.delegatedBusy != nil || app.voice.isOn {
            return try await showPoki(LocalizedStringResource("Poki is still busy, so this task didn’t start. Here is what Poki is doing.", table: "Entry"))
        }
        AppLog.shared.add("chat", "task from a shortcut (\(task.count) characters)")
        chat.send(task)
        guard chat.running else {
            return try await showPoki(LocalizedStringResource("Poki couldn’t start the task. The chat says why.", table: "Entry"))
        }
        guard app.sessionOn else {
            return try await showPoki(LocalizedStringResource("Poki started the task. Turn Poki on so it can act on the phone.", table: "Entry"))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("Poki is on it. It tells you when it’s done.", table: "Entry")))
    }

    /// Poki comes to the front on the chat (or the hand-off under way). Before iOS 26 it shows them the
    /// next time the owner opens Poki.
    @MainActor
    private func showPoki(_ words: LocalizedStringResource) async throws -> IntentResultContainer<Never, Never, Never, IntentDialog> {
        PokiEntry.shared.ask(.show)
        if #available(iOS 26.0, *) { try await continueInForeground(IntentDialog(words), alwaysConfirm: false) }
        return .result(dialog: IntentDialog(words))
    }
}

/// Poki's actions in Shortcuts, Spotlight and Siri, and the shortcuts the Action Button can run.
struct PokiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToPokiIntent(),
                    phrases: ["Talk to \(.applicationName)", "Start talking to \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Talk to Poki", table: "Entry"), systemImageName: "waveform.circle")
        AppShortcut(intent: SendTaskToPokiIntent(),
                    phrases: ["Send a task to \(.applicationName)", "Give \(.applicationName) a task"],
                    shortTitle: LocalizedStringResource("Send Task", table: "Entry"), systemImageName: "paperplane")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
