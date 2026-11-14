import PokiCore
import XCTest
@testable import Poki

@MainActor
final class AgentConversationTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "AgentConversationTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentConversationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        // Not the first launch of the version that archives: saved conversations stay in the list.
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func launch() -> SessionStore { SessionStore(folder: folder, defaults: defaults) }

    private func call(_ store: SessionStore, client: String, connector: String?, step: String, failed: Bool = false, closes: Bool = true,
                      during: () -> Void = {}) {
        let session = UUID().uuidString.lowercased()
        store.observe(.session(.started(id: session, client: client, version: "1.0", connector: connector)), approvals: [])
        store.observe(.toolStarted(name: "do", summary: step, session: session), approvals: [])
        during()
        store.observe(.toolFinished(summary: step, delivery: failed ? "failed: error: the runner did not answer" : "sent", app: "Notes", thumbnail: nil, error: nil, session: session), approvals: [])
        if closes { store.observe(.session(.ended(id: session)), approvals: []) }
    }

    private func steps(_ session: SavedSession?) -> [String] {
        (session?.entries ?? []).compactMap { entry in
            guard case .step(let text, let ok) = entry.kind else { return nil }
            return ok == false ? "\(text) (failed)" : text
        }
    }

    func testOneRunOfAClientIsOneConversation() {
        let store = launch()
        let taps = (1...6).map { "Tap “Item \($0)”" }
        for tap in taps {
            call(store, client: "claude-ai", connector: "work", step: tap) {
                XCTAssertEqual(store.activeSessionID, store.listed.first?.id)
            }
        }
        XCTAssertEqual(store.listed.count, 1, "six calls, each in its own MCP session, are one conversation")
        XCTAssertEqual(store.listed.first?.name, "Claude")
        XCTAssertEqual(steps(store.listed.first), taps, "every call is in it, in order")
    }

    /// Concurrent MCP requests from the same client can share one conversation, while their
    /// completion events arrive out of order. They must never overwrite one another's receipts.
    func testOverlappingSessionsKeepTheirOwnStepResultsAndStayLiveUntilBothEnd() throws {
        let store = launch()
        let first = "overlap-first-" + UUID().uuidString
        let second = "overlap-second-" + UUID().uuidString
        for id in [first, second] {
            store.observe(.session(.started(id: id, client: "claude-ai", version: "1.0", connector: "work")), approvals: [])
        }
        store.observe(.toolStarted(name: "look", summary: "First request", session: first), approvals: [])
        store.observe(.toolStarted(name: "do", summary: "Second request", session: second), approvals: [])
        XCTAssertEqual(store.listed.count, 1)

        // The first step completes while the second is still pending. Before this fix,
        // the first result overwrote the second pending step because it was the latest.
        store.observe(.toolFinished(summary: "First read completed", delivery: "sent", app: "Safari",
                                    thumbnail: nil, error: nil, session: first), approvals: [])
        store.observe(.session(.ended(id: first)), approvals: [])
        let stillLive = try XCTUnwrap(store.listed.first)
        XCTAssertTrue(stillLive.live, "second MCP session remains active")
        store.archive(stillLive.id)
        XCTAssertNil(store.session(stillLive.id)?.archived, "an active shared conversation cannot be archived")

        store.observe(.toolFinished(summary: "Second tap failed", delivery: "failed: timeout", app: "Notes",
                                    thumbnail: nil, error: nil, session: second), approvals: [])
        let receipts = try XCTUnwrap(store.listed.first).entries.compactMap { entry -> (String, Bool?, String?)? in
            if case .step(let summary, let ok) = entry.kind { return (summary, ok, entry.app) }
            return nil
        }
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts[0].0, "First read completed")
        XCTAssertEqual(receipts[0].1, true)
        XCTAssertEqual(receipts[0].2, "Safari")
        XCTAssertEqual(receipts[1].0, "Second tap failed")
        XCTAssertEqual(receipts[1].1, false)
        XCTAssertEqual(receipts[1].2, "Notes")

        store.observe(.session(.ended(id: second)), approvals: [])
        XCTAssertFalse(try XCTUnwrap(store.listed.first).live)
    }

    func testEachClientAndEachConnectorKeepsItsOwnConversation() {
        let store = launch()
        for round in 1...3 {
            call(store, client: "claude-ai", connector: "work", step: "Claude at work \(round)")
            call(store, client: "chatgpt", connector: "work", step: "ChatGPT at work \(round)")
            call(store, client: "claude-ai", connector: "home", step: "Claude at home \(round)")
            call(store, client: "claude-ai", connector: nil, step: "Claude locally \(round)")
            call(store, client: "chatgpt", connector: nil, step: "ChatGPT locally \(round)")
        }
        XCTAssertEqual(store.listed.count, 5)
        XCTAssertEqual(Set(store.listed.map { steps($0) }), [
            (1...3).map { "Claude at work \($0)" },
            (1...3).map { "ChatGPT at work \($0)" },
            (1...3).map { "Claude at home \($0)" },
            (1...3).map { "Claude locally \($0)" },
            (1...3).map { "ChatGPT locally \($0)" },
        ])
        XCTAssertEqual(store.listed.map(\.name).sorted(), ["ChatGPT", "ChatGPT", "Claude", "Claude", "Claude"])
    }

    func testAClientBackMuchLaterBeginsANewConversationAndEarlierOnesStay() throws {
        let hourAgo = Date().addingTimeInterval(-3600), minuteAgo = Date().addingTimeInterval(-60)
        func saveEarlier(_ id: String, at time: Date, archived: Date? = nil) throws {
            var earlier = SavedSession(id: id, kind: .agent, client: "Claude", title: "Claude", started: time, updated: time, live: false, outcome: .done,
                                       entries: [ChatEntry(.time(time)), ChatEntry(.step("Earlier tap in \(id)", ok: true))], calls: [])
            earlier.connector = "work"
            earlier.archived = archived
            try JSONEncoder().encode(earlier).write(to: folder.appendingPathComponent("\(id).json"))
        }
        for n in 1...3 { try saveEarlier("earlier-\(n)", at: hourAgo) }
        try saveEarlier("put-away", at: minuteAgo, archived: minuteAgo)
        let store = launch()
        let before = store.sessions
        XCTAssertEqual(store.listed.count, 3)

        for n in 1...5 { call(store, client: "claude-ai", connector: "work", step: "Tap \(n) today") }

        XCTAssertEqual(store.listed.count, 4, "the run is one new conversation beside the three earlier ones")
        for earlier in before { XCTAssertEqual(store.session(earlier.id), earlier, "an earlier conversation is as it was saved") }
        XCTAssertEqual(steps(store.listed.first { !before.map(\.id).contains($0.id) }), (1...5).map { "Tap \($0) today" })
    }

    func testCallsInSessionsPokiNeverSawBeginAreOneConversation() {
        let store = launch()
        store.connectorAgent = { $0 == "work" ? "ChatGPT" : nil }
        for n in 1...5 { call(store, client: "", connector: "work", step: "Tap \(n)", closes: false) }
        XCTAssertEqual(store.listed.count, 1)
        XCTAssertEqual(store.listed.first?.name, "ChatGPT")
        XCTAssertEqual(steps(store.listed.first), (1...5).map { "Tap \($0)" })
    }

    func testAFailedCallAndAReconnectStayInTheConversation() {
        let store = launch()
        call(store, client: "claude-ai", connector: "work", step: "Open Notes", closes: false)
        call(store, client: "claude-ai", connector: "work", step: "Tap “Shopping”", failed: true, closes: false)
        let silent = UUID().uuidString.lowercased()
        store.observe(.session(.started(id: silent, client: "claude-ai", version: "1.0", connector: "work")), approvals: [])
        store.observe(.session(.ended(id: silent)), approvals: [])
        store.flush()
        let originalID = store.listed.first?.id
        let reconnected = launch()
        call(reconnected, client: "claude-ai", connector: "work", step: "Look at the screen")

        XCTAssertEqual(reconnected.listed.count, 1)
        XCTAssertEqual(reconnected.listed.first?.id, originalID)
        XCTAssertEqual(reconnected.listed.first?.name, "Claude")
        XCTAssertEqual(steps(reconnected.listed.first), ["Open Notes", "Tap “Shopping” (failed)", "Look at the screen"])
        reconnected.flush()
        XCTAssertEqual(launch().sessions, reconnected.sessions)
    }
}
