import XCTest
import UserNotifications
@testable import Poki

@MainActor
final class LanguageTests: XCTestCase {
    private var preference = "system"
    private var defaults: [String: Any] = [:]
    private let routingKeys = ["chat.provider", "chat.customURL", "chat.customModel"]

    override func setUp() async throws {
        preference = AppLocalization.shared.preference
        for key in routingKeys { defaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        AppLocalization.shared.preference = preference
        for key in routingKeys { UserDefaults.standard.set(defaults[key], forKey: key) }
    }

    func testEachDeclaredLanguageIsOfferedExactlyOnce() throws {
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String])
        XCTAssertFalse(declared.isEmpty)
        for language in declared where language != "Base" {
            XCTAssertEqual(AppLocalization.languages.filter { $0 == language }.count, 1, language)
        }
        XCTAssertFalse(AppLocalization.languages.contains("Base"))
    }

    func testSystemMatchingAndUnsupportedPreferenceFallback() {
        let supported = ["en", "zh-Hans", "zh-Hant"]
        XCTAssertEqual(AppLocalization.resolve("system", supported: supported, preferred: ["zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.resolve("removed-language", supported: supported, preferred: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolve("system", supported: supported, preferred: ["fr-FR"]), "en")
        XCTAssertEqual(AppLocalization.resolve("en", supported: supported, preferred: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLocalization.resolve("system", supported: supported + ["ar"], preferred: ["ar-SA"]), "ar")
        AppLocalization.shared.preference = AppLocalization.system
        XCTAssertEqual(AppLocalization.language, Bundle.main.preferredLocalizations.first)
    }

    func testResourcesStatusFontsAndSharedPreferenceChangeTogether() {
        let cases: [(String, String, String, AppLanguage)] = [
            ("en", "General", "Ready", .english),
            ("zh-Hans", "通用", "就绪", .simplifiedChinese),
            ("zh-Hant", "一般", "就緒", .traditionalChinese),
        ]
        for (language, general, ready, appLanguage) in cases {
            AppLocalization.shared.preference = language
            XCTAssertEqual(AppLocalization.text("General"), general)
            XCTAssertEqual(StatusWord.ready.text, ready)
            XCTAssertEqual(AppLocalization.bundle.localizedString(forKey: "General", value: nil, table: nil), general)
            XCTAssertEqual(AppLanguage.current, appLanguage)
            XCTAssertEqual(Prominent.usesGeist, language == "en")
            XCTAssertEqual(ActivityTheme.usesGeist, language == "en")
            XCTAssertEqual(UserDefaults.standard.string(forKey: AppLocalization.key), language)
            XCTAssertEqual(SharedContainer.defaults.string(forKey: "effectiveUILanguage"), language)
            XCTAssertEqual(AppLocalization.locale.region, Locale.current.region)
        }
    }

    func testDefaultShortcutCacheRefreshesWithoutChangingStoredRequests() {
        let store = HomeShortcutStore()
        AppLocalization.shared.preference = "en"
        store.refresh(sessions: [], routines: [])
        let english = store.shortcuts.map(\.text)
        AppLocalization.shared.preference = "zh-Hans"
        store.refresh(sessions: [], routines: [])
        XCTAssertNotEqual(store.shortcuts.map(\.text), english)
        XCTAssertTrue(store.shortcuts.contains { $0.text == "发消息" })
    }

    func testLanguageSurvivesSettingsVaultRestoration() throws {
        let backup = try Keychain.read("settings.v1")
        defer {
            if let backup { try? Keychain.write(backup, account: "settings.v1") }
            else { Keychain.delete("settings.v1") }
        }
        AppLocalization.shared.preference = "zh-Hant"
        SettingsVault.save()
        UserDefaults.standard.removeObject(forKey: AppLocalization.key)
        SettingsVault.restore()
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppLocalization.key), "zh-Hant")
    }

    func testNotificationActionsRefreshWithLanguageWithoutChangingTheirMeaning() async throws {
        let center = UNUserNotificationCenter.current()
        let original = await center.notificationCategories()
        defer { center.setNotificationCategories(original) }
        AppLocalization.shared.preference = "zh-Hant"
        ApprovalNotice.registerActions()
        let categories = await center.notificationCategories()
        let actions = try XCTUnwrap(categories.first { $0.identifier == ApprovalNotice.category }).actions
        let allow = try XCTUnwrap(actions.first { $0.identifier == ApprovalNotice.allow })
        XCTAssertEqual(allow.title, "允許")
        XCTAssertTrue(allow.options.contains(.authenticationRequired))
        XCTAssertTrue(actions.first { $0.identifier == ApprovalNotice.deny }?.options.contains(.destructive) == true)
    }

    func testLanguageRefreshPreservesApprovalAndActivityState() throws {
        let activity = ActivityController()
        let ask = PendingApproval(id: "language-test", app: "Notes", summary: "Original task", reason: "raw reason", expires: .distantFuture)
        activity.update { state in
            state.phase = .approval
            state.approval = ask
            state.headline = "Original task"
            state.plan = .init(steps: ["Original step"], current: 1)
            state.stepCount = 3
        }
        let before = activity.state
        AppLocalization.shared.preference = "zh-Hant"
        activity.languageChanged()
        var expected = before
        expected.uiLanguage = "zh-Hant"
        XCTAssertEqual(activity.state, expected)
        let encoded = try JSONEncoder().encode(before)
        XCTAssertEqual(try JSONDecoder().decode(PokiState.self, from: encoded), before)
    }

    func testUntouchedIntroductionUpdatesWithoutReplacingEntriesOrSession() {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        AppLocalization.shared.preference = "en"
        chat.newConversation()
        let before = chat.entries
        let session = chat.sessionID
        AppLocalization.shared.preference = "zh-Hans"
        chat.languageChanged()
        XCTAssertEqual(chat.sessionID, session)
        XCTAssertEqual(chat.entries.map(\.id), before.map(\.id))
        XCTAssertEqual(chat.entries.map(\.at), before.map(\.at))
        XCTAssertNotEqual(chat.entries[1].kind, before[1].kind)
    }

    /// A local scripted endpoint exercises the real request path. No provider or physical input.
    func testSwitchingDuringRequestKeepsRoutingTaskAndRecordedContent() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Original model reply")])
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        let chat = ChatModel(app: app, kind: .handoff, requester: "Test agent")
        let identity = chat.sessionID
        chat.send("Original user request")
        XCTAssertTrue(chat.running)
        let original = chat.entries
        AppLocalization.shared.preference = "zh-Hant"
        app.languageChanged()
        chat.languageChanged()
        XCTAssertTrue(chat.running)
        XCTAssertEqual(chat.entries, original)
        XCTAssertEqual(chat.sessionID, identity)
        XCTAssertEqual(ModelKeys.selectedProvider, .custom)
        XCTAssertEqual(ModelKeys.customModel, "fake-model")
        let deadline = ContinuousClock.now + .seconds(15)
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
        XCTAssertEqual(server.requests.count, 1)
        let completed = chat.entries
        XCTAssertTrue(completed.contains { $0.kind == .poki("Original model reply") })
        AppLocalization.shared.preference = "en"
        chat.languageChanged()
        XCTAssertEqual(chat.entries, completed)
    }
}
