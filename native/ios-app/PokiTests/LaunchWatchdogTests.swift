import CryptoKit
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class LaunchWatchdogTests: XCTestCase {
    private var folder: URL!
    private var routineFolder: URL!
    private var ddiBackup: URL?
    private var defaults: UserDefaults!
    private var savedModelSettings: [String: Any?] = [:]
    private var savedModelSetup: (relay: String?, enabled: Any?, setup: SetupState)?
    private let suite = "LaunchWatchdogTests"
    private static let modelSettingKeys = ["chat.provider", "chat.customURL", "chat.customModel"]

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        routineFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchWatchdogRoutines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: routineFolder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        for key in Self.modelSettingKeys { savedModelSettings[key] = UserDefaults.standard.object(forKey: key) }
        savedModelSetup = (UserDefaults.standard.string(forKey: "relayAddress"),
                           UserDefaults.standard.object(forKey: "relayEnabled"),
                           SetupState.load())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: routineFolder)
        UserDefaults().removePersistentDomain(forName: suite)
        for key in Self.modelSettingKeys { UserDefaults.standard.set(savedModelSettings[key] ?? nil, forKey: key) }
        if let savedModelSetup {
            UserDefaults.standard.set(savedModelSetup.relay, forKey: "relayAddress")
            UserDefaults.standard.set(savedModelSetup.enabled, forKey: "relayEnabled")
            savedModelSetup.setup.save()
        }
        if let ddiBackup {
            let ddi = AppFiles.ddiDirectory
            try? FileManager.default.removeItem(at: ddi)
            try? FileManager.default.moveItem(at: ddiBackup, to: ddi)
            self.ddiBackup = nil
        }
    }

    private func seedLargeHistory(count: Int, archivedCount: Int, entriesPerSession: Int, callsPerSession: Int) throws {
        let now = Date()
        let longAnswer = "<AXScreen app='com.apple.Preferences'>\n"
            + String(repeating: "  <Button label='Settings item row with detail text and hint' frame='{{16, 120}, {360, 52}}'/>\n", count: 40)
        let encoder = JSONEncoder()
        for i in 0..<count {
            let sid = String(format: "watchdog-%04d", i)
            let updated = now.addingTimeInterval(-Double((count - i) * 3600))
            var entries: [ChatEntry] = [ChatEntry(.time(updated))]
            for e in 0..<entriesPerSession {
                switch e % 4 {
                case 0:
                    entries.append(ChatEntry(.you("Open Settings and check section \(e) with extra details " + String(repeating: "word ", count: 30), delivered: true)))
                case 1:
                    entries.append(ChatEntry(.plan([
                        PlanStep("Open Settings \(e)", state: .done),
                        PlanStep("Check row \(e)", state: .done),
                    ])))
                case 2:
                    entries.append(ChatEntry(.step("Look at screen \(e)", ok: true)))
                default:
                    entries.append(ChatEntry(.poki("Checked item \(e): " + String(repeating: "summary ", count: 25))))
                }
            }
            let calls = (0..<callsPerSession).map { c in
                CallRecord(name: c.isMultiple(of: 2) ? "look" : "do", arguments: "{}", answer: longAnswer, ms: 200, ok: true)
            }
            var session = SavedSession(
                id: sid,
                kind: .poki,
                client: nil,
                title: "Session \(i)",
                started: updated,
                updated: updated,
                live: false,
                outcome: .done,
                entries: entries,
                calls: calls
            )
            if i < archivedCount { session.archived = updated }
            try encoder.encode(session).write(to: folder.appendingPathComponent("\(sid).json"))
        }
    }

    private func seedRoutineBackup(routineCount: Int = 80) throws -> RoutineStore {
        let backupDir = routineFolder.appendingPathComponent("AgentBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let steps: [[String: Any]] = Array(repeating: [
            "action": ["tap": [120, 240]],
            "app": "com.apple.Preferences",
        ], count: 12)
        let routines: [[String: Any]] = (0..<routineCount).map { i in
            [
                "name": "routine-\(i)",
                "description": "Check settings item \(i)",
                "app": "com.apple.Preferences",
                "steps": steps,
                "params": [String: String](),
                "expect": [String](),
                "read": [String](),
                "runs": i % 5,
                "ok": i % 5,
                "failuresInARow": 0,
                "lastMs": 120,
                "savedBy": "owner",
                "created": now,
                "updated": now,
            ]
        }
        let payload: [String: Any] = [
            "schema": RoutineStore.schema,
            "exported": now,
            "routines": routines,
            "notes": [Any](),
            "runs": [Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: backupDir.appendingPathComponent(RoutineStore.backupName))
        return RoutineStore(url: routineFolder.appendingPathComponent("memory.json"), backupDirectory: backupDir)
    }

    private func seedDiskImageFixture(imageBytesCount: Int = 80 * 1024 * 1024) throws {
        let ddi = AppFiles.ddiDirectory
        if FileManager.default.fileExists(atPath: ddi.path) {
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("ddi-backup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: ddi, to: backup)
            ddiBackup = backup
        }
        try FileManager.default.createDirectory(at: ddi, withIntermediateDirectories: true)

        let payloads: [(key: String, path: String, data: Data)] = [
            ("Cryptex1,GenericDmg", "Image.dmg", Data(repeating: 0x5A, count: imageBytesCount)),
            ("Cryptex1,GenericTrustCache", "Image.dmg.trustcache", Data("trustcache".utf8)),
            ("Cryptex1,CryptexInfoPlist", "Image.dmg.cryptex_info", Data("cryptex".utf8)),
            ("Cryptex1,GenericVolume", "Image.dmg.root_hash", Data("roothash".utf8)),
        ]
        var manifestEntries: [String: Any] = [:]
        for payload in payloads {
            try payload.data.write(to: ddi.appendingPathComponent(payload.path))
            manifestEntries[payload.key] = [
                "Digest": Data(SHA384.hash(data: payload.data)),
                "Info": ["Path": payload.path],
            ]
        }
        let manifest: [String: Any] = [
            "ProductBuildVersion": "99Z999",
            "BuildIdentities": [["Manifest": manifestEntries]],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try plistData.write(to: ddi.appendingPathComponent("BuildManifest.plist"))
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        await fulfillment(of: [expectation], timeout: timeout)
    }

    func testLargeUpgradeStartupCompletesFirstFrameWithinBudget() async throws {
        try seedLargeHistory(count: 400, archivedCount: 250, entriesPerSession: 100, callsPerSession: 50)
        try seedDiskImageFixture()
        let routineStore = try seedRoutineBackup(routineCount: 80)

        let t0 = ContinuousClock.now
        let routineTask = PokiApp.scheduleStartupWork(routines: routineStore)
        let store = SessionStore.launchStore(folder: folder, defaults: defaults)
        let shortcutStore = HomeShortcutStore()
        shortcutStore.refreshInBackground(sessions: store.sessions, routines: { routineStore.routines })
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let chat = ChatModel(app: model, store: store)
        let tStartupInit = ContinuousClock.now - t0

        let tFrameStart = ContinuousClock.now
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(
            rootView: RootView(sessionStore: store, shortcutStore: shortcutStore).environment(model).environment(chat)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()
        let tFrame = ContinuousClock.now - tFrameStart
        defer { window.isHidden = true; model.stopSession() }

        let total = tStartupInit + tFrame
        print("WATCHDOG_TIMING startupInit=\(tStartupInit) frame=\(tFrame) total=\(total)")
        // Startup work (SessionStore, RoutineStore backup, HomeShortcutStore, DiskImageStore, AppModel, ChatModel)
        // previously blocked for >700 ms on 400 sessions + 80 MB DDI; off main thread it stays well under 250 ms.
        XCTAssertLessThan(tStartupInit, .milliseconds(250), "Startup init must stay off the main thread (took \(tStartupInit))")
        XCTAssertLessThan(total, .milliseconds(1500), "First frame with large history, routine backup, and DDI must stay within watchdog budget (startupInit=\(tStartupInit), frame=\(tFrame))")
        XCTAssertTrue(store.listed.isEmpty, "Pre-archive upgrade sessions must not flash in listed before archiving completes")

        await store.waitUntilLoaded()
        await model.diskImage.ensureChecked()
        let imported = await routineTask.value

        XCTAssertEqual(store.sessions.count, 400)
        XCTAssertEqual(store.archivedSessions.count, 400)
        XCTAssertTrue(store.listed.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        XCTAssertTrue(model.diskImage.hasFiles)
        XCTAssertNotNil(imported)
        XCTAssertEqual(routineStore.routines.count, 80)

        shortcutStore.refreshInBackground(sessions: store.sessions, routines: { routineStore.routines })
        await shortcutStore.waitUntilRefreshed()
        XCTAssertFalse(shortcutStore.shortcuts.isEmpty)
    }

    func testUpgradeWithSmallHistoryAndDiskImageDoesNotBlockMainThread() async throws {
        try seedLargeHistory(count: 40, archivedCount: 0, entriesPerSession: 20, callsPerSession: 10)
        try seedDiskImageFixture()

        let t0 = ContinuousClock.now
        let diskImage = DiskImageStore()
        diskImage.notice()
        let store = SessionStore.launchStore(folder: folder, defaults: defaults)
        let elapsed = ContinuousClock.now - t0

        XCTAssertEqual(diskImage.state, .missing, "DDI SHA-384 verification and developer framework dlopen must stay off the main thread during init")
        XCTAssertTrue(diskImage.isChecking)
        XCTAssertLessThan(elapsed, .milliseconds(100), "Init with 40 sessions and 80 MB DDI must return immediately (took \(elapsed))")

        await store.waitUntilLoaded()
        await diskImage.ensureChecked()

        XCTAssertFalse(diskImage.isChecking)
        XCTAssertEqual(store.sessions.count, 40)
        XCTAssertEqual(store.archivedSessions.count, 40)
        XCTAssertTrue(store.listed.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        XCTAssertTrue(diskImage.hasFiles)
    }

    func testStartSessionWhileDiskImageCheckIsRunningDoesNotMisreportOrOverwriteDDI() async throws {
        try seedDiskImageFixture()

        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation(), requiresDiskImageCheck: true)
        defer { model.stopSession() }
        model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        XCTAssertTrue(model.diskImage.isChecking)

        // Simulate user focusing the composer or tapping a home pill while DDI verification is still running.
        model.prepareForTask()

        XCTAssertNil(model.problem, "Pending DDI verification must not falsely report that the disk image is not downloaded")
        XCTAssertTrue(model.sessionStarting)
        if case .downloading = model.diskImage.state {
            XCTFail("Pending DDI verification must not trigger a fresh download that overwrites existing DDI files")
        }

        await waitFor("session turns on once background DDI check finishes") {
            model.sessionOn && !model.sessionStarting
        }

        XCTAssertNil(model.problem)
        XCTAssertTrue(model.diskImage.hasFiles)
        XCTAssertFalse(model.diskImage.isChecking)
        // Verify checkTask did not get stuck non-nil so subsequent notice() still functions.
        model.diskImage.notice()
        await model.diskImage.ensureChecked()
        XCTAssertFalse(model.diskImage.isChecking)
        XCTAssertTrue(model.diskImage.hasFiles)
    }

    func testChatModelWaitsForSessionStoreBeforeSendingAndDoesNotClobberDraft() async throws {
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)
        let now = Date()
        let encoder = JSONEncoder()

        // Seed 60 sessions where:
        // - `recent-chat` (updated 30 min ago) is the latest in-app chat within 12h.
        // - `older-stopped` (updated 20 days ago, outside the first batch of 20 newest files) is a stopped task.
        var olderStopped = SavedSession(
            id: "older-stopped",
            kind: .poki,
            client: nil,
            title: "Inspect Safari preferences",
            started: now.addingTimeInterval(-20 * 86400),
            updated: now.addingTimeInterval(-20 * 86400),
            live: false,
            outcome: .stopped,
            entries: [
                ChatEntry(.time(now.addingTimeInterval(-20 * 86400))),
                ChatEntry(.you("Inspect Safari preferences", delivered: true)),
                ChatEntry(.poki("Stopped halfway.")),
            ],
            calls: []
        )
        olderStopped.entries[1].continuedTask = nil
        let olderURL = folder.appendingPathComponent("older-stopped.json")
        try encoder.encode(olderStopped).write(to: olderURL)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 86400)], ofItemAtPath: olderURL.path)

        for i in 0..<58 {
            let sid = String(format: "filler-%03d", i)
            let at = now.addingTimeInterval(-Double((i + 2) * 3600))
            let session = SavedSession(
                id: sid,
                kind: .agent,
                client: "Codex",
                title: "Agent \(i)",
                started: at,
                updated: at,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.time(at))],
                calls: []
            )
            let url = folder.appendingPathComponent("\(sid).json")
            try encoder.encode(session).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }

        let recentChat = SavedSession(
            id: "recent-chat",
            kind: .poki,
            client: nil,
            title: "Recent chat",
            started: now.addingTimeInterval(-1800),
            updated: now.addingTimeInterval(-1800),
            live: false,
            outcome: .done,
            entries: [
                ChatEntry(.time(now.addingTimeInterval(-1800))),
                ChatEntry(.you("Check battery level", delivered: true)),
                ChatEntry(.poki("Battery is at 80%.")),
            ],
            calls: []
        )
        let recentURL = folder.appendingPathComponent("recent-chat.json")
        try encoder.encode(recentChat).write(to: recentURL)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1800)], ofItemAtPath: recentURL.path)

        let server = try FakeCompletions(replies: [
            FakeCompletions.text("Followed up."),
            FakeCompletions.text("Resumed Safari task."),
            FakeCompletions.text("Resumed generic task."),
        ])
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom

        // 1. Typing a draft before initial load finishes must not be clobbered by restoreLatestIfUntouched().
        let draftStore = SessionStore.launchStore(folder: folder, defaults: defaults)
        let draftModel = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        defer { draftModel.stopSession() }
        let draftChat = ChatModel(app: draftModel, store: draftStore)
        let initialDraftSessionID = draftChat.sessionID
        draftChat.setDraftActivity(true)
        await draftStore.waitUntilLoaded()
        XCTAssertEqual(draftChat.sessionID, initialDraftSessionID, "Typing a draft before initial load must not switch away to an older chat")

        // 2. Sending a normal message before initial batch loads must restore the <12h chat rather than fork a new session.
        let sendStore = SessionStore.launchStore(folder: folder, defaults: defaults)
        XCTAssertFalse(sendStore.isInitialReady)
        let sendModel = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        defer { sendModel.stopSession() }
        let sendChat = ChatModel(app: sendModel, store: sendStore)
        sendChat.send("And check storage")
        await waitFor("normal send finishes after waiting for initial batch") { !sendChat.running }
        XCTAssertEqual(sendChat.sessionID, "recent-chat")

        // 3. Sending a continuation request before full load completes must wait for all sessions and resume the older stopped task.
        let contStore = SessionStore.launchStore(folder: folder, defaults: defaults)
        XCTAssertFalse(contStore.isLoaded)
        let contModel = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        defer { contModel.stopSession() }
        let contChat = ChatModel(app: contModel, store: contStore)
        contChat.send("继续 Inspect Safari preferences")
        await waitFor("continuation send finishes after waiting for full session load") { !contChat.running }
        XCTAssertEqual(contChat.sessionID, "older-stopped")

        // 4. Generic "继续" from Home (no <12h chat) before full load also waits for all batches to find older stopped tasks.
        try? FileManager.default.removeItem(at: recentURL)
        let genericStore = SessionStore.launchStore(folder: folder, defaults: defaults)
        XCTAssertFalse(genericStore.isLoaded)
        let genericModel = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        defer { genericModel.stopSession() }
        let genericChat = ChatModel(app: genericModel, store: genericStore)
        genericChat.send("继续")
        await waitFor("generic continuation finishes after waiting for full session load") { !genericChat.running }
        XCTAssertEqual(genericChat.sessionID, "older-stopped")
    }

    func testUpgradeBatchLoadDoesNotExposeUnarchivedSessionsBeforeArchiveCompletes() async throws {
        try seedLargeHistory(count: 80, archivedCount: 0, entriesPerSession: 10, callsPerSession: 4)
        let store = SessionStore.launchStore(folder: folder, defaults: defaults)

        var sawFlash = false
        while !store.isLoaded {
            if !store.listed.isEmpty { sawFlash = true }
            await Task.yield()
        }
        XCTAssertFalse(sawFlash, "Upgrade load must not expose unarchived old sessions in listed before archiving finishes")
        XCTAssertTrue(store.listed.isEmpty)
        XCTAssertEqual(store.archivedSessions.count, 80)
        XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
    }
}
