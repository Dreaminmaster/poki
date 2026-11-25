import XCTest
@testable import Poki

/// The first run shows on a fresh install and never to someone updating from a version they used; an
/// update's welcome shows once for each new version.
@MainActor
final class FirstRunDecisionTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "FirstRunDecisionTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FirstRunDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func launch() { FirstRun.decide(defaults: defaults, sessionsFolder: folder) }
    private var record: String? { defaults.string(forKey: FirstRun.key) }

    func testFreshInstallGetsTheFirstRun() {
        launch()
        XCTAssertEqual(record, "due")
    }

    func testAnUpdateFromAVersionInUseSkipsIt() throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        defaults.set(Data([1]), forKey: "setup")
        launch()
        XCTAssertEqual(record, "done")
    }

    func testLeavingHalfwayShowsItAgainNextLaunch() throws {
        launch()
        // What the first run's own steps saved before the app was closed does not count as an earlier version.
        defaults.set(Data([1]), forKey: "setup")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("new-1.json"))
        launch()
        XCTAssertEqual(record, "due")
        FirstRun.finish(defaults: defaults)
        launch()
        XCTAssertEqual(record, "done")
    }

    func testAFreshInstallGetsTheFirstRunsWelcome() {
        launch()
        XCTAssertEqual(FirstRun.pending(defaults: defaults, version: "0.4.7"), .firstRun)
    }

    func testEachNewVersionGetsOneWelcome() {
        launch()
        FirstRun.finish(defaults: defaults, version: "0.4.7")
        XCTAssertNil(FirstRun.pending(defaults: defaults, version: "0.4.7"))
        XCTAssertEqual(FirstRun.pending(defaults: defaults, version: "0.4.8"), .update("0.4.8"))
        FirstRun.finish(defaults: defaults, version: "0.4.8")
        XCTAssertNil(FirstRun.pending(defaults: defaults, version: "0.4.8"))
    }

    func testAnUpdateFromBeforeTheWelcomePanelGetsTheUpdatesWelcome() throws {
        defaults.set(Data([1]), forKey: "setup")
        launch()
        XCTAssertEqual(FirstRun.pending(defaults: defaults, version: "0.4.7"), .update("0.4.7"))
    }

    /// Closing the welcome lets the hint on Poki's picture show, but only for the app's own records: a
    /// test's defaults leave the shared tip state alone.
    func testFinishReleasesTheMenuHintOnlyForTheAppsOwnRecords() {
        let standard = UserDefaults.standard
        let saved = (standard.object(forKey: FirstRun.key), standard.object(forKey: FirstRun.versionKey))
        defer {
            standard.set(saved.0, forKey: FirstRun.key)
            standard.set(saved.1, forKey: FirstRun.versionKey)
            PokiMenuTip.welcomeUp = false
        }

        PokiMenuTip.welcomeUp = true
        FirstRun.finish(defaults: defaults, version: "0.5.1")
        XCTAssertTrue(PokiMenuTip.welcomeUp)

        FirstRun.finish(defaults: standard, version: FirstRun.version)
        XCTAssertFalse(PokiMenuTip.welcomeUp)
    }

    /// The in-app tests and scripted launches keep TipKit off, so the hint never pops over the
    /// screens and alerts they check. A person's own launch, or `-pokiResetTips`, shows it.
    func testMenuHintIsHeldBackForScriptedLaunches() {
        XCTAssertTrue(PokiMenuTip.heldBack(environment: ["XCTestBundlePath": "/tmp/PokiTests.xctest"], arguments: [:]))
        XCTAssertTrue(PokiMenuTip.heldBack(environment: [:], arguments: ["pokiScreen": "home"]))
        XCTAssertFalse(PokiMenuTip.heldBack(environment: [:], arguments: ["pokiScreen": "home", "pokiResetTips": "YES"]))
        XCTAssertFalse(PokiMenuTip.heldBack(environment: [:], arguments: [:]))
        XCTAssertFalse(PokiMenuTip.heldBack(environment: [:], arguments: ["AppleLanguages": "(en)"]))
    }
}
