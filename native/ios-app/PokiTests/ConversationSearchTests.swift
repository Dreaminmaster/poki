import Foundation
import XCTest
@testable import Poki

@MainActor
final class ConversationSearchTests: XCTestCase {
    private func sample(_ id: String = "first", name: String = "Trip planning", entries: [ChatEntry]) -> SavedSession {
        SavedSession(id: id, kind: .poki, client: nil, title: name, started: .now,
                     updated: .now, live: false, outcome: .done, entries: entries, calls: [])
    }

    /// The real Settings search pipeline: snapshot -> background-safe filtering -> current-record resolve.
    /// Convenience lives in XCTest, not in the production search implementation.
    private func find(in sessions: [SavedSession], query: String,
                      limit: Int = ConversationSearchIndex.displayLimit) -> [ConversationSearchHit] {
        let snapshot = ConversationSearchIndex.snapshot(in: sessions)
        let matched = ConversationSearchIndex.search(snapshot, query: query, limit: limit)
        return ConversationSearchIndex.resolve(matched, in: sessions)
    }

    func testFindsOlderMessageEvenWhenLastLineDoesNotMatch() {
        let old = ChatEntry(.you("明天下午去海港拍照", delivered: true))
        let newest = ChatEntry(.poki("Understood."))
        let session = sample(entries: [old, newest])
        let hits = find(in: [session], query: "海港")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.entryID, old.id)
        XCTAssertTrue(hits.first?.detail.contains("海港") == true)
    }

    func testEnglishIsCaseInsensitiveAndAccentTolerant() {
        let older = ChatEntry(.poki("The café near the station is open."))
        let results = find(in: [sample(entries: [older])], query: "CAFE")
        XCTAssertEqual(results.map(\.entryID), [older.id])
    }

    func testIncludesAgentRequestsPlansAndNotes() {
        let request = ChatEntry(.request("Find the museum", from: "Codex"))
        var plan = ChatEntry(.plan([PlanStep("Open the calendar"), PlanStep("Check the exhibition")]))
        plan.title = "Museum itinerary"
        let problem = ChatEntry(.note(.problem("The ticket website failed")))
        let session = sample(entries: [request, plan, problem])
        XCTAssertEqual(find(in: [session], query: "museum").count, 2)
        XCTAssertEqual(find(in: [session], query: "exhibition").first?.entryID, plan.id)
        XCTAssertEqual(find(in: [session], query: "ticket").first?.entryID, problem.id)
    }

    func testMatchesTitleAndShowsAllSessionsForEmptyQuery() {
        let a = sample("a", name: "Sydney Harbour", entries: [ChatEntry(.poki("Done."))])
        let b = sample("b", name: "Grocery list", entries: [ChatEntry(.you("milk", delivered: true))])
        let titled = find(in: [a, b], query: "harbour")
        XCTAssertEqual(titled.count, 1)
        XCTAssertNil(titled.first?.entryID)
        let all = find(in: [a, b], query: "  ")
        XCTAssertEqual(all.map(\.session.id), ["a", "b"])
    }

    func testDeletedSessionsDoNotAppearAndLimitIsEnforced() {
        let a = sample("a", entries: (0..<20).map { ChatEntry(.you("find me \($0)", delivered: true)) })
        let b = sample("deleted", entries: [ChatEntry(.poki("find me"))])
        XCTAssertEqual(find(in: [a], query: "find", limit: 5).count, 5)
        XCTAssertFalse(find(in: [a], query: "find").contains { $0.session.id == b.id })
        XCTAssertTrue(find(in: [a, b], query: "missing").isEmpty)
    }

    func testArchivedOlderMessageAndDeletedRecordsUseTheProductionPipeline() {
        let older = ChatEntry(.you("Remember the late ferry from Circular Quay", delivered: true))
        var archived = sample("archived", name: "October travel", entries: [
            older, ChatEntry(.poki("All set"))
        ])
        archived.archived = Date(timeIntervalSince1970: 1_700_000_000)
        let active = sample("current", name: "Today", entries: [ChatEntry(.poki("Hello"))])
        let all = [active, archived]
        let snapshot = ConversationSearchIndex.snapshot(in: all)
        let rawHits = ConversationSearchIndex.search(snapshot, query: "late ferry")
        XCTAssertEqual(rawHits.map(\.sessionID), ["archived"])
        XCTAssertEqual(ConversationSearchIndex.resolve(rawHits, in: all).first?.entryID, older.id)
        XCTAssertTrue(find(in: all, query: "late ferry").first?.session.archived != nil)
        // The session may be deleted between the background search and main-actor resolution.
        XCTAssertTrue(ConversationSearchIndex.resolve(rawHits, in: [active]).isEmpty)
    }

    func testCancellationClearsPendingSearchWithoutReportingOldHits() async {
        let archive = sample("old", entries: [ChatEntry(.you("needle found", delivered: true))])
        let snapshot = ConversationSearchIndex.snapshot(in: [archive])
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ConversationSearchIndex.search(snapshot, query: "needle")
        }.value
        XCTAssertTrue(cancelled.isEmpty, "a cancelled search must not publish stale hits")
    }

    func testRestoringSavedJSONKeepsTheExactMessageTarget() throws {
        let target = ChatEntry(.you("Reserve a table for next Friday", delivered: true))
        let original = sample("roundtrip", entries: [target, ChatEntry(.poki("Done."))])
        let serialized = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SavedSession.self, from: serialized)
        XCTAssertEqual(find(in: [restored], query: "friday").first?.entryID, target.id)
    }

    func testComputedLastLineRemainsSearchable() {
        let pending = ChatEntry(.note(.waiting))
        let session = sample(entries: [pending])
        let query = String(session.lastLine.prefix(5))
        let hits = find(in: [session], query: query)
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits.first?.entryID)
    }

    func testSearchKeepsSpeakerIdentityWithoutEagerLocalization() {
        let user = ChatEntry(.you("language switch", delivered: true))
        let task = ChatEntry(.note(.problem("language switch")))
        let agent = ChatEntry(.request("language switch", from: "External agent"))
        let hits = find(in: [sample(entries: [user, task, agent])], query: "language switch")
        XCTAssertEqual(hits.first(where: { $0.entryID == user.id })?.author, .you)
        XCTAssertEqual(hits.first(where: { $0.entryID == task.id })?.author, .task)
        XCTAssertEqual(hits.first(where: { $0.entryID == agent.id })?.author, .agent("External agent"))
    }

    func testNewBrowserVisitsAndApprovalDetailsRemainSearchable() {
        var visit = BrowserVisit()
        visit.host = "sydney.edu.au"
        visit.title = "Campus events"
        let browser = ChatEntry(.browser(visit))
        let approval = ApprovalNote(id: "approval-1", summary: "Send course email",
                                    app: "Mail", why: "sending a message",
                                    byModel: false, state: .asking, reason: "",
                                    reply: false, answered: nil)
        let note = ChatEntry(.note(.approval(approval)))
        let session = sample(entries: [browser, note])

        let pageMatches = find(in: [session], query: "sydney.edu.au")
        XCTAssertEqual(pageMatches.first?.entryID, browser.id)
        XCTAssertEqual(pageMatches.first?.author, .browser)
        XCTAssertTrue(pageMatches.first?.detail.contains("Campus events") == true)

        let approvalMatches = find(in: [session], query: "course email")
        XCTAssertEqual(approvalMatches.first?.entryID, note.id)
        XCTAssertEqual(approvalMatches.first?.author, .task)
        XCTAssertEqual(find(in: [session], query: "sending a message").first?.entryID,
                       note.id)
    }

    func testMetadataAndLastLineMatchHaveOneStableResultID() {
        let session = sample("waiting", name: "Waiting", entries: [ChatEntry(.note(.waiting))])
        XCTAssertTrue(session.lastLine.localizedStandardContains("waiting"))
        let hits = find(in: [session], query: "waiting")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "waiting:title")
        XCTAssertNil(hits.first?.entryID)
    }

    func testSameImmutableIndexSupportsDifferentQueries() {
        let first = ChatEntry(.you("alpha note", delivered: true))
        let second = ChatEntry(.poki("beta answer"))
        let session = sample(entries: [first, second])
        let index = ConversationSearchIndex.snapshot(in: [session])
        XCTAssertEqual(ConversationSearchIndex.search(index, query: "alpha").first?.entryID, first.id)
        XCTAssertEqual(ConversationSearchIndex.search(index, query: "beta").first?.entryID, second.id)
        XCTAssertTrue(ConversationSearchIndex.search(index, query: "not present").isEmpty)
    }

    func testExcerptPreservesChineseAndBoundsLongMessages() {
        let content = String(repeating: "abc", count: 110) + " 海港日落 " + String(repeating: "def", count: 100)
        let snippet = ConversationSearchIndex.excerpt(content, around: "海港")
        XCTAssertTrue(snippet.contains("海港日落"))
        XCTAssertLessThan(snippet.count, content.count)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
    }
}
