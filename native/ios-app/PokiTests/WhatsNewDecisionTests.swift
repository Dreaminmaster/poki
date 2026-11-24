import XCTest
@testable import Poki

/// What's New shows once after an update when the catalog matches the installed app version,
/// stays dismissed on later launches of the same version, survives pending welcome and fresh
/// containers, defers cleanly around temporary launch blockers, and never shows on a fresh install.
@MainActor
final class WhatsNewDecisionTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "WhatsNewDecisionTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsNewDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeCatalog(version: String) -> WhatsNewRelease {
        WhatsNewRelease(
            version: version,
            items: [
                WhatsNewItem(
                    id: "sample",
                    symbol: "sparkles",
                    title: WhatsNewText(en: "Sample", zhHans: "示例", zhHant: "範例"),
                    summary: WhatsNewText(en: "Summary", zhHans: "说明", zhHant: "說明")
                )
            ]
        )
    }

    private func launch(version: String) {
        let priorFirstRun = defaults.string(forKey: FirstRun.key)
        FirstRun.decide(defaults: defaults, sessionsFolder: folder)
        WhatsNew.decide(
            installedVersion: version,
            priorFirstRun: priorFirstRun,
            defaults: defaults,
            sessionsFolder: folder
        )
    }

    func testFreshInstallSkipsWhatsNewEvenAfterFinishingFirstRun() {
        let catalog = makeCatalog(version: "0.5.0")
        launch(version: "0.5.0")
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: catalog, defaults: defaults),
            "A fresh install must not show What's New"
        )

        // Finishing the welcome guide and reopening the same version still must not show What's New.
        FirstRun.finish(defaults: defaults)
        launch(version: "0.5.0")
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: catalog, defaults: defaults),
            "Reopening the same version after a fresh install must not show What's New"
        )
    }

    func testUpgradeShowsOnceThenStaysDismissedUntilNextVersion() throws {
        let release050 = makeCatalog(version: "0.5.0")
        let release051 = makeCatalog(version: "0.5.1")

        // Seed an earlier version's trace (an existing user upgrading to 0.5.0).
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        defaults.set(Data([1]), forKey: "setup")

        launch(version: "0.5.0")
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "First launch after upgrading from an earlier version must show What's New"
        )

        // Closing the app without dismissing keeps it due on the next launch.
        launch(version: "0.5.0")
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "What's New remains due until the user dismisses it"
        )

        // Once dismissed, subsequent launches of the same version never show it again.
        WhatsNew.markSeen(version: "0.5.0", catalog: release050, defaults: defaults)
        launch(version: "0.5.0")
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "Dismissed What's New must not appear again on the same version"
        )

        // Upgrading to a newer release shows What's New once again.
        launch(version: "0.5.1")
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.1", catalog: release051, defaults: defaults),
            "Upgrading to a newer version must show What's New again"
        )
        WhatsNew.markSeen(version: "0.5.1", catalog: release051, defaults: defaults)
        launch(version: "0.5.1")
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.1", catalog: release051, defaults: defaults),
            "Dismissed newer What's New must not reappear"
        )
    }

    /// Regression for F2a: upgrading from an earlier version whose welcome guide was still pending
    /// must not overwrite `seenVersionKey` with the new version; once welcome finishes, What's New appears.
    func testUpgradeWithPendingWelcomeShowsWhatsNewAfterWelcomeFinishes() {
        let release050 = makeCatalog(version: "0.5.0")
        // Older build launched once and left FirstRun pending without a What's New seen record.
        defaults.set(FirstRun.Record.due.rawValue, forKey: FirstRun.key)

        launch(version: "0.5.0")
        XCTAssertNil(
            defaults.string(forKey: WhatsNew.seenVersionKey),
            "Upgrading while welcome is pending must not mark the new version as already seen"
        )
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "What's New waits while the welcome guide is still due"
        )

        FirstRun.finish(defaults: defaults)
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "After finishing the welcome guide, What's New must be due for the upgraded version"
        )

        launch(version: "0.5.0")
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "Relaunching after finishing welcome keeps What's New due until dismissed"
        )
    }

    /// Regression for F2b: a fresh container (for example after 7-day re-signing) that restored only
    /// `pokiWhatsNewSeenVersion` from Keychain must skip the same version and present on a newer version.
    func testFreshContainerWithOnlyRestoredSeenVersionShowsOnUpgradeAndSkipsSameVersion() {
        let release050 = makeCatalog(version: "0.5.0")
        let release051 = makeCatalog(version: "0.5.1")

        // Only the Keychain-restored seen version exists in the fresh container (no sessions or setup yet).
        defaults.set("0.5.0", forKey: WhatsNew.seenVersionKey)

        launch(version: "0.5.0")
        XCTAssertEqual(defaults.string(forKey: FirstRun.key), FirstRun.Record.done.rawValue)
        XCTAssertEqual(defaults.string(forKey: WhatsNew.seenVersionKey), "0.5.0")
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "Re-signing the same version into a fresh container must not re-show What's New"
        )

        // Now simulate a fresh container upgrade to 0.5.1 with only `seenVersion = 0.5.0` restored.
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        defaults.set("0.5.0", forKey: WhatsNew.seenVersionKey)

        launch(version: "0.5.1")
        XCTAssertEqual(
            defaults.string(forKey: WhatsNew.seenVersionKey),
            "0.5.0",
            "Fresh container upgrade must preserve the restored prior seen version instead of overwriting it"
        )
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.1", catalog: release051, defaults: defaults),
            "Fresh container upgrade with only a restored seen version must show What's New for 0.5.1"
        )
    }

    /// Regression for F3: a candidate build (e.g. 0.4.7) whose installed version does not match the
    /// catalog's version (0.5.0) must not present 0.5.0 notes or record 0.5.0 as seen.
    func testMismatchedAppVersionDoesNotPresentOrMarkFutureReleaseSeen() throws {
        let release050 = makeCatalog(version: "0.5.0")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        defaults.set(Data([1]), forKey: "setup")

        launch(version: "0.4.7")
        XCTAssertNil(
            WhatsNewCatalog.release(for: "0.4.7", catalog: release050),
            "Catalog notes for 0.5.0 must not match an installed 0.4.7 build"
        )
        XCTAssertFalse(
            WhatsNew.shouldPresent(installedVersion: "0.4.7", catalog: release050, defaults: defaults),
            "A 0.4.7 build must not pop up 0.5.0 What's New"
        )
        WhatsNew.markSeen(version: "0.4.7", catalog: release050, defaults: defaults)
        XCTAssertNil(
            defaults.string(forKey: WhatsNew.seenVersionKey),
            "Dismissing or running on a mismatched version must not record 0.5.0 as seen"
        )

        // Upgrading later to actual 0.5.0 still shows 0.5.0 What's New once.
        launch(version: "0.5.0")
        XCTAssertTrue(
            WhatsNew.shouldPresent(installedVersion: "0.5.0", catalog: release050, defaults: defaults),
            "Upgrading from 0.4.7 to actual 0.5.0 must present 0.5.0 What's New"
        )
    }

    /// Regression for F4: if Settings or welcome is temporarily open when Home finishes its first frame,
    /// the launch gate must defer instead of consuming the check and dropping What's New.
    func testTemporaryBlockerAtLaunchDefersWhatsNewUntilUnobstructed() {
        var gate = WhatsNewLaunchGate()
        let blockedBySettings = WhatsNewLaunchGate.Context(
            firstFrameDisplayed: true,
            curtainUp: false,
            sceneActive: true,
            welcoming: false,
            detailsOpen: true,
            installMessageActive: false,
            pairingUnderWay: false,
            whatsNewOpen: false
        )
        XCTAssertFalse(
            gate.beginSchedulingIfReady(context: blockedBySettings, isDue: { true }),
            "What's New must wait while deep-linked Settings is open"
        )

        let unobstructed = WhatsNewLaunchGate.Context(
            firstFrameDisplayed: true,
            curtainUp: false,
            sceneActive: true,
            welcoming: false,
            detailsOpen: false,
            installMessageActive: false,
            pairingUnderWay: false,
            whatsNewOpen: false
        )
        XCTAssertTrue(
            gate.beginSchedulingIfReady(context: unobstructed, isDue: { true }),
            "Closing Settings must allow What's New to schedule instead of being permanently skipped"
        )
        XCTAssertTrue(
            gate.commitIfStillReady(context: unobstructed, isDue: { true }),
            "Unobstructed commit must present What's New"
        )
        XCTAssertFalse(
            gate.beginSchedulingIfReady(context: unobstructed, isDue: { true }),
            "Once presented in a launch, the gate must not schedule a second time"
        )
    }

    /// Verifies language resolution across English, Simplified Chinese, and Traditional Chinese
    /// without pinning the current catalog's release number.
    func testWhatsNewTextResolvesLanguageSelection() {
        let text = WhatsNewText(en: "English", zhHans: "简体中文", zhHant: "繁體中文")
        XCTAssertEqual(text.resolved(for: "en"), "English")
        XCTAssertEqual(text.resolved(for: "fr"), "English")
        XCTAssertEqual(text.resolved(for: "zh-Hans"), "简体中文")
        XCTAssertEqual(text.resolved(for: "zh"), "简体中文")
        XCTAssertEqual(text.resolved(for: "zh-Hant"), "繁體中文")
        XCTAssertEqual(text.resolved(for: "zh-HK"), "繁體中文")
    }

    func testSmarterLiveVoiceCopyMatchesStopCancellationBehavior() throws {
        let item = try XCTUnwrap(WhatsNewCatalog.current.items.first { $0.id == "smarter-live-voice" })
        XCTAssertFalse(item.summary.en.contains("mutes voice, not tasks"), item.summary.en)
        XCTAssertTrue(item.summary.en.contains("to cancel tasks"), item.summary.en)
        XCTAssertTrue(item.summary.en.contains("to pause voice"), item.summary.en)
        XCTAssertFalse(item.summary.zhHans.contains("只静音不误停任务"), item.summary.zhHans)
        XCTAssertTrue(item.summary.zhHans.contains("取消任务"), item.summary.zhHans)
        XCTAssertTrue(item.summary.zhHans.contains("仅暂停播报"), item.summary.zhHans)
        XCTAssertFalse(item.summary.zhHant.contains("只靜音不誤停任務"), item.summary.zhHant)
        XCTAssertTrue(item.summary.zhHant.contains("取消任務"), item.summary.zhHant)
        XCTAssertTrue(item.summary.zhHant.contains("僅暫停播報"), item.summary.zhHant)
    }

    func testCurrentCatalogOrderAndTightenedOutcomeCopy() throws {
        let catalog = WhatsNewCatalog.current
        XCTAssertEqual(catalog.version, "0.5.0")
        XCTAssertEqual(
            catalog.items.map(\.id),
            [
                "chatgpt-sign-in",
                "faster-phone-actions",
                "watch-and-ask",
                "smarter-live-voice",
                "rich-result-cards",
                "memory-and-skills",
                "quick-app-picker",
                "refreshed-setup-menu",
                "ipad-and-duo-fixes",
                "mic-and-home-stability",
            ]
        )

        let forbiddenPunctuation = ["——", "—", " -- ", " · ", " • ", " ・ "]
        for item in catalog.items {
            let texts = [
                item.title.en, item.title.zhHans, item.title.zhHant,
                item.summary.en, item.summary.zhHans, item.summary.zhHant,
            ]
            for text in texts {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
                for forbidden in forbiddenPunctuation {
                    XCTAssertFalse(text.contains(forbidden), "\(item.id) contains forbidden separator \(forbidden): \(text)")
                }
            }
        }

        let speed = try XCTUnwrap(catalog.items.first { $0.id == "faster-phone-actions" })
        XCTAssertEqual(speed.title.en, "Faster Phone Actions")
        XCTAssertEqual(speed.title.zhHans, "操作全面提速")
        XCTAssertEqual(speed.title.zhHant, "操作全面提速")
        XCTAssertFalse(speed.title.en.contains("50%"), speed.title.en)
        XCTAssertFalse(speed.title.zhHans.contains("50%"), speed.title.zhHans)
        XCTAssertFalse(speed.title.zhHant.contains("50%"), speed.title.zhHant)
        XCTAssertFalse(speed.summary.en.contains("50%"), speed.summary.en)
        XCTAssertTrue(speed.summary.en.contains("respond noticeably faster"), speed.summary.en)

        let richCards = try XCTUnwrap(catalog.items.first { $0.id == "rich-result-cards" })
        XCTAssertFalse(richCards.summary.en.contains("fixing fare"), richCards.summary.en)
        XCTAssertFalse(richCards.summary.zhHans.contains("修复 12306"), richCards.summary.zhHans)
        XCTAssertFalse(richCards.summary.zhHant.contains("修復 12306"), richCards.summary.zhHant)

        let ipadFixes = try XCTUnwrap(catalog.items.first { $0.id == "ipad-and-duo-fixes" })
        XCTAssertFalse(ipadFixes.summary.en.contains("Fixed iPadOS"), ipadFixes.summary.en)
        XCTAssertFalse(ipadFixes.summary.zhHans.contains("修复 iPadOS"), ipadFixes.summary.zhHans)
        XCTAssertFalse(ipadFixes.summary.zhHant.contains("修復 iPadOS"), ipadFixes.summary.zhHant)
    }
}
