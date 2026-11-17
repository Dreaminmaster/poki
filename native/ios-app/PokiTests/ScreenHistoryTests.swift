import PokiCore
import XCTest
@testable import Poki

/// Screen History keeps only what the owner allows: a left-out app or the Home Screen leaves no read
/// and no line in the record, a fresh install leaves out passwords, payments, messages and Apple's
/// sign-in sheet, and clearing everything leaves nothing behind. Reads go in as the launcher sends
/// them, through the same call a run makes.
@MainActor
final class ScreenHistoryTests: XCTestCase {
    private let keys = ["history.enabled", "history.listMode", "history.excluded", "history.included"]
    private var saved: [String: Any] = [:]
    private var savedLanguage = AppLocalization.system

    override func setUp() async throws {
        savedLanguage = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        HistoryCapture.shared.enabled = false
        await HistoryStore.shared.deleteEverything()
    }

    override func tearDown() async throws {
        await HistoryStore.shared.deleteEverything()
        HistoryCapture.shared.enabled = false
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AppLocalization.shared.preference = savedLanguage
    }

    /// A read as the launcher reports it for a screen whose text changed.
    private func read(_ app: String, _ text: [String]) -> [String: Any] {
        ["ok": true, "app": app, "title": "", "text": text, "changed": true]
    }

    func testALeftOutAppAndTheHomeScreenLeaveNothingInTheStore() async {
        let capture = HistoryCapture()
        capture.exclude("com.example.bank")
        let start = Date()
        XCTAssertFalse(capture.keep(read("com.example.bank", ["Balance", "12,480.00"])))
        XCTAssertFalse(capture.keep(read("com.apple.springboard", ["Notification", "Messages, now, Your code is 482913"])))
        let reads = await HistoryStore.shared.recent()
        let record = await HistoryStore.shared.records().filter { $0.at >= start }
        XCTAssertEqual(reads.map(\.text), [])
        XCTAssertEqual(record.map(\.kind), [])
    }

    func testAFreshInstallLeavesOutPasswordsPaymentsMessagesAndAppleSignIn() async {
        let capture = HistoryCapture()
        for app in ["com.apple.MobileSMS", "com.tencent.xin", "com.apple.Passwords", "com.alipay.iphoneclient", "com.apple.AuthKitUIService"] {
            XCTAssertFalse(capture.keep(read(app, ["Your code is 482913"])), app)
        }
        XCTAssertTrue(capture.keep(read("com.apple.mobilenotes", ["Shopping list"])))
        let reads = await HistoryStore.shared.recent()
        XCTAssertEqual(reads.map(\.app), ["com.apple.mobilenotes"])
    }

    func testReadsWithoutABundleIDLeaveNothingInTheStore() async {
        let capture = HistoryCapture()
        let unknown = ["", "Notes", "no app name, pid 412", "com.example bank", "com..bank", ".com.bank", "com.bank.", "com.bank/app", "com.\u{94F6}\u{884C}"]
        for mode in HistoryCapture.ListMode.allCases {
            capture.listMode = mode
            capture.included = unknown
            for app in unknown {
                XCTAssertFalse(capture.keep(read(app, ["Private account details"])), app)
            }
            XCTAssertFalse(capture.keep(["ok": true, "text": ["Private account details"]]))
        }
        let reads = await HistoryStore.shared.recent()
        let record = await HistoryStore.shared.records()
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(record.isEmpty)
        capture.listMode = .exclude
        XCTAssertTrue(capture.keep(read("com.example.Bank-2", ["Public page"])))
    }

    func testASummaryFinishingAfterDeletionCannotRestoreForgottenText() async {
        let capture = HistoryCapture()
        let store = HistoryStore.shared
        let start = Date().addingTimeInterval(-600)
        let end = start.addingTimeInterval(600)
        for clearAll in [true, false] {
            store.add(at: start, app: "com.apple.mobilenotes", title: "Notes", text: "Private shopping list")
            let generation = await store.summaryGeneration()
            let source = await store.entries(from: start, to: end)
            XCTAssertEqual(source.map(\.text), ["Private shopping list"])
            if clearAll {
                await capture.clearEverything()
            } else {
                await capture.delete(from: start, to: end)
            }
            let reads = await store.recent()
            XCTAssertTrue(reads.isEmpty)
            await store.keep(BacktapeNote(title: "Forgotten list", body: "Private shopping list"), start: start, generation: generation)
            let stale = await store.notes(from: .distantPast, to: .distantFuture)
            XCTAssertTrue(stale.isEmpty, "A late summary restored forgotten text")
            store.add(at: start, app: "com.apple.mobilenotes", title: "Notes", text: "New shopping list")
            let freshGeneration = await store.summaryGeneration()
            await store.keep(BacktapeNote(title: "New list", body: "New shopping list"), start: start, generation: freshGeneration)
            let fresh = await store.note(start: start)
            XCTAssertEqual(fresh?.title, "New list")
            await capture.clearEverything()
        }
    }

