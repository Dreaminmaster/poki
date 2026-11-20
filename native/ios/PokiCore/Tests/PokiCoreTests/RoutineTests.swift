import XCTest
@testable import PokiCore

/// Routines: a task's do actions are recorded, saved by name, replayed in one call that waits for each
/// target and stops at a screen that differs; notes; export and import.
final class RoutineTests: XCTestCase {
    /// Settings → General → About, a screen per tap.
    final class Pages: @unchecked Sendable {
        let wda: FakeWDA
        let page = LockedBox(0)
        var screens: [[Node]]
        init(_ wda: FakeWDA, _ screens: [[Node]]) {
            self.wda = wda
            self.screens = screens
            show(0)
            wda.set("POST /wda/tap") { [self] _ in
                let next = min(self.page.value + 1, self.screens.count - 1)
                self.show(next)
                return (200, ["value": .null])
            }
        }
        func show(_ i: Int) { page.value = i; wda.tree(screens[i], app: "Settings") }
    }

    static let home = [Node("Button", "General", [16, 100, 358, 44]), Node("Button", "Privacy", [16, 144, 358, 44])]
    static let general = [Node("NavigationBar", "General", [0, 50, 390, 44]), Node("Button", "About", [16, 100, 358, 44]), Node("Button", "Software Update", [16, 144, 358, 44])]
    static let about = [Node("NavigationBar", "About", [0, 50, 390, 44]), Node("StaticText", "iOS Version", [16, 100, 358, 44], value: "27.3"), Node("StaticText", "Model Name", [16, 144, 358, 44], value: "iPhone")]

    func core(_ store: RoutineStore = RoutineStore(url: nil)) -> (PokiCore, FakeWDA, Pages) {
        let wda = FakeWDA()
        let pages = Pages(wda, [Self.home, Self.general, Self.about])
        let (core, _, _) = makeCore(wda) { $0.memory = store }
        return (core, wda, pages)
    }

