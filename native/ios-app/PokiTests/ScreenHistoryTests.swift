import PokiCore
import UIKit
import XCTest
import LocalAuthentication
import notify
@testable import Poki

/// Screen History keeps only what the owner allows: a left-out app or the Home Screen leaves no read
/// and no line in the record, a fresh install leaves out passwords, payments, messages and Apple's
/// sign-in sheet, and clearing everything leaves nothing behind. Reads go in as the launcher sends
/// them, through the same call a run makes.
@MainActor
final class ScreenHistoryTests: XCTestCase {
    private let keys = ["history.enabled", HistoryCapture.enabledKey, "history.listMode", "history.excluded", "history.included"]
    private var saved: [String: Any] = [:]
    private var savedLanguage = AppLocalization.system
    private var savedCaptureMode: HistoryCapture.ListMode = .exclude
    private var savedExcluded: [String] = []
    private var savedIncluded: [String] = []
    // Only a disposable, unenrolled simulator may create/use this fixture PIN.

    override func setUp() async throws {
        savedLanguage = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        // These test the query; the check before an answer leaves is SensesContext's.
        SensesContext.checksOutside = false
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        let capture = HistoryCapture.shared
        savedCaptureMode = capture.listMode
        savedExcluded = capture.excluded
        savedIncluded = capture.included
        capture.enabled = false
        HistoryLock.shared.lock()
        capture.listMode = .exclude
        capture.excluded = [Bundle.main.bundleIdentifier ?? "nz.zheha.poki"] + HistoryCapture.suggested
        capture.included = []
        await HistoryStore.shared.deleteEverything()
    }

    override func tearDown() async throws {
        HistoryLock.shared.lock()
        SensesContext.checksOutside = true
        await HistoryStore.shared.deleteEverything()
        HistoryCapture.shared.enabled = false
        HistoryCapture.shared.listMode = savedCaptureMode
        HistoryCapture.shared.excluded = savedExcluded
        HistoryCapture.shared.included = savedIncluded
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AppLocalization.shared.preference = savedLanguage
    }

    /// The production gate is opened by the real system prompt, not by a test-only bypass: the
    /// simulator enrolls Face ID and is told a matching face, as Features › Face ID › Matching Face does.
    /// Run these destructive history fixtures only on a disposable simulator.
    private func unlockHistoryForFixture() async throws {
        #if targetEnvironment(simulator)
        guard await openWithSimulatedFace() else {
            throw XCTSkip("The simulator's Face ID did not answer; use a disposable simulator.")
        }
        XCTAssertTrue(HistoryLock.shared.unlocked, "The real history lock must be open")
        #else
        throw XCTSkip("Screen history query fixtures require a disposable iOS simulator.")
        #endif
    }

