import AppIntents

/// For a shortcut the owner builds around it (issue 484): iOS refuses a new local connection while
/// cellular is the iPhone's way out, and accepts one with no cellular at all. A shortcut turns
/// Cellular Data (or Airplane Mode) off, runs this, and turns it back on: the connection opened in
/// between stays open on cellular. The answer says whether a read came through, so the shortcut can
/// wait for it and not guess a delay.
struct ReconnectPokiIntent: AppIntent {
    static let title = LocalizedStringResource("Reconnect Poki", table: "Entry")
    static let description = IntentDescription(LocalizedStringResource("Poki opens its connection to this iPhone again and says whether it worked. The Poki Loopback shortcut uses it to repair the loopback.", table: "Entry"))
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let app = AskPoki.app else {
            AppLog.shared.add("loopback", "reconnect from a shortcut: Poki was not ready")
            return .result(value: false)
        }
        let connected = await HistoryCollector.shared.reconnect(app, by: "the Reconnect Poki action")
        return .result(value: connected)
    }
}
