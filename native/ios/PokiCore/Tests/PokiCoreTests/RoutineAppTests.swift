import XCTest
@testable import PokiCore

final class RoutineAppTests: XCTestCase {
    static let wechat = "com.tencent.xin"
    static let xiaohongshu = "com.xingin.discover"
    static let trains = "cn.12306.rails12306"
    static let home = "com.apple.springboard"

    private func step(_ action: JSON, in app: String?) -> SkillStep {
        SkillStep(action: action, target: nil, app: app, secret: nil)
    }

    private func skill(_ name: String, app: String? = nil, steps: [SkillStep]) -> Skill {
        let date = Date(timeIntervalSince1970: 0)
        return Skill(name: name, description: "", app: app, steps: steps,
                     params: [:], expect: [], read: [], runs: 0, ok: 0,
                     failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: "Poki",
                     created: date, updated: date)
    }

    func testSavingACrossAppSkillIgnoresTheForegroundLeftByLaunch() {
        let store = SkillStore(url: nil)
        let steps = [
            step(["tap": [100, 200]], in: Self.wechat),
            step(["launch": ["bundle": .string(Self.xiaohongshu)]], in: Self.wechat),
            step(["wait": 100], in: Self.wechat),
            step(["tap": [200, 400]], in: Self.wechat),
        ]

        XCTAssertTrue(store.save(skill("Search a topic", steps: steps)))
        let saved = store.skill(named: "Search a topic")
        XCTAssertEqual(saved?.app, Self.xiaohongshu)
        XCTAssertEqual(saved?.otherApps, [Self.wechat])
    }

    func testSavingASkillIgnoresTheForegroundLeftByHomeUntilItIsSeenAgain() {
        let store = SkillStore(url: nil)
        let homeSearch = [
            step(["button": "home"], in: Self.wechat),
            step(["swipe": "down"], in: Self.wechat),
            step(["type": "WeChat"], in: Self.wechat),
            step(["tap": [200, 400]], in: Self.home),
        ]

        XCTAssertTrue(store.save(skill("Search Home", steps: homeSearch)))
        XCTAssertNil(store.skill(named: "Search Home")?.app)
        XCTAssertEqual(store.skill(named: "Search Home")?.otherApps, [])

        XCTAssertTrue(store.save(skill("Return to WeChat", steps: homeSearch + [
            step(["tap": [200, 400]], in: Self.wechat),
        ])))
        XCTAssertEqual(store.skill(named: "Return to WeChat")?.app, Self.wechat)
    }

