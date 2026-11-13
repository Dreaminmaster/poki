import XCTest
@testable import Poki

/// The dictation microphone is hidden by default, but earlier versions always showed it: the first launch
/// keeps it for someone who used the app before, once, and leaves a fresh install on the default.
@MainActor
final class DictationButtonMigrationTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "DictationButtonMigrationTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DictationButtonMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func launch() { FieldDictation.keepButtonForUpgrade(defaults: defaults, sessionsFolder: folder) }
    private var written: Bool? { defaults.object(forKey: FieldDictation.buttonKey) as? Bool }

    func testFreshInstallKeepsTheButtonHidden() {
        launch()
        XCTAssertNil(written, "nothing is written, so the default (hidden) stands")
    }

    func testSavedConversationsMeanAnUpgrade() throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        launch()
        XCTAssertEqual(written, true)
    }

    func testAnEarlierSettingMeansAnUpgradeEvenWithNoConversations() {
        defaults.set(Data([1]), forKey: "setup")
        launch()
        XCTAssertEqual(written, true)
    }

    func testItRunsOnce() throws {
        launch()
        // A fresh install that has since saved a conversation is not mistaken for an upgrade.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("new-1.json"))
        launch()
        XCTAssertNil(written)
    }

    func testAnUpgraderWhoTurnsItOffKeepsItOff() throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        launch()
        defaults.set(false, forKey: FieldDictation.buttonKey)
        launch()
        XCTAssertEqual(written, false)
    }

    func testAChoiceAlreadyMadeIsNotOverwritten() throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        defaults.set(false, forKey: FieldDictation.buttonKey)
        launch()
        XCTAssertEqual(written, false)
    }
}
