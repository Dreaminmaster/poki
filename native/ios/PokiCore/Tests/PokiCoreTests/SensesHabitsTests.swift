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

    func testReadsCloseTogetherAreOneUse() {
        let s = [SensesSighting(at: at(daysAgo: 1, hour: 9), app: "com.spotify.client"),
                 SensesSighting(at: at(daysAgo: 1, hour: 9, minute: 20), app: "com.spotify.client"),
                 SensesSighting(at: at(daysAgo: 1, hour: 9, minute: 45), app: "com.spotify.client"),
                 SensesSighting(at: at(daysAgo: 1, hour: 11), app: "com.spotify.client")]
        XCTAssertEqual(SensesHabits.uses(s, now: now)["com.spotify.client"]?.count, 2)
    }

    func testUsualMusicAppNeedsAClearLead() {
        var s: [SensesSighting] = []
        for day in 1...4 { s.append(SensesSighting(at: at(daysAgo: day, hour: 20), app: "com.spotify.client")) }
        s.append(SensesSighting(at: at(daysAgo: 2, hour: 8), app: "com.apple.Music"))
        let habits = SensesHabits.habits(from: SensesHabits.uses(s, now: now), now: now, calendar: calendar)
        XCTAssertTrue(habits.contains { $0.kind == .usual(.music) && $0.app == "com.spotify.client" })

        // About as much of another music app: no usual app.
        for day in 1...3 { s.append(SensesSighting(at: at(daysAgo: day, hour: 13), app: "com.apple.Music")) }
        let tied = SensesHabits.habits(from: SensesHabits.uses(s, now: now), now: now, calendar: calendar)
        XCTAssertFalse(tied.contains { if case .usual(.music) = $0.kind { true } else { false } })
    }

    func testAgentReadsAreLeftOut() {
        var s: [SensesSighting] = []
        var spans: [SensesAgentSpan] = []
        for day in 1...4 {
            s.append(SensesSighting(at: at(daysAgo: day, hour: 20, minute: 5), app: "com.spotify.client"))
            spans.append(SensesAgentSpan(app: "com.spotify.client", from: at(daysAgo: day, hour: 20), to: at(daysAgo: day, hour: 20, minute: 1)))
        }
        XCTAssertTrue(SensesHabits.uses(s, agentSpans: spans, now: now).isEmpty)
    }

    func testRoutineAndDaily() {
        var s: [SensesSighting] = []
        for day in 1...5 { s.append(SensesSighting(at: at(daysAgo: day, hour: 7), app: "com.duolingo.DuolingoMobile")) }
        for day in 0...6 { s.append(SensesSighting(at: at(daysAgo: day, hour: [9, 14, 19, 22, 10, 15, 20][day]), app: "com.reddit.Reddit")) }
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
