#if DEBUG
import Foundation
import PokiCore

/// Black-box UI test data. Installed only for the explicit -pokiUITestMemorySource
/// launch argument; never used by release builds or normal app launches.
@MainActor
enum MemorySourceUITestFixture {
    static let sourceID = "poki-uitest-memory-source"
    static let activeID = "poki-uitest-active-chat"
    static let marker = "Synthetic saved source transcript"
    static let draft = "Synthetic unsent composer draft"

    static func installIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-pokiUITestMemorySource") else { return }
        let defaults = UserDefaults.standard
        defaults.set("memoryRecent", forKey: "pokiScreen")
        defaults.set(draft, forKey: "pokiDraft")
        defaults.set(FirstRun.Record.done.rawValue, forKey: FirstRun.key)
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)

        let folder = SessionStore.defaultFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let now = Date()
            let active = SavedSession(
                id: activeID, kind: .poki, title: "Active synthetic chat",
                started: now.addingTimeInterval(-1800), updated: now,
                live: false, outcome: .done,
                entries: [ChatEntry(.you("Active synthetic chat", delivered: true))], calls: []
            )
            let source = SavedSession(
                id: sourceID, kind: .poki, title: "Saved synthetic conversation",
                started: now.addingTimeInterval(-7200), updated: now.addingTimeInterval(-3600),
                live: false, outcome: .done,
                entries: [ChatEntry(.you(marker, delivered: true))], calls: []
            )
            let encoder = JSONEncoder()
            for session in [active, source] {
                try encoder.encode(session).write(
                    to: folder.appendingPathComponent(session.id + ".json"),
                    options: .atomic
                )
            }
            _ = RoutineStore.shared.remember(
                "Synthetic source memory", by: RoutineStore.owner,
                heard: NoteOrigin(session: sourceID, app: nil)
            )
        } catch {
            assertionFailure("Memory source UI fixture failed to seed: \(error)")
        }
    }
}
#endif
