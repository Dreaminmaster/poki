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
        let session = SavedSession(id: id, kind: .poki, client: nil, title: lines.first ?? "", started: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                   updated: Date(timeIntervalSinceReferenceDate: 800_000_000), live: false, outcome: .done,
                                   entries: lines.enumerated().map { ChatEntry($0.offset.isMultiple(of: 2) ? .you($0.element, delivered: true) : .poki($0.element)) },
                                   calls: [])
        let data = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("archived"))
        try data.write(to: folder.appendingPathComponent("\(id).json"))
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
}