    func testClearingEverythingLeavesNoReadsSummariesOrRecord() async {
        let capture = HistoryCapture()
        HistoryStore.shared.add(at: Date(), app: "com.apple.mobilenotes", title: "Notes", text: "Shopping list")
        let generation = await HistoryStore.shared.summaryGeneration()
        await HistoryStore.shared.keep(BacktapeNote(title: "Shopping", body: "You wrote a list."), start: Date(timeIntervalSince1970: 1_800_000_000), generation: generation)
        HistoryStore.shared.note("leftOut", "com.example.bank")
        await capture.clearEverything()
        let size = await HistoryStore.shared.size()
        let notes = await HistoryStore.shared.notes(from: .distantPast, to: .distantFuture)
        let record = await HistoryStore.shared.records()
        XCTAssertEqual(size.entries, 0)
        XCTAssertEqual(notes.map(\.note.title), [])
        XCTAssertEqual(record.map(\.kind), [])
    }

    private struct DecodedHistoryResponse: Decodable {
        struct Item: Decodable {
            let app: String
            let at: String
            let endAt: String?
            let title: String?
            let text: String
        }
        let entries: [Item]
        let matched: Int
        let returned: Int
        let truncated: Bool
    }

    private func decodeHistoryJSON(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> DecodedHistoryResponse {
        let data = Data(raw.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], raw, file: file, line: line)
        XCTAssertEqual(Set(object.keys), ["entries", "matched", "returned", "truncated"], raw, file: file, line: line)
        let rawEntries = try XCTUnwrap(object["entries"] as? [[String: Any]], raw, file: file, line: line)
        let allowedKeys: Set<String> = ["app", "at", "endAt", "title", "text"]
        for entry in rawEntries {
            XCTAssertTrue(Set(entry.keys).isSubset(of: allowedKeys), "Unexpected entry keys in \(entry)", file: file, line: line)
            XCTAssertNil(entry["tree"], file: file, line: line)
            XCTAssertNil(entry["id"], file: file, line: line)
            XCTAssertNil(entry["bundleID"], file: file, line: line)
        }
        return try JSONDecoder().decode(DecodedHistoryResponse.self, from: data)
    }