    func testResavingAReplayKeepsTheAppWhereItsStepWasSent() async throws {
        let store = SkillStore(url: nil)
        let wda = FakeWDA()
        let front = LockedBox(Self.wechat)
        wda.tree([Node("StaticText", "WeChat", [16, 100, 80, 30])], app: Self.wechat)
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(front.value)]]) }
        for path in ["POST /wda/apps/activate", "POST /wda/apps/launch"] {
            wda.set(path) { [weak wda] body in
                if let bundle = body?["bundleId"]?.string {
                    front.value = bundle
                    wda?.tree([Node("StaticText", "Discover", [16, 100, 80, 30])], app: bundle)
                }
                return (200, ["value": .null])
            }
        }
        let (core, _, _) = makeCore(wda) {
            $0.memory = store
            $0.sensitive.enabled = false
        }
        XCTAssertTrue(store.save(skill("Discover", app: Self.xiaohongshu, steps: [
            step(["tap": [200, 400]], in: Self.xiaohongshu),
        ])))

        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "Discover"]]])
        XCTAssertFalse(run.isError, run.text)
        XCTAssertEqual(front.value, Self.xiaohongshu)
        let saved = await core.call("skills", ["action": "save", "name": "Saved replay"])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertEqual(store.skill(named: "Saved replay")?.app, Self.xiaohongshu)
    }

    static let fileFrom045 = #"""
    {
      "schema": "poki.agent-backup/1",
      "routines": [
        {
          "name": "Search Little Red Book", "description": "", "app": "com.tencent.xin",
          "params": {}, "expect": [], "read": [], "runs": 1, "ok": 1, "failuresInARow": 0,
          "savedBy": "Poki", "created": "2026-11-18T11:00:00Z", "updated": "2026-11-18T11:00:00Z",
          "steps": [
            {"action": {"tap": [100, 200]}, "app": "com.tencent.xin"},
            {"action": {"launch": "com.xingin.discover"}, "app": "com.tencent.xin"},
            {"action": {"tap": [200, 400]}, "app": "com.tencent.xin"}
          ]
        },
        {
          "name": "Find a train", "description": "", "app": "com.tencent.xin",
          "params": {}, "expect": [], "read": [], "runs": 0, "ok": 0, "failuresInARow": 0,
          "savedBy": "Poki", "created": "2026-11-18T10:00:00Z", "updated": "2026-11-18T10:00:00Z",
          "steps": [
            {"action": {"launch": {"bundle": "cn.12306.rails12306"}}, "app": "com.tencent.xin"},
            {"action": {"tap": [195, 600]}, "app": "com.tencent.xin"}
          ]
        }
      ],
      "notes": [],
      "runs": [],
      "changes": [
        {"id": "search-added", "action": "added", "at": "2026-11-18T11:00:00Z",
         "by": "Poki", "routineName": "Search Little Red Book", "routineApp": "com.tencent.xin"},
        {"id": "train-edited", "action": "edited", "at": "2026-11-18T11:00:00Z",
         "by": "owner", "routineName": "Find a train", "routineApp": "com.tencent.xin",
         "routine": {
           "name": "Find a train", "description": "", "app": "com.tencent.xin",
           "params": {}, "expect": [], "read": [], "runs": 0, "ok": 0, "failuresInARow": 0,
           "savedBy": "Poki", "created": "2026-11-18T10:00:00Z", "updated": "2026-11-18T10:00:00Z",
           "steps": [
             {"action": {"launch": "cn.12306.rails12306"}, "app": "com.tencent.xin"},
             {"action": {"tap": [195, 600]}, "app": "com.tencent.xin"}
           ]
         }}
      ]
    }
    """#

    func testOpeningMemoryFrom045RegroupsItOnceAndPreservesAPendingRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agent-memory.json")
        let backup = directory.appendingPathComponent("AgentBackup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data(Self.fileFrom045.utf8).write(to: url)
        let pendingRestore = Data(#"{"schema":"poki.agent-backup/1","routines":[]}"#.utf8)
        let backupFile = backup.appendingPathComponent(SkillStore.backupName)
        try pendingRestore.write(to: backupFile)

        let store = SkillStore(url: url, backupDirectory: backup)
        XCTAssertEqual(store.skill(named: "Search Little Red Book")?.app, Self.xiaohongshu)
        XCTAssertEqual(store.skill(named: "Search Little Red Book")?.runs, 1)
        XCTAssertEqual(store.skill(named: "Find a train")?.app, Self.trains)
        let changes = Dictionary(uniqueKeysWithValues: store.changes.map { ($0.id, $0) })
        XCTAssertEqual(changes["search-added"]?.routineApp, Self.xiaohongshu)
        XCTAssertEqual(changes["train-edited"]?.routine?.app, Self.trains)
        XCTAssertEqual(try Data(contentsOf: backupFile), pendingRestore)

        let upgraded = try Data(contentsOf: url)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        XCTAssertEqual(document["appRule"] as? Int, 1)
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let reopened = SkillStore(url: url, backupDirectory: backup)
        XCTAssertEqual(reopened.skill(named: "Find a train")?.app, Self.trains)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, oldDate)
        XCTAssertEqual(try Data(contentsOf: url), upgraded)
    }

    func testRestoringABackupFrom045RegroupsItBeforeExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.fileFrom045.utf8).write(to: directory.appendingPathComponent(SkillStore.backupName))
        let store = SkillStore(url: nil, backupDirectory: directory)

        XCTAssertNotNil(store.importRestoredBackup())
        XCTAssertEqual(store.skill(named: "Search Little Red Book")?.app, Self.xiaohongshu)
        XCTAssertEqual(store.skill(named: "Find a train")?.app, Self.trains)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        XCTAssertEqual(document["appRule"] as? Int, 1)
    }
}
