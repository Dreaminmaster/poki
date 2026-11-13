import Foundation
import XCTest
@testable import Poki

@MainActor
final class ConversationSearchTests: XCTestCase {
    private func sample(_ id: String = "first", name: String = "Trip planning", entries: [ChatEntry]) -> SavedSession {
        SavedSession(id: id, kind: .poki, client: nil, title: name, started: .now,
                     updated: .now, live: false, outcome: .done, entries: entries, calls: [])
    }

    func testFindsOlderMessageEvenWhenLastLineDoesNotMatch() {
        let old = ChatEntry(.you("明天下午去海港拍照", delivered: true))
        let newest = ChatEntry(.poki("Understood."))
        let session = sample(entries: [old, newest])
        let hits = ConversationSearchIndex.find(in: [session], query: "海港")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.entryID, old.id)
        XCTAssertTrue(hits.first?.detail.contains("海港") == true)
    }

    func testEnglishIsCaseInsensitiveAndAccentTolerant() {
        let older = ChatEntry(.poki("The café near the station is open."))
        let results = ConversationSearchIndex.find(in: [sample(entries: [older])], query: "CAFE")
        XCTAssertEqual(results.map(\.entryID), [older.id])
    }

    func testIncludesAgentRequestsPlansAndNotes() {
        let request = ChatEntry(.request("Find the museum", from: "Codex"))
        var plan = ChatEntry(.plan([PlanStep("Open the calendar"), PlanStep("Check the exhibition")]))
        plan.title = "Museum itinerary"
        let problem = ChatEntry(.note(.problem("The ticket website failed")))
        let session = sample(entries: [request, plan, problem])
        XCTAssertEqual(ConversationSearchIndex.find(in: [session], query: "museum").count, 2)
        XCTAssertEqual(ConversationSearchIndex.find(in: [session], query: "exhibition").first?.entryID, plan.id)
        XCTAssertEqual(ConversationSearchIndex.find(in: [session], query: "ticket").first?.entryID, problem.id)
    }

    func testMatchesTitleAndShowsAllSessionsForEmptyQuery() {
        let a = sample("a", name: "Sydney Harbour", entries: [ChatEntry(.poki("Done."))])
        let b = sample("b", name: "Grocery list", entries: [ChatEntry(.you("milk", delivered: true))])
        let titled = ConversationSearchIndex.find(in: [a, b], query: "harbour")
        XCTAssertEqual(titled.count, 1)
        XCTAssertNil(titled.first?.entryID)
        let all = ConversationSearchIndex.find(in: [a, b], query: "  ")
        XCTAssertEqual(all.map(\.session.id), ["a", "b"])
    }

    func testDeletedSessionsDoNotAppearAndLimitIsEnforced() {
        let a = sample("a", entries: (0..<20).map { ChatEntry(.you("find me \($0)", delivered: true)) })
        let b = sample("deleted", entries: [ChatEntry(.poki("find me"))])
        XCTAssertEqual(ConversationSearchIndex.find(in: [a], query: "find", limit: 5).count, 5)
        XCTAssertFalse(ConversationSearchIndex.find(in: [a], query: "find").contains { $0.session.id == b.id })
        XCTAssertTrue(ConversationSearchIndex.find(in: [a, b], query: "missing").isEmpty)
    }

    func testRestoringSavedJSONKeepsTheExactMessageTarget() throws {
        let target = ChatEntry(.you("Reserve a table for next Friday", delivered: true))
        let original = sample("roundtrip", entries: [target, ChatEntry(.poki("Done."))])
        let serialized = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SavedSession.self, from: serialized)
        XCTAssertEqual(ConversationSearchIndex.find(in: [restored], query: "friday").first?.entryID, target.id)
    }

    func testComputedLastLineRemainsSearchable() {
        let pending = ChatEntry(.note(.waiting))
        let session = sample(entries: [pending])
        let query = String(session.lastLine.prefix(5))
        let hits = ConversationSearchIndex.find(in: [session], query: query)
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits.first?.entryID)
    }

    func testSearchKeepsSpeakerIdentityWithoutEagerLocalization() {
        let user = ChatEntry(.you("language switch", delivered: true))
        let task = ChatEntry(.note(.problem("language switch")))
        let agent = ChatEntry(.request("language switch", from: "External agent"))
        let hits = ConversationSearchIndex.find(in: [sample(entries: [user, task, agent])], query: "language switch")
        XCTAssertEqual(hits.first(where: { $0.entryID == user.id })?.author, .you)
        XCTAssertEqual(hits.first(where: { $0.entryID == task.id })?.author, .task)
        XCTAssertEqual(hits.first(where: { $0.entryID == agent.id })?.author, .agent("External agent"))
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
