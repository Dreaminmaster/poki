import XCTest
@testable import PokiCore

final class SensesHabitsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Noon on 2026-11-20 in New York.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))! }

    private func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Two reads 4 s apart, as the collector reads an app that comes to the front.
    private func visit(_ at: Date, _ app: String) -> [SensesSighting] {
        [SensesSighting(at: at, app: app), SensesSighting(at: at.addingTimeInterval(4), app: app)]
    }

    func testAGlanceIsNoUse() {
        let s = [SensesSighting(at: at(daysAgo: 1, hour: 9), app: "com.spotify.client")] + visit(at(daysAgo: 2, hour: 9), "com.spotify.client")
        XCTAssertEqual(SensesHabits.uses(s, now: now)["com.spotify.client"]?.count, 1)
    }

    func testReadsCloseTogetherAreOneUse() {
        let s = [SensesSighting(at: at(daysAgo: 1, hour: 9), app: "com.spotify.client"),
                 SensesSighting(at: at(daysAgo: 1, hour: 9, minute: 20), app: "com.spotify.client"),
                 SensesSighting(at: at(daysAgo: 1, hour: 9, minute: 45), app: "com.spotify.client")]
            + visit(at(daysAgo: 1, hour: 11), "com.spotify.client")
        XCTAssertEqual(SensesHabits.uses(s, now: now)["com.spotify.client"]?.count, 2)
    }

    func testUsualMusicAppNeedsAClearLead() {
        var s: [SensesSighting] = []
        for day in 1...4 { s += visit(at(daysAgo: day, hour: 20), "com.spotify.client") }
        s += visit(at(daysAgo: 2, hour: 8), "com.apple.Music")
        let habits = SensesHabits.habits(from: SensesHabits.uses(s, now: now), now: now, calendar: calendar)
        XCTAssertTrue(habits.contains { $0.kind == .usual(.music) && $0.app == "com.spotify.client" })

        // About as much of another music app: no usual app.
        for day in 1...3 { s += visit(at(daysAgo: day, hour: 13), "com.apple.Music") }
        let tied = SensesHabits.habits(from: SensesHabits.uses(s, now: now), now: now, calendar: calendar)
        XCTAssertFalse(tied.contains { if case .usual(.music) = $0.kind { true } else { false } })
    }

    func testAgentReadsAreLeftOut() {
        var s: [SensesSighting] = []
        var spans: [SensesAgentSpan] = []
        for day in 1...4 {
            s += visit(at(daysAgo: day, hour: 20, minute: 5), "com.spotify.client")
            spans.append(SensesAgentSpan(app: "com.spotify.client", from: at(daysAgo: day, hour: 20), to: at(daysAgo: day, hour: 20, minute: 1)))
        }
        XCTAssertTrue(SensesHabits.uses(s, agentSpans: spans, now: now).isEmpty)
    }

    func testRoutineAndDaily() {
        var s: [SensesSighting] = []
        for day in 1...5 { s += visit(at(daysAgo: day, hour: 7), "com.duolingo.DuolingoMobile") }
        for day in 0...6 { s += visit(at(daysAgo: day, hour: [9, 14, 19, 22, 10, 15, 20][day]), "com.reddit.Reddit") }
        let habits = SensesHabits.habits(from: SensesHabits.uses(s, now: now), now: now, calendar: calendar)
        XCTAssertTrue(habits.contains { $0.kind == .routine(.morning) && $0.app == "com.duolingo.DuolingoMobile" && $0.days == 5 })
        XCTAssertTrue(habits.contains { $0.kind == .daily && $0.app == "com.reddit.Reddit" })
    }

    func testOwnerWordsComeFirst() {
        let habit = SensesHabit(kind: .usual(.music), app: "com.spotify.client", uses: 4, days: 4, lastUse: now)
        let names: (String, String) -> Bool = { text, app in
            app == "com.apple.Music" && text.lowercased().contains("apple music")
        }
        XCTAssertEqual(SensesHabits.usualApp(for: "play some jazz music", habits: [habit], names: names)?.app, "com.spotify.client")
        XCTAssertNil(SensesHabits.usualApp(for: "play jazz music in Apple Music", habits: [habit], names: names))
        XCTAssertNil(SensesHabits.usualApp(for: "play jazz music", habits: [habit], names: names, notes: ["Always use Apple Music for songs"]))
        XCTAssertNotNil(SensesHabits.usualApp(for: "play jazz music", habits: [habit], names: names, notes: ["I like jazz music"]))
        XCTAssertNil(SensesHabits.usualApp(for: "set a timer", habits: [habit], names: names))
    }
}