    /// The system prompt, answered by the simulator's matching face.
    private func openWithSimulatedFace() async -> Bool {
        let lock = HistoryLock.shared
        if lock.unlocked { return true }
        Self.enrollSimulatorFaceID()
        lock.refresh()
        let prompt = Task { await lock.open() }
        for _ in 0..<60 where !lock.unlocked {
            notify_post("com.apple.BiometricKit_Sim.pearl.match")
            notify_post("com.apple.BiometricKit_Sim.fingerTouch.match")
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await prompt.value || lock.unlocked
    }

    private static func enrollSimulatorFaceID() {
        var token: Int32 = 0
        guard notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token) == NOTIFY_STATUS_OK else { return }
        _ = notify_set_state(token, 1)
        _ = notify_post("com.apple.BiometricKit.enrollmentChanged")
        _ = notify_cancel(token)
        let deadline = Date().addingTimeInterval(10)
        while !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// A read as the launcher reports it for a screen whose text changed.
    private func read(_ app: String, _ text: [String]) -> [String: Any] {
        ["ok": true, "app": app, "title": "", "text": text, "changed": true]
    }

    /// Insights may use the chat model (the owner, 2026-11-20), but what leaves for an agent is still
    /// checked by the model on this iPhone first, whichever Insights Model is picked.
    func testThePrivacyCheckRunsOnThisIPhoneWithEitherInsightsModel() async {
        let use = SensesUse.shared
        let savedModel = use.insightModel
        let defaults = UserDefaults.standard
        let approvalKeys = [ApprovalChoice.modeKey, "approvals.classifier.level", "approvals.ask"]
        let savedApprovals = approvalKeys.map { defaults.object(forKey: $0) }
        // Not Ask All, which asks the owner before any check runs.
        defaults.set("reply", forKey: ApprovalChoice.modeKey)
        defaults.set("balanced", forKey: "approvals.classifier.level")
        defaults.removeObject(forKey: "approvals.ask")
        SensesContext.checksOutside = true
        defer {
            for (key, value) in zip(approvalKeys, savedApprovals) { defaults.set(value, forKey: key) }
            use.insightModel = savedModel
            BacktapeWriter.testModel = nil
            SensesContext.checksOutside = false
        }
        for model in [SensesInsightModel.onDevice, .chat] {
            use.insightModel = model
            var asked: [String] = []
            BacktapeWriter.testModel = { _, instructions in asked.append(instructions); return "ASK | where the person is" }
            let verdict = await SensesContext.checkOutside("Coffee at the corner shop at 9", arguments: "{\"question\":\"morning\"}")
            XCTAssertEqual(verdict, .ask(reason: "where the person is"), "\(model)")
            XCTAssertTrue(asked.contains { $0.contains("You guard a person's privacy") }, "the check did not run with \(model)")
        }
    }

    func testLauncherReadPreparesTextAndTreeBeforeMainActorDelivery() throws {
        let rows = [[0, "Button", "Open", "", 1, 2, 3, 4] as [Any]]
        var line = read("com.example.reader", ["Café", "你好"])
        line["tree"] = rows
        let prepared = HistoryBridge.Read(line)
        XCTAssertEqual(prepared.text, "Café\n你好")
        let decoded = try JSONSerialization.jsonObject(with: XCTUnwrap(prepared.tree)) as? NSArray
        XCTAssertEqual(decoded, rows as NSArray)

        line.removeValue(forKey: "text")
        XCTAssertNil(HistoryBridge.Read(line).tree)
        line["text"] = ["Ignored"]
        line["ok"] = false
        XCTAssertNil(HistoryBridge.Read(line).text)
        XCTAssertNil(HistoryBridge.Read(line).tree)
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

    func testUpgradePersistsTheScreenHistorySwitchAndKeepsExistingHistoryQueryable() async throws {
        let defaults = UserDefaults.standard
        let legacyKey = "history.enabled"
        let recordingKey = HistoryCapture.enabledKey
        let savedText = "Screen text recorded before upgrading"
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: savedText)
        defaults.set(true, forKey: legacyKey)

        let capture = HistoryCapture()
        XCTAssertTrue(capture.enabled)
        XCTAssertEqual(defaults.object(forKey: recordingKey) as? Bool, true)
        XCTAssertFalse(HistoryCapture.agentQueryAllowed)
        try await unlockHistoryForFixture()
        let core = PokiCore(config: CoreConfig(screenHistory: HistoryStore.agentSource), host: AppCoreHost())
        let result = await core.callTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(savedText))

        capture.enabled = false
        XCTAssertFalse(HistoryCapture().enabled, "A later choice to turn recording off survives relaunch")
        XCTAssertEqual(defaults.object(forKey: recordingKey) as? Bool, false)

        defaults.set(false, forKey: legacyKey)
        defaults.removeObject(forKey: recordingKey)
        XCTAssertFalse(HistoryCapture().enabled, "An upgrade with Screen History off stays off")
        XCTAssertEqual(defaults.object(forKey: recordingKey) as? Bool, false)

        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: recordingKey)
        XCTAssertFalse(HistoryCapture().enabled, "Screen History starts off on a fresh install")
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
        XCTAssertFalse(Harness.taskInstructions(for: "我刚才在备忘录里写了什么").text.contains("screen_history"))
        XCTAssertFalse(Harness.taskInstructions(for: "我刚才在备忘录里写了什么", inSplitView: true).text.contains("screen_history"))
        let initial = await app.runTool("screen_history", arguments: "{}")
        XCTAssertTrue(initial.isError)
        XCTAssertEqual(initial.text, "Screen History is not turned on.")
        XCTAssertFalse(initial.text.contains("Secret draft"))

