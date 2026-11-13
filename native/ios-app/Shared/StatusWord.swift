import Foundation

/// Poki's status words, in standard product language: two to four Chinese characters, no subject, no
/// voice of its own ("Ready", "Paused", "Needs approval"; the owner, 2026-11-12). The one table every
/// place that says Poki's state reads (Status.xcstrings): the bear's word (`PokiMood.word`) and through
/// it the top of the chat, the home page, the status card and Settings; and, in the widget extension,
/// which cannot see the app's `PokiMood`, the Dynamic Island, the Lock Screen card and their alerts.
enum StatusWord: CaseIterable {
    case ready, thinking, running, checking
    case needsApproval, needsYourAction
    case done, error, paused, off
    case disconnected, starting, notStarted, notSetUp
    case listening, speaking

    static let table = "Status"

    var text: String {
        switch self {
        case .ready: String(localized: "Ready", table: Self.table)
        case .thinking: String(localized: "Thinking", table: Self.table)
        case .running: String(localized: "Running", table: Self.table)
        case .checking: String(localized: "Checking", table: Self.table)
        case .needsApproval: String(localized: "Needs approval", table: Self.table)
        case .needsYourAction: String(localized: "Needs your action", table: Self.table)
        case .done: String(localized: "Done", table: Self.table)
        case .error: String(localized: "Error", table: Self.table)
        case .paused: String(localized: "Paused", table: Self.table)
        case .off: String(localized: "Off", table: Self.table)
        case .disconnected: String(localized: "Disconnected", table: Self.table)
        case .starting: String(localized: "Starting", table: Self.table)
        case .notStarted: String(localized: "Not started", table: Self.table)
        case .notSetUp: String(localized: "Not set up", table: Self.table)
        case .listening: String(localized: "Listening", table: Self.table)
        case .speaking: String(localized: "Speaking", table: Self.table)
        }
    }
}