final class ScreenHistoryCheckTests: XCTestCase {
    private func core(_ verdict: ScreenHistoryVerdict, wait: Double = 0.3) -> PokiCore {
        let source = ScreenHistorySource(
            isEnabled: { true },
            accessRevision: { 0 },
            entries: { _, _ in [ScreenHistoryEntry(at: Date().addingTimeInterval(-60), app: "Notes", bundleID: "com.apple.mobilenotes", title: "Trip", text: "Pack the passport")] },
            check: { _, _ in verdict })
        return makeCore { $0.approvalWait = wait; $0.screenHistory = source }.0
    }

    func testSharedAnswerPassesAndRefusedDoesNot() async {
        let shared = await core(.share).call("screen_history", [:])
        XCTAssertFalse(shared.isError)
        XCTAssertTrue(shared.text.contains("passport"))
        let refused = await core(.refuse("no")).call("screen_history", [:])
        XCTAssertTrue(refused.isError)
        XCTAssertFalse(refused.text.contains("passport"))
    }

    func testAskWaitsForTheOwner() async {
        let unanswered = await core(.ask(reason: "private")).call("screen_history", [:])
        XCTAssertTrue(unanswered.isError)
        XCTAssertFalse(unanswered.text.contains("passport"))

        let c = core(.ask(reason: "private"), wait: 5)
        Task {
            while c.pendingApproval == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            c.resolveApproval(id: c.pendingApproval!.id, approved: true)
        }
        let approved = await c.call("screen_history", [:])
        XCTAssertFalse(approved.isError)
        XCTAssertTrue(approved.text.contains("passport"))
    }

    /// History turned off or access changed while the check or the owner's answer was awaited: the
    /// text read before is not handed out, even when the owner then approves.
    func testAccessChangedDuringTheWaitSharesNothing() async {
        let revision = Revision()
        func source(_ verdict: ScreenHistoryVerdict, revokeInCheck: Bool) -> ScreenHistorySource {
            ScreenHistorySource(
                isEnabled: { true },
                accessRevision: { revision.value },
                entries: { _, _ in [ScreenHistoryEntry(at: Date().addingTimeInterval(-60), app: "Notes", bundleID: "com.apple.mobilenotes", title: "Trip", text: "Pack the passport")] },
                check: { _, _ in
                    if revokeInCheck { revision.value += 1 }
                    return verdict
                })
        }
        let shared = await makeCore { $0.screenHistory = source(.share, revokeInCheck: true) }.0.call("screen_history", [:])
        XCTAssertTrue(shared.isError)
        XCTAssertFalse(shared.text.contains("passport"), shared.text)

        let c = makeCore { $0.approvalWait = 5; $0.screenHistory = source(.ask(reason: "private"), revokeInCheck: false) }.0
        Task {
            while c.pendingApproval == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            revision.value += 1
            c.resolveApproval(id: c.pendingApproval!.id, approved: true)
        }
        let approved = await c.call("screen_history", [:])
        XCTAssertTrue(approved.isError)
        XCTAssertFalse(approved.text.contains("passport"), approved.text)
    }
}

private final class Revision: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    var value: UInt64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
