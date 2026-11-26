import XCTest
@testable import Poki

/// Imported backups never restore a running task engine. Keep interrupted
/// conversations resumable without inventing a successful task outcome.
@MainActor
final class SessionBackupRestoreTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "SessionBackupRestoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }

    private func backup(_ session: SavedSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }

    private func session(live: Bool, hasCard: Bool = true, offset: TimeInterval = 0) -> SavedSession {
        let time = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        var request = ChatEntry(.you("Review the saved task", delivered: true))
        request.at = time
        var card = ChatEntry(.plan([]))
        card.at = time
        card.ended = live ? nil : time
        var receipt = ChatEntry(.step("Earlier action was confirmed", ok: true))
        receipt.at = time
        return SavedSession(id: "restored", kind: .poki, client: nil, title: "Saved task",
                            started: time, updated: time, live: live, outcome: live ? nil : .done,
                            entries: hasCard ? [request, card, receipt] : [request, receipt], calls: [])
    }

    func testLiveBackupBecomesInterruptedAndResumableAfterReload() throws {
        let original = session(live: true)
        let store = SessionStore(folder: folder, defaults: defaults)
        defer { store.flush() }
        try store.restore(backup(original))
        let restored = try XCTUnwrap(store.session(original.id))
        XCTAssertFalse(restored.live)
        XCTAssertEqual(restored.outcome, .interrupted)
        XCTAssertEqual(restored.updated, original.updated)
        XCTAssertEqual(restored.entries[1].id, original.entries[1].id)
        XCTAssertEqual(restored.entries[1].ended, original.updated)
        XCTAssertEqual(restored.entries[1].interrupted, true)
        XCTAssertEqual(restored.entries[2], original.entries[2], "Keep the original action evidence")

        store.flush()
        let reopened = SessionStore(folder: folder, defaults: defaults)
        let persisted = try XCTUnwrap(reopened.session(original.id))
        XCTAssertEqual(persisted, restored)
        switch ChatContinuation.resolve("continue", current: original.id, choices: nil, sessions: reopened.sessions) {
        case .resume(let selected): XCTAssertEqual(selected.id, original.id)
        default: XCTFail("A restored interrupted task must remain resumable")
        }
    }

    func testMissingTaskCardIsAddedOnlyOnceOnBackupImport() throws {
        let original = session(live: true, hasCard: false)
        let store = SessionStore(folder: folder, defaults: defaults)
        defer { store.flush() }
        let data = try backup(original)
        try store.restore(data)
        let restored = try XCTUnwrap(store.session(original.id))
        XCTAssertEqual(restored.entries.count, original.entries.count + 1)
        guard restored.entries.indices.contains(1), case .plan = restored.entries[1].kind else {
            return XCTFail("Expected an interrupted task card")
        }
        XCTAssertEqual(restored.entries[1].interrupted, true)
        try store.restore(data)
        XCTAssertEqual(store.session(original.id), restored, "The same backup must not replace the task card")
    }

    func testCompletedLocalCopyWinsOverOlderLiveBackup() throws {
        let store = SessionStore(folder: folder, defaults: defaults)
        defer { store.flush() }
        let completed = session(live: false, offset: 60)
        try store.restore(backup(completed))
        try store.restore(backup(session(live: true)))
        XCTAssertEqual(store.session(completed.id), completed)
    }
}