    func number(of label: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains("\"\(label)") {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }

    /// Records Settings → General → About by hand and saves it.
    func recordAbout(_ core: PokiCore) async -> ToolResult {
        let first = await core.call("look", [:])
        let general = number(of: "General", in: first.text)!
        let second = await core.call("do", ["actions": [["tap": .number(Double(general))]]])
        guard let about = number(of: "About", in: second.text) else { XCTFail(second.text); return second }
        _ = await core.call("do", ["actions": [["tap": .number(Double(about))]]])
        return await core.call("routines", ["action": "save", "name": "iOS version", "description": "read the iOS version in Settings", "read": ["iOS Version"]])
    }

    func testATaskIsSavedAsARoutineByWhatItTapped() async {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        let saved = await recordAbout(core)
        XCTAssertTrue(saved.text.contains("saved \"iOS version\" (2 steps"), saved.text)
        let routine = store.routine(named: "iOS version")!
        XCTAssertEqual(routine.steps.map { $0.target?.label }, ["General", "About"])
        XCTAssertEqual(routine.steps.map { $0.target?.type }, ["Button", "Button"])
        XCTAssertEqual(routine.app, "com.apple.Preferences")
        XCTAssertTrue(routine.expect.contains("About") || routine.expect.contains("iOS Version"), "\(routine.expect)")
    }

    /// A phone that holds WeChat and Little Red Book: `launch` brings the app in front and the read shows its screen.
    final class TwoApps: @unchecked Sendable {
        static let wechat = "com.tencent.xin", redbook = "com.xingin.discover"
        static let screens: [String: (name: String, nodes: [Node])] = [
            wechat: ("微信", [Node("Button", "Discover", [16, 100, 358, 44]), Node("Button", "Me", [16, 144, 358, 44])]),
            redbook: ("小红书", [Node("Button", "Search", [16, 100, 358, 44]), Node("Button", "Notes", [16, 144, 358, 44])]),
        ]
        let wda: FakeWDA
        init(_ wda: FakeWDA) {
            self.wda = wda
            show(Self.wechat)
            wda.set("POST /wda/apps/activate") { [self] body in
                self.show(body?["bundleId"]?.string ?? "")
                return (200, ["value": .null])
            }
        }
        func show(_ bundle: String) {
            guard let screen = Self.screens[bundle] else { return }
            wda.tree(screen.nodes, app: screen.name)
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(bundle), "name": .string(screen.name)]]) }
        }
    }

    /// The Memory page lists a skill under its app: "Search a topic" was done in Little Red Book,
    /// after WeChat was used first in the same task.
    func testASkillBelongsToTheAppItWorkedInNotTheFirstOneOpenedInTheTask() async throws {
        let store = RoutineStore(url: nil)
        let wda = FakeWDA()
        let phone = TwoApps(wda)
        let (core, _, _) = makeCore(wda) { $0.memory = store }
        let wechat = await core.call("look", [:])
        let discover = try XCTUnwrap(number(of: "Discover", in: wechat.text), wechat.text)
        _ = await core.call("do", ["actions": [["tap": .number(Double(discover))]]])
        let redbook = await core.call("do", ["actions": [["launch": .string(TwoApps.redbook)]]])
        let search = try XCTUnwrap(number(of: "Search", in: redbook.text), redbook.text)
        _ = await core.call("do", ["actions": [["tap": .number(Double(search))]]])
        let saved = await core.call("routines", ["action": "save", "name": "Search a topic", "description": "search a topic in Little Red Book"])
        XCTAssertTrue(saved.text.contains("saved \"Search a topic\""), saved.text)
        XCTAssertEqual(store.routine(named: "Search a topic")?.app, TwoApps.redbook)
        XCTAssertEqual(store.routine(named: "Search a topic")?.otherApps, [TwoApps.wechat])
        XCTAssertEqual(store.skills.filter { $0.app == TwoApps.wechat }.map(\.name), [], "it must not be listed under WeChat")

        // Run from WeChat again: the run still starts where its first step is, not in the app it ends in.
        phone.show(TwoApps.wechat)
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "Search a topic"]]])
        XCTAssertTrue(run.text.contains("run \"Search a topic\": 3 steps"), run.text)
        XCTAssertFalse(run.isError, run.text)
    }

    func testARunRepeatsTheRoutineInOneCallAndReadsTheValue() async {
        let (core, wda, pages) = core()
        _ = await recordAbout(core)
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("run \"iOS version\": 2 steps"), run.text)
        XCTAssertTrue(run.text.contains("end check passed"), run.text)
        XCTAssertTrue(run.text.contains("read: iOS Version = 27.3"), run.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps + 2)
        XCTAssertEqual(pages.page.value, 2)
        XCTAssertFalse(run.isError)
    }

    func testARunStopsWhereTheScreenDiffersAndSendsNothingMore() async {
        let store = RoutineStore(url: nil)
        let (core, wda, pages) = core(store)
        _ = await recordAbout(core)
        pages.screens[0] = [Node("Button", "Privacy", [16, 100, 358, 44])]
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("stopped at step 1 of 2"), run.text)
        XCTAssertTrue(run.text.contains("Button \"General\" is not on screen"), run.text)
        XCTAssertTrue(run.text.contains("app: Settings"), "the stop answers with the screen: \(run.text)")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
        XCTAssertEqual(store.routine(named: "iOS version")?.failuresInARow, 1)
        XCTAssertEqual(store.routine(named: "iOS version")?.lastStop?.step, 1)
    }

    func testTwoLikeTargetsFarFromTheRecordedOneAreNotGuessedBetween() async {
        let (core, wda, pages) = core()
        _ = await recordAbout(core)
        pages.screens[0] = [Node("Button", "General", [16, 400, 358, 44]), Node("Button", "General", [16, 600, 358, 44])]
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("2 elements match Button \"General\""), run.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
    }

    /// The brief goes into every task's prompt: a full memory stays within 4000 characters, and keeps
    /// the routine that fits the task and the newest note.
    func testTheBriefStaysShortWhenTheMemoryIsFull() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        _ = await recordAbout(core)
        var other = try XCTUnwrap(store.routine(named: "iOS version"))
        for i in 0..<30 {
            other.name = "errand \(i)"
            other.description = String(repeating: "an errand the owner runs every week, ", count: 8)
            store.save(other)
        }
        for i in 0..<50 { _ = store.remember("note \(i): " + String(repeating: "a long fact about the owner. ", count: 10), by: "test") }

        let brief = store.brief(for: "what iOS version is this")

        XCTAssertLessThanOrEqual(brief.count, 4000)
        XCTAssertTrue(brief.contains("- iOS version: read the iOS version in Settings"), brief)
        XCTAssertTrue(brief.contains("note 49: "), brief)
    }

    func testAStaleRoutineIsNotOfferedAndASaveOverItStartsItsRecordAgain() async {
        let store = RoutineStore(url: nil)
        let (core, _, pages) = core(store)
        _ = await recordAbout(core)
        XCTAssertTrue(store.brief(for: "what iOS version is this").contains("iOS version"))
        pages.screens[0] = [Node("Button", "Privacy", [16, 100, 358, 44])]
        for _ in 0..<2 { pages.show(0); _ = await core.call("look", [:]); _ = await core.call("do", ["actions": [["run": "iOS version"]]]) }
        XCTAssertTrue(store.routine(named: "iOS version")!.stale)
        XCTAssertFalse(store.brief(for: "what iOS version is this").contains("iOS version:"))
    }

    func testTheFirstLookOfATaskNamesTheRoutinesAndFinishOffersToSave() async {
        let (core, _, pages) = core()
        let first = await core.call("look", [:])
        XCTAssertFalse(first.text.contains("skills"), first.text)
        _ = await recordAbout(core)
        pages.show(0)
        let finished = await core.call("do", ["actions": [["tap": 1]], "finish": true])
        XCTAssertTrue(finished.text.contains("learn: this task took"), finished.text)
        let next = await core.call("look", [:])
        XCTAssertTrue(next.text.contains("skills for this app: \"iOS version\""), next.text)
    }

    func testTypedTextBecomesAParameterAndAPasswordIsNeverKept() async {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        _ = await core.call("look", [:])
        // Record by hand: the type actions as the recorder sees them.
        let c = core.computer
        c.refs = [1: Element(type: "SearchField", label: "Search", value: nil, identifier: nil, frame: Rect(x: 16, y: 60, width: 358, height: 36), depth: 1)]
        c.trace = [c.recordable(["type": "hello", "ref": 1])!]
        let (routine, _) = c.routine(named: "search", description: "", read: [], expect: [], by: "test")
        XCTAssertEqual(routine?.steps.first?.action["type"]?.string, "{{text_1}}")
        XCTAssertEqual(routine?.params["text_1"], "hello")
        XCTAssertEqual(routine?.steps.first?.target?.label, "Search")
        c.refs = [1: Element(type: "SecureTextField", label: "Password", value: nil, identifier: nil, frame: Rect(x: 16, y: 60, width: 358, height: 36), depth: 1)]
        let secret = c.recordable(["type": "hunter2", "ref": 1])!
        XCTAssertEqual(secret.step.secret, true)
        XCTAssertNil(secret.typed)
        XCTAssertFalse(secret.step.action.serialized().contains("hunter2"))
    }

    func testNotesExportAndImportMoveTheMemoryBetweenPhones() async throws {
        let a = RoutineStore(url: nil)
        let (core, _, _) = core(a)
        _ = await recordAbout(core)
        let remembered = await core.call("routines", ["action": "remember", "text": "Mom is the contact Mama"])
        XCTAssertTrue(remembered.text.contains("remembered"), remembered.text)
        let exported = await core.call("routines", ["action": "export"])
        XCTAssertTrue(exported.text.contains("\"schema\" : \"poki.agent-backup/2\""), String(exported.text.prefix(200)))

        let b = RoutineStore(url: nil)
        let summary = try b.importData(Data(exported.text.utf8), by: "test")
        XCTAssertTrue(summary.contains("1 skills added"), summary)
        XCTAssertEqual(b.notes.map(\.text), ["Mom is the contact Mama"])
        XCTAssertEqual(b.routine(named: "iOS version")?.steps.count, 2)
        // Importing the same file again changes nothing; an older copy does not replace a newer one.
        let again = try b.importData(Data(exported.text.utf8), by: "test")
        XCTAssertTrue(again.contains("0 skills added, 0 replaced"), again)
        XCTAssertThrowsError(try b.importData(Data(#"{"schema":"other/1"}"#.utf8), by: "test"))
        XCTAssertTrue(b.brief(for: "anything").contains("Mom is the contact Mama"))
    }

    func testTheBackupCopyIsWrittenAndARestoredOneIsMergedIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-routines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RoutineStore(url: dir.appendingPathComponent("memory.json"), backupDirectory: dir.appendingPathComponent("AgentBackup"))
        store.remember("Use the work email", by: "owner")
        let backup = dir.appendingPathComponent("AgentBackup/poki-agent-backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(store.importRestoredBackup(), "our own copy is not imported again")
        // Poki Setup puts another phone's backup there.
        let other = RoutineStore(url: nil)
        other.remember("Mom is the contact Mama", by: "owner")
        try other.exportData().write(to: backup)
        let reopened = RoutineStore(url: dir.appendingPathComponent("memory.json"), backupDirectory: dir.appendingPathComponent("AgentBackup"))
        XCTAssertNotNil(reopened.importRestoredBackup())
        XCTAssertEqual(Set(reopened.notes.map(\.text)), ["Use the work email", "Mom is the contact Mama"])
    }

    func testTheToolIsListedAndAnswersWithoutTheRunner() async {
        let (core, _, _) = core()
        let list = await core.rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], session: nil)
        XCTAssertTrue(list.reply?.serialized().contains("\"name\":\"skills\"") == true)
        let empty = await core.call("routines", ["action": "list"])
        XCTAssertTrue(empty.text.contains("none saved yet"), empty.text)
        let bad = await core.call("routines", ["action": "show", "name": "nope"])
        XCTAssertTrue(bad.isError)
    }

    func testChineseRequestSelectsTheMatchingSkillAndLeavesUnrelatedSkillsOut() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        _ = await recordAbout(core)
        var battery = try XCTUnwrap(store.routine(named: "iOS version"))
        battery.name = "查电池健康"
        battery.description = "在设置里查看电池最大容量"
        battery.app = "com.apple.Preferences"
        battery.updated = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(battery)

        for i in 0..<15 {
            var filler = battery
            filler.name = "日常事务\(i)"
            filler.description = "每周查看一次快递进度\(i)"
            filler.app = "com.Cainiao.cnwireless"
            filler.updated = Date(timeIntervalSince1970: 1_700_001_000 + Double(i))
            store.save(filler)
        }

        let matched = store.brief(for: "帮我看看电池健康度")
        XCTAssertTrue(matched.contains("查电池健康"), matched)
        XCTAssertFalse(matched.contains("日常事务"), matched)

        let unrelated = store.brief(for: "帮我算一下 25 乘 36", app: "com.apple.calculator")
        XCTAssertFalse(unrelated.contains("查电池健康"), unrelated)
        XCTAssertFalse(unrelated.contains("日常事务"), unrelated)
    }

    func testLegacyBackupMigratesRoutinesToSkillsWithAppFromStepsOrNil() throws {
        let legacyJSON = """
        {
          "schema": "poki.agent-backup/1",
          "routines": [
            {
              "name": "查电池健康",
              "description": "查看最大容量",
              "app": "com.apple.Preferences",
              "steps": [{"action": {"tap": "@"}, "app": "com.apple.Preferences"}],
              "params": {},
              "expect": [],
              "read": [],
              "runs": 2,
              "ok": 2,
              "failuresInARow": 0,
              "savedBy": "Poki",
              "created": "2026-11-01T00:00:00Z",
              "updated": "2026-11-01T00:00:00Z"
            },
            {
              "name": "步骤里带设置",
              "description": "A legacy skill attributed to the first app",
              "app": "com.tencent.xin",
              "steps": [
                {"action": {"tap": "@"}, "app": "com.apple.springboard"},
                {"action": {"tap": "@"}, "target": {"type": "Button", "label": "Discover", "x": 100, "y": 120}, "app": "com.tencent.xin"},
                {"action": {"launch": "com.apple.Preferences"}, "app": "com.tencent.xin"},
                {"action": {"tap": "@"}, "target": {"type": "Button", "label": "通用", "x": 100, "y": 120}, "app": "com.apple.Preferences"},
                {"action": {"wait": 100}, "app": "com.tencent.xin"},
                {"action": {"button": "home"}, "app": "com.tencent.xin"}
              ],
              "params": {},
              "expect": [],
              "read": [],
              "runs": 1,
              "ok": 1,
              "failuresInARow": 0,
              "savedBy": "Poki",
              "created": "2026-11-01T00:00:00Z",
              "updated": "2026-11-01T00:00:00Z"
            },
            {
              "name": "返回主屏幕",
              "description": "没有任何 App 记录",
              "steps": [{"action": {"button": "home"}}],
              "params": {},
              "expect": [],
              "read": [],
              "runs": 1,
              "ok": 1,
              "failuresInARow": 0,
              "savedBy": "Poki",
              "created": "2026-11-01T00:00:00Z",
              "updated": "2026-11-01T00:00:00Z"
            }
          ],
          "notes": [{"id": "n1", "text": "常点少冰", "by": "owner", "at": "2026-11-01T00:00:00Z"}],
          "runs": [{"routine": "查电池健康", "at": "2026-11-01T00:00:00Z", "ms": 420, "outcome": "ok", "steps": ["1 tap"]}]
        }
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-memory.json")
        try Data(legacyJSON.utf8).write(to: file)

        let loaded = RoutineStore(url: file)
        XCTAssertEqual(loaded.routine(named: "查电池健康")?.app, "com.apple.Preferences")
        XCTAssertEqual(loaded.routine(named: "步骤里带设置")?.app, "com.apple.Preferences")
        XCTAssertNil(loaded.routine(named: "返回主屏幕")?.app)
        XCTAssertEqual(loaded.notes.map(\.text), ["常点少冰"])

        let imported = RoutineStore(url: nil)
        let summary = try imported.importData(Data(legacyJSON.utf8), by: "test")
        XCTAssertTrue(summary.contains("3 skills added"), summary)
        XCTAssertEqual(imported.routine(named: "步骤里带设置")?.app, "com.apple.Preferences")
        XCTAssertNil(imported.routine(named: "返回主屏幕")?.app)

        let exportedData = try imported.exportData()
        let exported = String(decoding: exportedData, as: UTF8.self)
        XCTAssertTrue(exported.contains("\"schema\" : \"poki.agent-backup/2\""), exported)
        XCTAssertTrue(exported.contains("\"skills\""), exported)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any])
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedData) as? [String: Any])
        let originalSkills = try XCTUnwrap(original["routines"] as? [[String: Any]])
        let migratedSkills = try XCTUnwrap(migrated["skills"] as? [[String: Any]])
        for old in originalSkills {
            let name = try XCTUnwrap(old["name"] as? String)
            var before = old
            var after = try XCTUnwrap(migratedSkills.first { $0["name"] as? String == name })
            before.removeValue(forKey: "app")
            after.removeValue(forKey: "app")
            XCTAssertEqual(before as NSDictionary, after as NSDictionary, "Migration must preserve the skill content and run history")
        }
        let roundTripped = RoutineStore(url: nil)
        _ = try roundTripped.importData(exportedData, by: "test")
        XCTAssertEqual(roundTripped.skills.map(\.name).sorted(), imported.skills.map(\.name).sorted())
    }

    func testSkillsToolIsPrimaryAndRoutinesAliasReturnsTheSameResult() async {
        let (core, _, pages) = core()
        let listRPC = await core.rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], session: nil)
        let catalog = listRPC.reply?.serialized() ?? ""
        XCTAssertTrue(catalog.contains("\"name\":\"skills\""), catalog)
        XCTAssertFalse(catalog.contains("\"name\":\"routines\""), catalog)

        _ = await core.call("look", [:])
        let general = number(of: "General", in: (await core.call("look", [:])).text)!
        let second = await core.call("do", ["actions": [["tap": .number(Double(general))]]])
        let about = number(of: "About", in: second.text)!
        _ = await core.call("do", ["actions": [["tap": .number(Double(about))]]])
        let saved = await core.call("skills", ["action": "save", "name": "查系统版本", "description": "在设置里读取 iOS 版本", "read": ["iOS Version"]])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertTrue(saved.text.contains("skills: saved \"查系统版本\""), saved.text)

        let listedViaNew = await core.call("skills", ["action": "list"])
        let listedViaAlias = await core.call("routines", ["action": "list"])
        XCTAssertFalse(listedViaAlias.isError, listedViaAlias.text)
        XCTAssertEqual(listedViaAlias.text, listedViaNew.text)

        pages.show(0)
        _ = await core.call("look", [:])
        let replayed = await core.call("do", ["actions": [["run": "查系统版本"]]])
        XCTAssertFalse(replayed.isError, replayed.text)
        XCTAssertTrue(replayed.text.contains("run \"查系统版本\": 2 steps"), replayed.text)
        XCTAssertTrue(replayed.text.contains("read: iOS Version = 27.3"), replayed.text)
    }

    // MARK: The Memory page's fields: locks, the app, where a note was heard, Recent Updates

    /// A memory file exactly as Poki wrote it before locks, apps on notes and the change log.
    static let fileFromBefore = #"""
    {
      "notes" : [
        { "at" : "2026-11-10T08:00:00Z", "by" : "owner", "id" : "a1b2c3d4", "text" : "Mom is the contact Mama" },
        { "at" : "2026-11-12T09:30:00Z", "by" : "Poki", "id" : "b2c3d4e5", "text" : "Coffee is an iced Americano, light ice" }
      ],
      "routines" : [
        {
          "created" : "2026-11-11T10:00:00Z", "description" : "read the iOS version in Settings", "expect" : [ "About" ],
          "failuresInARow" : 0, "lastMs" : 6000, "name" : "iOS version", "ok" : 2, "params" : { }, "read" : [ "iOS Version" ],
          "runs" : 2, "savedBy" : "Poki", "updated" : "2026-11-11T10:00:00Z",
          "steps" : [ { "action" : { "tap" : "@" }, "app" : "com.apple.Preferences",
                        "target" : { "label" : "General", "type" : "Button", "x" : 195, "y" : 122 } } ]
        }
      ],
      "runs" : [ ],
      "schema" : "poki.agent-backup/1"
    }
    """#

    func testAFileFromBeforeTheMemoryPageFieldsOpensWithEverythingInIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent-memory.json")
        try Data(Self.fileFromBefore.utf8).write(to: url)

        let store = RoutineStore(url: url)
        XCTAssertEqual(store.notes.map(\.text), ["Mom is the contact Mama", "Coffee is an iced Americano, light ice"])
        XCTAssertEqual(store.notes.map(\.app), [nil, nil], "no app: About You")
        XCTAssertEqual(store.notes.map(\.heard), [nil, nil], "no conversation to go back to")
        XCTAssertEqual(store.routine(named: "iOS version")?.runs, 2)
        // The first change writes the file in the new shape; nothing from before is lost.
        store.setLocked("b2c3d4e5", true)
        let reopened = RoutineStore(url: url)
        XCTAssertEqual(reopened.notes.map(\.id), ["a1b2c3d4", "b2c3d4e5"])
        XCTAssertEqual(reopened.notes.map(\.isLocked), [false, true])
        XCTAssertEqual(reopened.routine(named: "iOS version")?.steps.first?.target?.label, "General")
        // A backup from before imports the same way.
        let other = RoutineStore(url: nil)
        _ = try other.importData(Data(Self.fileFromBefore.utf8), by: "import")
        XCTAssertEqual(other.notes.count, 2)
        XCTAssertNotNil(other.routine(named: "iOS version"))
    }

    func testAnAgentsImportDoesNotPassNotesOffAsTheOwnersEditsOrConversations() throws {
        let source = RoutineStore(url: nil)
        let heard = source.remember("Coffee is an iced Americano", by: "Poki", heard: NoteOrigin(session: "chat-1", app: "com.apple.mobilesafari"))!
        let edited = source.remember("Mom is the contact Mama", by: "owner")!
        source.editNote(edited.id, text: "Mom is the contact Mama (Mom)")
        let file = try source.exportData()

        // An MCP client's import: its notes are its own, not the owner's edit and not a chat of ours.
        let fromAgent = RoutineStore(url: nil)
        try fromAgent.importData(file, by: "Claude Code")
        let agent = Dictionary(uniqueKeysWithValues: fromAgent.notes.map { ($0.id, $0) })
        XCTAssertNil(agent[heard.id]?.heard, "a conversation of another phone's is not one to go back to")
        XCTAssertNil(agent[edited.id]?.edited, "it must not show as the owner's change")
        XCTAssertNil(agent[edited.id]?.locked)
        XCTAssertEqual(agent[edited.id]?.by, "Claude Code")

        // The owner restoring their own backup keeps all of it.
        let restored = RoutineStore(url: nil)
        try restored.importData(file, by: "restore")
        XCTAssertNotNil(restored.notes.first { $0.id == edited.id }?.edited)
        XCTAssertEqual(restored.notes.first { $0.id == heard.id }?.heard?.session, "chat-1")
    }

    func testAFileThisVersionCannotReadIsSetAsideNotWrittenOver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent-memory.json")
        let unreadable = Data(#"{"notes": "not a list", "schema": "poki.agent-backup/1"}"#.utf8)
        try unreadable.write(to: url)

        let store = RoutineStore(url: url)
        store.remember("Use the work email", by: "owner")
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("agent-memory.unreadable-") }
        XCTAssertEqual(aside.count, 1, "the file it could not read is kept")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), unreadable)
    }

    func testAnAgentCannotChangeOrForgetWhatTheOwnerLocked() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, pages) = core(store)
        _ = await recordAbout(core)
        let note = store.remember("Mom is the contact Mama", by: "Poki")!
        store.setLocked(note.id, true)
        store.setLocked("iOS version", true)
        let steps = store.routine(named: "iOS version")!.steps

        let forgetNote = await core.call("routines", ["action": "forget_note", "text": .string(note.id)])
        XCTAssertTrue(forgetNote.isError && forgetNote.text.contains("locked"), forgetNote.text)
        XCTAssertFalse(store.forgetNote(note.id, by: "an MCP client"), "the store refuses it too, whoever asks")
        let forget = await core.call("routines", ["action": "forget", "name": "iOS version"])
        XCTAssertTrue(forget.isError, forget.text)
        let edit = await core.call("routines", ["action": "edit", "name": "iOS version", "description": "something else", "rename": "other"])
        XCTAssertTrue(edit.isError, edit.text)
        pages.show(0)
        let saveOver = await recordAbout(core)
        XCTAssertTrue(saveOver.isError, saveOver.text)
        // Nor by the side doors: a client that calls itself "owner" importing a file that brings a
        // locked note of the owner's under the locked note's id, or a rename onto the locked routine's name.
        func post(_ body: JSON, _ session: String? = nil) async -> RelayResponse {
            await core.handle(RelayRequest(id: "r", method: "POST", headers: session.map { ["mcp-session-id": $0] } ?? [:], body: body.serialized()))
        }
        let hello = await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "owner"]]])
        let session = try XCTUnwrap(hello.headers["mcp-session-id"])
        let elsewhere = RoutineStore(url: nil)
        let planted = try XCTUnwrap(elsewhere.remember("Mom is not a contact", by: RoutineStore.owner, locked: true))
        let forged = String(decoding: try elsewhere.exportData(), as: UTF8.self).replacingOccurrences(of: planted.id, with: note.id)
        let imported = try JSON.parse(await post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "routines", "arguments": ["action": "import", "data": .string(forged)]]], session).body)
        XCTAssertEqual(imported["result"]?["isError"], false, "\(imported)")
        let brought = try XCTUnwrap(store.note("Mom is not a contact"))
        XCTAssertNotEqual(brought.id, note.id)
        XCTAssertFalse(brought.isLocked)
        XCTAssertNotEqual(brought.by, RoutineStore.owner)
        var copy = try XCTUnwrap(store.routine(named: "iOS version"))
        copy.name = "Settings check"; copy.locked = nil
        XCTAssertTrue(store.save(copy))
        let onto = await core.call("routines", ["action": "edit", "name": "Settings check", "rename": "iOS version"])
        XCTAssertTrue(onto.isError, onto.text)
        // Filling the notes past the cap drops the oldest unlocked ones, never the locked one.
        for i in 0..<60 { store.remember("Fact \(i)", by: "Poki") }

        XCTAssertEqual(store.note(note.id)?.text, "Mom is the contact Mama")
        XCTAssertEqual(store.routine(named: "iOS version")?.description, "read the iOS version in Settings")
        XCTAssertEqual(store.routine(named: "iOS version")?.steps, steps)
        XCTAssertNil(store.routine(named: "other"))
        XCTAssertNotNil(store.routine(named: "Settings check"))
    }

    func testUndoingAForgetPutsTheNoteBackAsItWas() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        let said = await core.callTool("routines", arguments: #"{"action":"remember","text":"Lunch is the dumplings place"}"#, conversation: "chat-1")
        XCTAssertFalse(said.isError, said.text)
        let note = try XCTUnwrap(store.note("Lunch is the dumplings place"))
        XCTAssertEqual(note.heard?.session, "chat-1", "the conversation it was heard in")

        XCTAssertTrue(store.forgetNote(note.id, by: RoutineStore.owner))
        XCTAssertNil(store.note(note.id))
        let forgot = try XCTUnwrap(store.changes.first)
        XCTAssertEqual(forgot.action, MemoryChangeRecord.forgot)
        XCTAssertTrue(store.undo(forgot.id))
        XCTAssertEqual(store.note(note.id), note, "the same id, date and conversation; not locked, since the owner forgot it")
        XCTAssertFalse(store.undo(forgot.id), "once")

        // The owner moving it to an app, then changing their mind: it is back as it was, with its
        // conversation and unlocked, not only its words.
        store.editNote(note.id, text: note.text, app: .some("com.meituan.itakeaway"))
        XCTAssertEqual(store.note(note.id)?.isLocked, true)
        XCTAssertTrue(store.undo(store.changes.first!.id))
        XCTAssertEqual(store.note(note.id), note)

        // Undoing what an agent did locks the item, so it is not done again.
        XCTAssertTrue(store.forgetNote(note.id, by: "Poki"))
        XCTAssertTrue(store.undo(store.changes.first!.id))
        XCTAssertEqual(store.note(note.id)?.isLocked, true)
    }

    func testUndoingLegacySkillChangesRestoresTheCorrectAppWithoutLosingContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("poki-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-memory.json")
        for (action, by, oldLocked, expectedLocked) in [
            ("forgot", "owner", true, true),
            ("forgot", "Poki", false, true),
            ("edited", "owner", true, false),
            ("edited", "Poki", false, true),
        ] {
            let legacy = """
            {
              "name": "Search a topic",
              "description": "Search Little Red Book after using WeChat",
              "app": "com.tencent.xin",
              "steps": [
                {"action": {"tap": "@"}, "target": {"type": "Button", "label": "Discover", "x": 100, "y": 120}, "app": "com.tencent.xin"},
                {"action": {"launch": "com.xingin.discover"}, "app": "com.tencent.xin"},
                {"action": {"type": "{{topic}}"}, "app": "com.xingin.discover"}
              ],
              "params": {"topic": "coffee"}, "expect": ["Results"], "read": ["Title"],
              "runs": 9, "ok": 7, "failuresInARow": 1, "lastMs": 420,
              "savedBy": "Poki", "locked": \(oldLocked),
              "created": "2026-11-01T00:00:00Z", "updated": "2026-11-02T00:00:00Z"
            }
            """
            let old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
            var current = old
            current["name"] = "Renamed search"
            current["description"] = "Edited description"
            current["locked"] = false
            let history: [String: Any] = [
                "schema": "poki.agent-backup/1",
                "routines": action == "edited" ? [current] : [],
                "notes": [], "runs": [],
                "changes": [["id": "legacy-change", "action": action, "by": by,
                             "at": "2026-11-03T00:00:00Z", "routineName": "Renamed search",
                             "routineApp": "com.tencent.xin", "routine": old]],
            ]
            try JSONSerialization.data(withJSONObject: history).write(to: file)
            let store = RoutineStore(url: file)
            XCTAssertTrue(store.undo("legacy-change"), "\(action) by \(by)")
            let restored = try XCTUnwrap(store.skill(named: "Search a topic"))
            XCTAssertEqual(restored.app, "com.xingin.discover", "\(action) by \(by)")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var expected = try decoder.decode(Skill.self, from: Data(legacy.utf8))
            expected.app = "com.xingin.discover"
            expected.locked = expectedLocked
            XCTAssertEqual(restored, expected, "Undo must preserve content, run history, and its existing lock semantics")
            XCTAssertNil(store.skill(named: "Renamed search"))
            XCTAssertFalse(store.undo("legacy-change"), "a history entry can only be undone once")
            XCTAssertEqual(RoutineStore(url: file).skill(named: "Search a topic"), expected)
        }
    }

    func testAnExportCarriesNoForgottenText() throws {
        let store = RoutineStore(url: nil)
        store.remember("Mom is the contact Mama", by: "owner")
        let secret = store.remember("The gate code is by the mailbox", by: "Poki")!
        store.forgetNote(secret.id, by: RoutineStore.owner)
        XCTAssertNotNil(store.changes.first?.note, "kept on the phone, for undo")

        let exported = String(decoding: try store.exportData(), as: UTF8.self)
        XCTAssertTrue(exported.contains("Mom is the contact Mama"))
        XCTAssertFalse(exported.contains("gate code"))
    }
}