        try await unlockHistoryForFixture()
        HistoryCapture.shared.enabled = true
        let listedOn = try await mcpTools()
        // Outside agents get the query; Poki's own chat asks through personal_context, which a model on
        // this iPhone answers and checks before anything reaches the chat's model (SensesContext).
        XCTAssertFalse(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertFalse(Harness.splitViewTools.map(\.name).contains("screen_history"))
        XCTAssertTrue(Harness.tools.map(\.name).contains(SensesContext.name))
        XCTAssertTrue(listedOn.contains("screen_history"))
        XCTAssertFalse(Harness.taskInstructions(for: "我刚才在备忘录里写了什么").text.contains("screen_history"))
        XCTAssertTrue(Harness.taskInstructions(for: "我刚才在备忘录里写了什么").text.contains(SensesContext.name))
        XCTAssertTrue(Harness.taskInstructions(for: "我刚才在备忘录里写了什么", inSplitView: true).text.contains(SensesContext.name))

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

        try await unlockHistoryForFixture()
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

        try await unlockHistoryForFixture()
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
    
    func testInFlightScreenHistoryQueryIsRevokedWhenTurnedOff() async throws {
        try await assertRevokedPendingQuery(change: .turnOff)
    }

    func testInFlightScreenHistoryQueryCannotSurviveOffThenOn() async throws {
        try await assertRevokedPendingQuery(change: .turnOffThenOn)
    }

    func testInFlightScreenHistoryQueryIsRevokedOnAppPermissionChange() async throws {
        try await assertRevokedPendingQuery(change: .changeAppScope)
    }

    func testInFlightScreenHistoryQueryIsRevokedByActualDeletion() async throws {
        try await assertRevokedPendingQuery(change: .clear)
    }

    func testInFlightScreenHistoryQueryIsRevokedByLockThenUnlock() async throws {
        try await assertRevokedPendingQuery(change: .lockThenUnlock)
    }

    func testDeviceLockRevokesPendingReadEvenWhileCaptureIsIdle() async throws {
        try await assertRevokedPendingQuery(change: .deviceLock)
    }

    func testPasscodeSettingChangeRevokesPendingRead() async throws {
        try await assertRevokedPendingQuery(change: .changePasscode)
    }

    /// Exercise new queries through the app's actual core/SQLite source, not a fake source.
    func testLockedHistoryRefusesNewQueriesAndGrantsFreshReadsAfterUnlock() async throws {
        try await unlockHistoryForFixture()
        let capture = HistoryCapture.shared
        let lock = HistoryLock.shared
        capture.enabled = true
        let canary = "SYNTHETIC_FRESH_QUERY_ALLOWED"
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: canary)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let initial = await app.runTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(initial.isError, initial.text)
        XCTAssertTrue(initial.text.contains(canary), initial.text)

        lock.lock()
        XCTAssertFalse(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertFalse(Harness.splitViewTools.map(\.name).contains("screen_history"))
        XCTAssertFalse(Harness.taskInstructions(for: "Recall the earlier note").text.contains(PokiCore.screenHistoryInstructions))
        let locked = await app.runTool("screen_history", arguments: "{}")
        XCTAssertTrue(locked.isError)
        XCTAssertFalse(locked.text.contains(canary))

        let opened = await openWithSimulatedFace()

        XCTAssertTrue(opened)
        // Poki's own chat reads Screen History through personal_context only (Senses, 6600edd8): the
        // raw query stays for outside agents, whatever the lock says.
        XCTAssertFalse(Harness.tools.map(\.name).contains("screen_history"))
        XCTAssertTrue(Harness.tools.map(\.name).contains(SensesContext.name))
        let reopened = await app.runTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(reopened.isError, reopened.text)
        XCTAssertTrue(reopened.text.contains(canary))

        capture.enabled = false
        capture.enabled = true
        let fresh = await app.runTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(fresh.isError, fresh.text)
        XCTAssertTrue(fresh.text.contains(canary), fresh.text)
    }

    /// The chat uses this same validation after its core await and before persisting a call.
    func testCompletedHistoryAnswerCannotCrossARevokedChatDeliveryBoundary() async throws {
        try await unlockHistoryForFixture()
        HistoryCapture.shared.enabled = true
        let canary = "SYNTHETIC_CHAT_DELIVERY_CANARY"
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: canary)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let revision = HistoryCapture.agentQueryRevision
        let answer = await app.runTool("screen_history", arguments: #"{"period":"last_hour"}"#)
        XCTAssertFalse(answer.isError, answer.text)
        XCTAssertTrue(answer.text.contains(canary), answer.text)
        HistoryLock.shared.lock()
        let opened = await openWithSimulatedFace()
        XCTAssertTrue(opened)
        let safe = HistoryCapture.validateAgentAnswer(answer, revision: revision)
        XCTAssertTrue(safe.isError)
        XCTAssertFalse(safe.text.contains(canary))
    }

    /// The same Pi conversation must refresh its tool declaration during a running task.
    /// The second request was authorized; locking before its reply must prevent the raw
    /// tool result from being resent during the third and fourth requests.
    func testLiveModelRequestsRefreshHistoryToolsAndDiscardRevokedEvidence() async throws {
        try await unlockHistoryForFixture()
        let capture = HistoryCapture.shared
        capture.enabled = true
        let canary = "SYNTHETIC_MODEL_REQUEST_CANARY"
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: canary)
        let settings = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom"]
        let saved = settings.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(settings, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        let requestsSeen = HistoryFixtureCounter()
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("screen_history", ["period": "last_hour"]),
            FakeCompletions.tool("report_plan", ["steps": ["Check note", "Answer"], "currentStep": 1]),
            FakeCompletions.tool("report_plan", ["steps": ["Check note", "Answer"], "currentStep": 2]),
            FakeCompletions.text("Finished.")
        ], onRequest: { _ in
            let turn = requestsSeen.next()
            guard turn == 2 || turn == 3 else { return }
            // The fake server invokes this on its own serial network queue, before
            // it sends a reply, so the next model turn observes a deterministic change.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { HistoryCapture.shared.enabled = turn == 3 }
            }
        })
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        await SessionStore.shared.waitUntilLoaded()
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        app.inProcessReadyForProbe()
        let chat = ChatModel(app: app, kind: .handoff, requester: "History fixture")
        _ = await chat.runDelegated("Read the earlier note and tell me when done.")
        let requests = server.requests
        guard requests.count == 4 else {
            return XCTFail("Expected four actual model requests, got \(requests.count)")
        }
        func hasHistoryTool(_ request: [String: Any]) -> Bool {
            let tools = request["tools"] as? [[String: Any]] ?? []
            return tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "screen_history" }
        }
        func payload(_ request: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: request)) ?? Data(), as: UTF8.self)
        }
        // Since the Senses work (6600edd8) Poki's own chat never declares the raw screen_history
        // query, on or off: Screen History reaches it only through personal_context, answered and
        // checked on this iPhone. So no request offers the raw tool or carries its screen text, and
        // every one keeps personal_context, through the switch going off and on.
        func hasContextTool(_ request: [String: Any]) -> Bool {
            let tools = request["tools"] as? [[String: Any]] ?? []
            return tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == SensesContext.name }
        }
        for (turn, request) in requests.enumerated() {
            XCTAssertFalse(hasHistoryTool(request), "request \(turn) offers the raw screen_history query")
            XCTAssertTrue(hasContextTool(request), "request \(turn) lost personal_context")
            XCTAssertFalse(FakeCompletions.system(request).contains(PokiCore.screenHistoryInstructions), "request \(turn)")
            XCTAssertFalse(payload(request).contains(canary), "request \(turn) carries raw screen text")
        }
    }

    private enum PendingPrivacyChange {
        case turnOff, turnOffThenOn, changeAppScope, clear, lockThenUnlock, deviceLock, changePasscode
    }

    private func assertRevokedPendingQuery(change: PendingPrivacyChange) async throws {
        try await unlockHistoryForFixture()
        let capture = change == .deviceLock ? HistoryCapture() : HistoryCapture.shared
        let lock = HistoryLock.shared
        capture.enabled = true
        defer { if change == .deviceLock { capture.enabled = false } }
        let savedPasscode = lock.passcodeOn
        defer { if lock.passcodeOn != savedPasscode { _ = lock.changePasscode(savedPasscode) } }
        let canary = "SYNTHETIC_PRIVATE_HISTORY_CANARY"
        HistoryStore.shared.add(at: Date().addingTimeInterval(-120), app: "com.apple.mobilenotes", title: "Notes", text: canary)
        let delayedRead = SuspendedScreenHistoryRead()

        // Keep the production authorization and revision closures *unchanged*. The only
        // seam is a latch after the real SQLite read and production app filtering. A
        // constant accessRevision closure would now fail the off/on, clear and relock tests.
        var source = HistoryStore.agentSource
        let read = source.entries
        source.entries = { start, end in
            let actual = await read(start, end)
            return await delayedRead.hold(actual)
        }
        let core = PokiCore(config: CoreConfig(screenHistory: source), host: AppCoreHost())
        let query = Task { await core.callTool("screen_history", arguments: #"{"period":"last_hour"}"#) }

        guard let snapshot = await delayedRead.waitForSnapshot() else {
            await delayedRead.release()
            query.cancel()
            let answer = await query.value
            XCTFail("The production read did not reach the latch: \(answer.text)")
            return
        }
        XCTAssertTrue(snapshot.contains { $0.text.contains(canary) }, "The suspended snapshot must really contain the synthetic record")
        switch change {
        case .turnOff:
            capture.enabled = false
        case .turnOffThenOn:
            capture.enabled = false
            capture.enabled = true
        case .changeAppScope:
            capture.exclude("com.apple.mobilenotes")
        case .clear:
            await capture.clearEverything()
        case .lockThenUnlock:
            lock.lock()
            XCTAssertFalse(HistoryCapture.agentQueryAllowed)
            let opened = await openWithSimulatedFace()
            XCTAssertTrue(opened)
        case .deviceLock:
            XCTAssertFalse(capture.isRunning)
            NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            XCTAssertFalse(lock.unlocked, "Device lock must revoke even with no recording run")
            XCTAssertFalse(HistoryCapture.agentQueryAllowed)
            let early = await lock.open()
            XCTAssertFalse(early, "Protected data is still unavailable")
            NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            let opened = await openWithSimulatedFace()
            XCTAssertTrue(opened)
        case .changePasscode:
            // Changing how history opens closes it, with the read under way.
            XCTAssertTrue(lock.changePasscode(!savedPasscode))
        }
        await delayedRead.release()

        let answer = await query.value
        XCTAssertTrue(answer.isError, "A query with an obsolete privacy decision must fail")
        XCTAssertFalse(answer.text.contains(canary), "Revoked screen text must never enter a tool result")
    }
}

private final class HistoryFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Holds an actual read at a deterministic boundary, without touching its authorization.
/// A bounded wait reports an early refusal as a failure rather than hanging the entire suite.
private actor SuspendedScreenHistoryRead {
    private var snapshot: [ScreenHistoryEntry]?
    private var pending: CheckedContinuation<[ScreenHistoryEntry], Never>?
    private var released = false

    func hold(_ entries: [ScreenHistoryEntry]) async -> [ScreenHistoryEntry] {
        snapshot = entries
        if released { return entries }
        return await withCheckedContinuation { pending = $0 }
    }

    func waitForSnapshot() async -> [ScreenHistoryEntry]? {
        for _ in 0..<250 {
            if let snapshot { return snapshot }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return snapshot
    }

    func release() {
        released = true
        if let snapshot { pending?.resume(returning: snapshot) }
        pending = nil
    }
}
