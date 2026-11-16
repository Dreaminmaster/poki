import CryptoKit
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class LaunchWatchdogTests: XCTestCase {
    private var folder: URL!
    private var ddiBackup: URL?
    private var defaults: UserDefaults!
    private let suite = "LaunchWatchdogTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
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

    func testLargeUpgradeStartupCompletesFirstFrameWithinBudget() async throws {
        try seedLargeHistory(count: 400, archivedCount: 250, entriesPerSession: 100, callsPerSession: 50)
        try seedDiskImageFixture()

        let t0 = ContinuousClock.now
        let diskImage = DiskImageStore()
        let store = SessionStore.launchStore(folder: folder, defaults: defaults)
        let tStore = ContinuousClock.now - t0

        let t1 = ContinuousClock.now
        let shortcutStore = HomeShortcutStore()
        shortcutStore.refreshInBackground(sessions: store.sessions, routines: { [] })
        let tShortcuts = ContinuousClock.now - t1

        let t2 = ContinuousClock.now
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: RootView().environment(model).environment(chat))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()
        let tFrame = ContinuousClock.now - t2
        defer { window.isHidden = true; model.stopSession() }

        let total = tStore + tShortcuts + tFrame
        print("WATCHDOG_TIMING store=\(tStore) shortcuts=\(tShortcuts) frame=\(tFrame) total=\(total)")
        XCTAssertLessThan(total, .milliseconds(500), "First frame with large session history and DDI must not block the main thread (store=\(tStore), shortcuts=\(tShortcuts), frame=\(tFrame))")

        await store.waitUntilLoaded()
        await diskImage.ensureChecked()

        XCTAssertEqual(store.sessions.count, 400)
        XCTAssertEqual(store.archivedSessions.count, 400)
        XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        XCTAssertTrue(diskImage.hasFiles)

        shortcutStore.refreshInBackground(sessions: store.sessions, routines: { [] })
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
        XCTAssertLessThan(elapsed, .milliseconds(100), "Init with 40 sessions and 80 MB DDI must return immediately (took \(elapsed))")

        await store.waitUntilLoaded()
        await diskImage.ensureChecked()

        XCTAssertEqual(store.sessions.count, 40)
        XCTAssertEqual(store.archivedSessions.count, 40)
        XCTAssertTrue(defaults.bool(forKey: SessionStore.archivedEarlierKey))
        XCTAssertTrue(diskImage.hasFiles)
    }
}