    func testScreenHistoryToolIsUnavailableWhenTheSwitchIsOff() async throws {
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: "Secret draft")
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let core = PokiCore(config: CoreConfig(screenHistory: HistoryStore.agentSource), host: AppCoreHost())
        func mcpTools() async throws -> [String] {
            let reply = await core.handle(RelayRequest(id: "1", method: "POST", headers: [:], body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])
            let result = try XCTUnwrap(body["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }

        let listedOff = try await mcpTools()
        XCTAssertFalse(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertFalse(Harness.splitViewTools.map(\.name).contains("screen_history"))
        XCTAssertFalse(listedOff.contains("screen_history"))
        XCTAssertFalse(Harness.instructions(for: "我刚才在备忘录里写了什么").contains("screen_history"))
        XCTAssertFalse(Harness.instructions(for: "我刚才在备忘录里写了什么", inSplitView: true).contains("screen_history"))
        let initial = await app.runTool("screen_history", arguments: "{}")
        XCTAssertTrue(initial.isError)
        XCTAssertEqual(initial.text, "Screen History is not turned on.")
        XCTAssertFalse(initial.text.contains("Secret draft"))

        HistoryCapture.shared.enabled = true
        let listedOn = try await mcpTools()
        XCTAssertTrue(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertTrue(Harness.splitViewTools.map(\.name).contains("screen_history"))
        XCTAssertTrue(listedOn.contains("screen_history"))
        XCTAssertTrue(Harness.instructions(for: "我刚才在备忘录里写了什么").contains("screen_history"))
        XCTAssertTrue(Harness.instructions(for: "我刚才在备忘录里写了什么", inSplitView: true).contains("screen_history"))

        HistoryCapture.shared.enabled = false
        let listedOffAgain = try await mcpTools()
        XCTAssertFalse(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertFalse(listedOffAgain.contains("screen_history"))
        let turnedOff = await app.runTool("screen_history", arguments: "{}")
        XCTAssertTrue(turnedOff.isError)
        XCTAssertEqual(turnedOff.text, "Screen History is not turned on.")
    }

    func testScreenHistoryToolQueriesStoredReadsByTimeSpanAppAndKeyword() async throws {
        let now = Date()
        let calendar = Calendar.current
        let todayFiveAM = try XCTUnwrap(calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now))
        let morningStart = now < todayFiveAM
            ? try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: todayFiveAM))
            : todayFiveAM
        let morningReadAt = morningStart.addingTimeInterval(min(3600, max(60, now.timeIntervalSince(morningStart) / 2)))
        let yesterdayAfternoon = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!))
        let twoAndHalfHoursAgo = now.addingTimeInterval(-9000)
        let twentyMinutesAgo = now.addingTimeInterval(-1200)
        let tenMinutesAgo = now.addingTimeInterval(-600)
        let treeBlob = Data(#"[[0,"Window","HiddenTreeMarker","",0,0,402,874]]"#.utf8)

        HistoryStore.shared.add(at: yesterdayAfternoon, app: "com.apple.weather", title: "Weather", text: "Rain tomorrow in Tokyo")
        HistoryStore.shared.add(at: morningReadAt, app: "com.apple.mobilesafari", title: "Benchmarks", text: "SQLite WAL 420k ops")
        HistoryStore.shared.add(at: twoAndHalfHoursAgo, app: "com.apple.Maps", title: "Search", text: "Cedar Street Bakery")
        HistoryStore.shared.add(
            at: twentyMinutesAgo,
            app: "com.atebits.Tweetie2",
            title: "Home",
            text: "For you\nFollowing\nZero-copy SQLite parser landed\nVertical scroll bar, 3 pages\n0%\nadd",
            tree: treeBlob
        )
        HistoryStore.shared.add(
            at: twentyMinutesAgo.addingTimeInterval(5),
            app: "com.atebits.Tweetie2",
            title: "Home",
            text: "For you\nFollowing\nZero-copy SQLite parser landed\nBenchmarks look solid\nVertical scroll bar, 3 pages\n25%\nadd",
            tree: treeBlob
        )
        HistoryStore.shared.add(
            at: twentyMinutesAgo.addingTimeInterval(10),
            app: "com.atebits.Tweetie2",
            title: "Home",
            text: "For you\nFollowing\nZero-copy SQLite parser landed\nBenchmarks look solid\nVertical scroll bar, 3 pages\n50%\nadd",
            tree: treeBlob
        )
        HistoryStore.shared.add(at: tenMinutesAgo, app: "com.apple.mobilenotes", title: "Groceries", text: "Buy oat milk and figs")

        HistoryCapture.shared.enabled = true
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())

        let lastHour = await app.runTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(lastHour.isError, lastHour.text)
        XCTAssertFalse(lastHour.text.contains("com.atebits.Tweetie2"), lastHour.text)
        XCTAssertFalse(lastHour.text.contains("HiddenTreeMarker"), lastHour.text)
        XCTAssertFalse(lastHour.text.contains("Vertical scroll bar"), lastHour.text)
        let lastHourParsed = try decodeHistoryJSON(lastHour.text)
        XCTAssertFalse(lastHourParsed.truncated)
        XCTAssertEqual(lastHourParsed.matched, 2)
        XCTAssertEqual(lastHourParsed.returned, 2)
        XCTAssertEqual(lastHourParsed.entries.map(\.app), ["X", "Notes"])
        XCTAssertNotNil(lastHourParsed.entries[0].endAt)
        XCTAssertEqual(lastHourParsed.entries[0].title, "Home")
        XCTAssertEqual(
            lastHourParsed.entries[0].text,
            "For you\nFollowing\nZero-copy SQLite parser landed\nBenchmarks look solid"
        )
        XCTAssertNil(lastHourParsed.entries[1].endAt)
        XCTAssertEqual(lastHourParsed.entries[1].title, "Groceries")
        XCTAssertEqual(lastHourParsed.entries[1].text, "Buy oat milk and figs")

        let morning = await app.runTool("screen_history", arguments: #"{"period":"morning"}"#)
        XCTAssertFalse(morning.isError, morning.text)
        let morningParsed = try decodeHistoryJSON(morning.text)
        XCTAssertTrue(morningParsed.entries.contains(where: { $0.app == "Safari" && $0.text.contains("SQLite WAL 420k ops") }), morning.text)
        XCTAssertFalse(morningParsed.entries.contains(where: { $0.text.contains("Rain tomorrow in Tokyo") }), morning.text)

        let iso = ISO8601DateFormatter()
        let spanArgs = try JSONSerialization.data(withJSONObject: [
            "start": iso.string(from: twoAndHalfHoursAgo.addingTimeInterval(-60)),
            "end": iso.string(from: twoAndHalfHoursAgo.addingTimeInterval(60)),
        ])
        let span = await app.runTool("screen_history", arguments: String(decoding: spanArgs, as: UTF8.self))
        XCTAssertFalse(span.isError, span.text)
        let spanParsed = try decodeHistoryJSON(span.text)
        XCTAssertEqual(spanParsed.entries.map(\.app), ["Maps"])
        XCTAssertEqual(spanParsed.entries.first?.text, "Cedar Street Bakery")

        AppLocalization.shared.preference = "zh-Hans"
        let byChineseApp = await app.runTool("screen_history", arguments: #"{"app":"备忘录"}"#)
        XCTAssertFalse(byChineseApp.isError, byChineseApp.text)
        let chineseAppParsed = try decodeHistoryJSON(byChineseApp.text)
        XCTAssertEqual(chineseAppParsed.entries.map(\.app), ["备忘录"])
        XCTAssertEqual(chineseAppParsed.entries.map(\.text), ["Buy oat milk and figs"])
        AppLocalization.shared.preference = "en"

        let byKeyword = await app.runTool("screen_history", arguments: #"{"query":"figs"}"#)
        XCTAssertFalse(byKeyword.isError, byKeyword.text)
        let keywordParsed = try decodeHistoryJSON(byKeyword.text)
        XCTAssertEqual(keywordParsed.entries.map(\.text), ["Buy oat milk and figs"])
    }

    func testScreenHistoryToolTruncatesAtEntryAndLengthCaps() async throws {
        let now = Date()
        let padding = String(repeating: "detail ", count: 30)
        for index in 1...65 {
            let at = now.addingTimeInterval(Double(index - 70) * 30)
            HistoryStore.shared.add(at: at, app: "com.apple.mobilenotes", title: "Notes", text: "Note-\(index): \(padding)")
        }

        HistoryCapture.shared.enabled = true
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())

        let byLimit = await app.runTool("screen_history", arguments: #"{"period":"last_hour","limit":3}"#)
        XCTAssertFalse(byLimit.isError, byLimit.text)
        let limitParsed = try decodeHistoryJSON(byLimit.text)
        XCTAssertEqual(limitParsed.matched, 65)
        XCTAssertEqual(limitParsed.returned, 3)
        XCTAssertTrue(limitParsed.truncated)
        XCTAssertEqual(limitParsed.entries.count, 3)
        XCTAssertTrue(limitParsed.entries[0].text.hasPrefix("Note-63:"))
        XCTAssertTrue(limitParsed.entries[1].text.hasPrefix("Note-64:"))
        XCTAssertTrue(limitParsed.entries[2].text.hasPrefix("Note-65:"))

        let byTotalLength = await app.runTool("screen_history", arguments: #"{"period":"last_hour","limit":500}"#)
        XCTAssertFalse(byTotalLength.isError, byTotalLength.text)
        XCTAssertLessThanOrEqual(byTotalLength.text.count, 4000)
        let totalLengthParsed = try decodeHistoryJSON(byTotalLength.text)
        XCTAssertEqual(totalLengthParsed.matched, 65)
        XCTAssertLessThan(totalLengthParsed.returned, 65)
        XCTAssertTrue(totalLengthParsed.truncated)
        XCTAssertEqual(totalLengthParsed.entries.count, totalLengthParsed.returned)
        XCTAssertTrue(totalLengthParsed.entries.last?.text.hasPrefix("Note-65:") == true)
        XCTAssertFalse(totalLengthParsed.entries.contains(where: { $0.text.hasPrefix("Note-1:") }))

        let giantBody = String(repeating: "a", count: 3000) + " needle-marker " + String(repeating: "b", count: 3000)
        HistoryStore.shared.add(at: now.addingTimeInterval(-10), app: "com.apple.mobilenotes", title: "Long", text: giantBody)
        let giantResult = await app.runTool("screen_history", arguments: #"{"period":"last_hour","query":"needle-marker"}"#)
        XCTAssertFalse(giantResult.isError, giantResult.text)
        XCTAssertLessThanOrEqual(giantResult.text.count, 4000)
        let giantParsed = try decodeHistoryJSON(giantResult.text)
        XCTAssertTrue(giantParsed.truncated)
        XCTAssertEqual(giantParsed.entries.count, 1)
        XCTAssertTrue(giantParsed.entries[0].text.contains("needle-marker"))
    }
    /// A permission decision made before an asynchronous SQLite read must not authorize
    /// the answer after the owner turns Screen History off.
    func testInFlightScreenHistoryQueryIsRevokedWhenTurnedOff() async {
        await assertRevokedPendingQuery(change: .turnOff)
    }

    /// Turning Screen History back on grants new queries, never the old in-flight one.
    func testInFlightScreenHistoryQueryCannotSurviveOffThenOn() async {
        await assertRevokedPendingQuery(change: .turnOffThenOn)
    }

    /// Changing the included/excluded apps must also invalidate a pending answer.
    func testInFlightScreenHistoryQueryIsRevokedOnAppPermissionChange() async {
        await assertRevokedPendingQuery(change: .changeAppScope)
    }

    /// Exercise the real HistoryCapture gate: tests using a fake source alone would miss
    /// a forgotten revision bump in the app's switch or exclusion-list wiring.
    func testHistoryCaptureInvalidatesQueriesOnRealPrivacySettingsChanges() async {
        let capture = HistoryCapture.shared
        capture.enabled = true
        XCTAssertTrue(HistoryCapture.agentQueryAllowed)
        let initial = HistoryCapture.accessRevision

        capture.listMode = capture.listMode == .exclude ? .include : .exclude
        let afterListMode = HistoryCapture.accessRevision
        XCTAssertNotEqual(initial, afterListMode)

        capture.exclude("com.example.sensitive-history-test")
        let afterExclusion = HistoryCapture.accessRevision
        XCTAssertNotEqual(afterListMode, afterExclusion)

        capture.enabled = false
        XCTAssertFalse(HistoryCapture.agentQueryAllowed)
        let afterStop = HistoryCapture.accessRevision
        capture.enabled = true
        XCTAssertNotEqual(afterStop, HistoryCapture.accessRevision)

        let beforeDeletion = HistoryCapture.accessRevision
        await capture.clearEverything()
        XCTAssertNotEqual(beforeDeletion, HistoryCapture.accessRevision)
    }

    private enum PendingPrivacyChange {
        case turnOff, turnOffThenOn, changeAppScope
    }

    private func assertRevokedPendingQuery(change: PendingPrivacyChange) async {
        let access = TestHistoryAccess()
        let delayedRead = SuspendedScreenHistoryRead()
        let source = ScreenHistorySource(
            isEnabled: { access.isEnabled },
            accessRevision: { access.revision },
            entries: { _, _ in await delayedRead.read() }
        )
        let core = PokiCore(config: CoreConfig(screenHistory: source), host: AppCoreHost())
        let query = Task { await core.callTool("screen_history", arguments: "{}") }

        await delayedRead.waitUntilStarted()
        switch change {
        case .turnOff:
            access.setEnabled(false)
        case .turnOffThenOn:
            access.setEnabled(false)
            access.setEnabled(true)
        case .changeAppScope:
            access.invalidateAppPermissions()
        }
        await delayedRead.finish([
            ScreenHistoryEntry(
                at: Date(),
                app: "Notes",
                bundleID: "com.apple.mobilenotes",
                text: "SYNTHETIC_PRIVATE_HISTORY_CANARY"
            )
        ])

        let answer = await query.value
        XCTAssertTrue(answer.isError, "A query started with an obsolete privacy decision must fail")
        XCTAssertFalse(answer.text.contains("SYNTHETIC_PRIVATE_HISTORY_CANARY"),
                       "Revoked screen text must never enter a tool result")
    }

}


/// An asynchronous source whose response is deliberately held until the test changes permissions.
/// Actor isolation makes the timing deterministic without sleeps or real screen contents.
private actor SuspendedScreenHistoryRead {
    private var started = false
    private var waitingForStart: CheckedContinuation<Void, Never>?
    private var pendingResponse: CheckedContinuation<[ScreenHistoryEntry], Never>?

    func read() async -> [ScreenHistoryEntry] {
        started = true
        waitingForStart?.resume()
        waitingForStart = nil
        return await withCheckedContinuation { continuation in
            pendingResponse = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waitingForStart = continuation
        }
    }

    func finish(_ entries: [ScreenHistoryEntry]) {
        pendingResponse?.resume(returning: entries)
        pendingResponse = nil
    }
}

/// Mimics the switch and app-permission changes without touching the user's own settings.
private final class TestHistoryAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var enabledValue = true
    private var revisionValue: UInt64 = 1

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledValue
    }

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revisionValue
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabledValue = value
        revisionValue &+= 1
        lock.unlock()
    }

    func invalidateAppPermissions() {
        lock.lock()
        revisionValue &+= 1
        lock.unlock()
    }
}
