import XCTest
@testable import Poki

/// Archiving conversations: the first launch of the version that archives puts every conversation saved
/// before it in the archive, once, and archiving keeps every line.
@MainActor
final class SessionArchiveTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "SessionArchiveTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SessionArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// A session as an earlier version wrote it: no archived field.
    private func saveEarlier(_ id: String, lines: [String]) throws -> SavedSession {
        let session = try save(id, lines: lines, updated: Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertFalse(String(decoding: try Data(contentsOf: folder.appendingPathComponent("\(id).json")), as: UTF8.self).contains("archived"))
        return session
    }

    @discardableResult
    private func save(_ id: String, lines: [String], updated: Date, archived: Date? = nil) throws -> SavedSession {
        var session = SavedSession(id: id, kind: .poki, client: nil, title: lines.first ?? "", started: updated, updated: updated, live: false, outcome: .done,
                                   entries: lines.enumerated().map { ChatEntry($0.offset.isMultiple(of: 2) ? .you($0.element, delivered: true) : .poki($0.element)) },
                                   calls: [])
        session.archived = archived
        try JSONEncoder().encode(session).write(to: folder.appendingPathComponent("\(id).json"))
        return session
    }

    private func launch() -> SessionStore { SessionStore(folder: folder, defaults: defaults) }

    func testUpgradeArchivesEveryEarlierConversationOnce() throws {
        let first = try saveEarlier("old-1", lines: ["Add oat milk to my list", "Added."])
        let second = try saveEarlier("old-2", lines: ["What iOS version is this?", "iOS 27.3."])

        let upgraded = launch()
        XCTAssertEqual(upgraded.listed.map(\.id), [], "the list starts empty after the upgrade")
        XCTAssertEqual(Set(upgraded.archivedSessions.map(\.id)), ["old-1", "old-2"])
        XCTAssertEqual(upgraded.session("old-1")?.entries, first.entries)
        XCTAssertEqual(upgraded.session("old-2")?.entries, second.entries)

        let later = try saveEarlier("after-upgrade", lines: ["Order my usual coffee"])
        let relaunched = launch()
        XCTAssertEqual(relaunched.listed.map(\.id), [later.id], "a conversation saved after the upgrade is not archived on the next launch")
        XCTAssertEqual(Set(relaunched.archivedSessions.map(\.id)), ["old-1", "old-2"], "the archive is kept on disk")
    }

    func testArchiveMigrationRetriesAfterWriteFailure() async throws {
        for deferred in [false, true] {
            let id = deferred ? "deferred" : "immediate"
            _ = try saveEarlier(id, lines: ["Keep this conversation"])
            defaults.removeObject(forKey: SessionStore.archivedEarlierKey)
            let failed = SessionStore(folder: folder, defaults: defaults, deferLoad: deferred,
                                      archiveWrite: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            await failed.waitUntilLoaded()
            XCTAssertFalse(defaults.bool(forKey: SessionStore.archivedEarlierKey))
            XCTAssertEqual(launch().archivedSessions.first { $0.id == id }?.entries.count, 1)
            XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        }
    }

    func testRetryDoesNotArchiveConversationsCreatedAfterFailedMigration() async throws {
        _ = try saveEarlier("old", lines: ["Before upgrade"])
        let failed = SessionStore(folder: folder, defaults: defaults,
                                  archiveWrite: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        await failed.waitUntilLoaded()
        XCTAssertFalse(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        _ = try saveEarlier("new", lines: ["Created after upgrade"])
        let retried = launch()
        XCTAssertTrue(retried.archivedSessions.contains { $0.id == "old" })
        XCTAssertTrue(retried.listed.contains { $0.id == "new" }, "A later conversation is not part of the upgrade migration")
    }

    func testExplicitUnarchiveAfterFailedMigrationSurvivesRetry() async throws {
        _ = try saveEarlier("old", lines: ["Before upgrade"])
        let failed = SessionStore(folder: folder, defaults: defaults,
                                  archiveWrite: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        await failed.waitUntilLoaded()
        failed.unarchive("old")
        failed.flush()
        let retried = launch()
        XCTAssertTrue(retried.listed.contains { $0.id == "old" })
        XCTAssertFalse(retried.archivedSessions.contains { $0.id == "old" })
    }

    func testUnreadableOldFileDoesNotAddLaterConversationToMigration() throws {
        let oldFile = folder.appendingPathComponent("old.json")
        try FileManager.default.createDirectory(at: oldFile, withIntermediateDirectories: false)
        let first = launch()
        XCTAssertFalse(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        XCTAssertTrue(first.listed.isEmpty)
        _ = try saveEarlier("new", lines: ["After upgrade"])
        try FileManager.default.removeItem(at: oldFile)
        _ = try saveEarlier("old", lines: ["Before upgrade"])
        let retried = launch()
        XCTAssertTrue(retried.listed.contains { $0.id == "new" })
        XCTAssertTrue(retried.archivedSessions.contains { $0.id == "old" })
    }

    func testSessionCreatedWhileDirectoryUnavailableIsNotMigrated() throws {
        try FileManager.default.removeItem(at: folder)
        try Data("unavailable".utf8).write(to: folder)
        let first = launch()
        first.save(voice: "new", started: Date(), lines: [
            VoiceLine(role: .you, text: "New"),
            VoiceLine(role: .poki, text: "Reply")
        ], live: false)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        first.flush()
        _ = try saveEarlier("old", lines: ["Before upgrade"])
        let retried = launch()
        XCTAssertTrue(retried.listed.contains { $0.id == "new" })
        XCTAssertTrue(retried.archivedSessions.contains { $0.id == "old" })
    }

    func testMalformedOldFileDoesNotCompleteMigrationOrArchiveLaterSession() throws {
        try Data("{".utf8).write(to: folder.appendingPathComponent("old.json"))
        _ = launch()
        XCTAssertFalse(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        _ = try saveEarlier("new", lines: ["After upgrade"])
        _ = try saveEarlier("old", lines: ["Before upgrade"])
        let retried = launch()
        XCTAssertTrue(retried.listed.contains { $0.id == "new" })
        XCTAssertTrue(retried.archivedSessions.contains { $0.id == "old" })
    }

    func testFlushRetriesFailedSaveWithoutResurrectingDeletedConversation() throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        for id in ["keep", "delete"] { _ = try saveEarlier(id, lines: ["Conversation"]) }
        let store = launch()
        for id in ["keep", "delete"] {
            let file = folder.appendingPathComponent(id + ".json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            store.archive(id)
        }
        store.flush()
        for id in ["keep", "delete"] {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".json"))
        }
        store.delete("delete")
        store.flush()
        XCTAssertEqual(launch().archivedSessions.map(\.id), ["keep"])
    }

    func testRestoredModelContextIsBoundedAndRetainsNewestEvidence() {
        let old = String(repeating: "old transcript filler ", count: 280)
        let entries = (0..<60).map { index in
            ChatEntry(.poki("earlier \(index): \(old)"))
        } + [
            ChatEntry(.you("Inspect the current Settings page before proceeding", delivered: true)),
            ChatEntry(.step("The final read failed; delivery remains unknown", ok: false))
        ]
        let oversized = String(repeating: "old provider response ", count: 20_000)
        let calls = (0..<11).map { index in
            CallRecord(name: "look", arguments: #"{"screen":"Settings"}"#,
                       answer: oversized, ms: 120, ok: true)
        } + [
            CallRecord(name: "look", arguments: #"{"screen":"Settings"}"#,
                       answer: "Important recent output: FAILED_READ, no confirmation",
                       ms: 200, ok: false)
        ]
        let saved = SavedSession(id: "bounded", kind: .poki, client: nil, title: "Settings work",
                                 started: Date(), updated: Date(), live: false, outcome: .stopped,
                                 entries: entries, calls: calls)
        let context = saved.modelContext
        XCTAssertLessThan(context.count, 28_000, "restoring historical records must not inflate the model request")
        XCTAssertTrue(context.contains("Inspect the current Settings page"))
        XCTAssertTrue(context.contains("The final read failed; delivery remains unknown"))
        XCTAssertTrue(context.contains("Important recent output: FAILED_READ, no confirmation"))
        XCTAssertTrue(context.contains("[older tool output abbreviated]"), "imported oversized results must be shortened")
        XCTAssertTrue(context.contains("Last outcome: stopped"))
        XCTAssertFalse(context.contains("earlier 0:"), "oldest transcript rows should yield to recent ones")
        XCTAssertTrue(context.contains("an omitted result is unknown, not success"))
    }

    func testRestoredModelContextDoesNotDropOrdinaryShortHistory() {
        let entries = [
            ChatEntry(.you("Open Safari", delivered: true)),
            ChatEntry(.step("Safari opened", ok: true))
        ]
        let calls = [CallRecord(name: "look", arguments: "{}", answer: "Current app: Safari",
                                ms: 12, ok: true)]
        let saved = SavedSession(id: "short", kind: .poki, client: nil, title: "Safari",
                                 started: Date(), updated: Date(), live: false, outcome: .stopped,
                                 entries: entries, calls: calls)
        let context = saved.modelContext
        XCTAssertTrue(context.contains("Owner: Open Safari"))
        XCTAssertTrue(context.contains("Step (succeeded): Safari opened"))
        XCTAssertTrue(context.contains("Result (ok): Current app: Safari"))
    }

    func testFreshInstallArchivesNothing() throws {
        let installed = launch()
        XCTAssertTrue(installed.sessions.isEmpty)
        let later = try saveEarlier("first-chat", lines: ["Hi"])
        XCTAssertEqual(launch().listed.map(\.id), [later.id])
    }

    func testUnarchivedConversationStaysListedAfterRelaunch() throws {
        _ = try saveEarlier("old-1", lines: ["Add oat milk to my list", "Added."])
        _ = try saveEarlier("old-2", lines: ["What iOS version is this?", "iOS 27.3."])
        let upgraded = launch()
        upgraded.unarchive("old-1")
        upgraded.flush()

        for _ in 0..<2 {
            let relaunched = launch()
            XCTAssertEqual(relaunched.listed.map(\.id), ["old-1"], "brought back stays back")
            XCTAssertEqual(relaunched.archivedSessions.map(\.id), ["old-2"])
        }
    }

    func testArchivingKeepsEveryLine() throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        let saved = try saveEarlier("chat", lines: ["Send “On my way” to Mom", "Sent.", "Thanks", "Any time."])
        let store = launch()
        XCTAssertEqual(store.listed.map(\.id), ["chat"])
        store.archive("chat")
        store.flush()

        let relaunched = launch()
        XCTAssertEqual(relaunched.listed.map(\.id), [])
        XCTAssertEqual(relaunched.session("chat")?.entries, saved.entries)
        XCTAssertEqual(relaunched.session("chat")?.name, saved.name)
        relaunched.unarchive("chat")
        relaunched.flush()
        XCTAssertEqual(launch().session("chat")?.entries, saved.entries)
    }

    /// Archiving and deleting say which conversation left the list, each time, so the screen showing it leaves it.
    func testArchiveAndDeleteSayWhichConversationLeft() throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        _ = try saveEarlier("one", lines: ["Open Maps", "Opened."])
        _ = try saveEarlier("two", lines: ["Open Notes", "Opened."])
        let store = launch()
        XCTAssertNil(store.removed)
        store.archive("one")
        XCTAssertEqual(store.removed?.id, "one")
        let first = store.removed
        store.delete("two")
        XCTAssertEqual(store.removed?.id, "two")
        store.unarchive("one")
        store.archive("one")
        XCTAssertEqual(store.removed?.id, "one")
        XCTAssertNotEqual(store.removed, first, "the same conversation leaving again is a new change")
    }

    /// The limit is on the conversations list only: past it, the oldest listed conversation goes, and an
    /// archived one, older than all of them, stays with every line.
    func testTheLimitNeverTakesAnArchivedConversation() throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let archived = try (0..<5).map { try save("archived-\($0)", lines: ["Old task \($0)", "Done."], updated: start.addingTimeInterval(Double($0)), archived: start) }
        for i in 0...SessionStore.limit { try save("listed-\(i)", lines: ["Task \(i)"], updated: start.addingTimeInterval(1000 + Double(i))) }

        let store = launch()
        XCTAssertEqual(store.listed.count, SessionStore.limit)
        XCTAssertNil(store.session("listed-0"), "the oldest listed conversation is the one over the limit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("listed-0.json").path))
        XCTAssertEqual(Set(store.archivedSessions.map(\.id)), Set(archived.map(\.id)), "no archived conversation is taken")
        let relaunched = launch()
        for session in archived { XCTAssertEqual(relaunched.session(session.id)?.entries, session.entries) }
    }

    /// A conversation brought back from the archive counts as new from that moment for the limit: a full
    /// list does not drop it at once for its old date.
    func testAConversationJustUnarchivedIsNotTheOldestForTheLimit() throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let old = try save("old", lines: ["Book a table", "Booked."], updated: start, archived: start)
        for i in 0..<SessionStore.limit { try save("listed-\(i)", lines: ["Task \(i)"], updated: start.addingTimeInterval(1000 + Double(i))) }

        let store = launch()
        store.unarchive("old")
        store.flush()

        let relaunched = launch()
        XCTAssertEqual(relaunched.listed.count, SessionStore.limit)
        XCTAssertEqual(relaunched.session("old")?.entries, old.entries, "the conversation just brought back stays")
        XCTAssertNil(relaunched.session("listed-0"), "the oldest of the others goes instead")
    }
}
