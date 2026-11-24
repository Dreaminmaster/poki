import XCTest
@testable import Poki

/// The chat's opening words say whether Poki asks before a sensitive step, as Poki’s Rules page has it.
@MainActor
final class GreetingTests: XCTestCase {
    private var hostLocalization: HostLocalizationSnapshot!
    private var storage: IsolatedTestStorage!
    private var localization: AppLocalization!
    private static let promise = "Asks before irreversible steps."
    private static let expectedOffGreetingEN = "Payments, deletions in menus and confirmation dialogs (and matching deletions when full screen details are unavailable, such as voice taps by button name), and Wallet actions always require your confirmation; other sensitive steps go ahead without asking."

    override func setUp() async throws {
        hostLocalization = HostLocalizationSnapshot.capture()
        storage = try IsolatedTestStorage(prefix: "greeting")
        localization = AppLocalization(storage: storage.storage)
        localization.preference = "en"
    }

    override func tearDown() async throws {
        hostLocalization.assertUnchanged()
        localization = nil
        if let storage {
            self.storage = nil
            try storage.tearDown()
        }
    }

    private func greeting(_ chat: ChatModel) -> [String] {
        chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }
    }

    private func newChat(asking mode: ApprovalClassifier.Mode) -> (AppModel, ChatModel) {
        storage.defaults.set(mode.rawValue, forKey: ApprovalClassifier.modeKey)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        let chat = ChatModel(app: app, localization: localization)
        chat.newConversation()
        return (app, chat)
    }

    /// With Never Ask the line under the bear says what still asks, as the top of Approvals has it:
    /// payments, deletions in menus and confirmation dialogs (or when full screen details are
    /// unavailable), and Wallet need the owner, and the other sensitive steps go ahead.
    func testTheGreetingPromisesToAskOnlyWhenAskingIsOn() {
        let (_, off) = newChat(asking: .off)
        XCTAssertFalse(greeting(off).contains(Self.promise), "\(greeting(off))")
        XCTAssertEqual(greeting(off).last, Self.expectedOffGreetingEN)
        let (_, on) = newChat(asking: .confirm)
        XCTAssertTrue(greeting(on).contains(Self.promise), "\(greeting(on))")
    }

    /// Turning asking off while a new conversation shows only its greeting changes the greeting.
    func testTurningAskingOffChangesAnUntouchedGreeting() {
        let (app, chat) = newChat(asking: .reply)
        app.approvalMode = .off
        XCTAssertFalse(greeting(chat).contains(Self.promise), "\(greeting(chat))")
    }

    /// English, Simplified Chinese, and Traditional Chinese approval copy across chat greetings,
    /// Settings (`ApprovalsSettingsView` / `ApprovalsSections`), and the bear menu (`PokiStatusCard`)
    /// must consistently state that payments, deletions in menus and confirmation dialogs (and
    /// matching deletions when full screen details are unavailable, such as voice taps by button
    /// name), and Wallet actions still require confirmation — while keeping host language
    /// preferences untouched.
    func testApprovalCopyMatchesScopedDeletionRuleAcrossLocalizations() {
        let checks: [(lang: String, menuOrDialogToken: String, sensitiveDeleteToken: String, noTreeToken: String, matchingDeleteToken: String, paymentToken: String, walletToken: String)] = [
            ("en", "menus and confirmation dialogs", "menus or confirmation dialogs", "full screen details are unavailable", "matching deletions", "Payments", "Wallet"),
            ("zh-Hans", "菜单和确认弹窗中的删除", "菜单或确认弹窗中的删除", "缺少完整页面信息时", "符合条件的删除", "付款", "钱包"),
            ("zh-Hant", "選單和確認彈窗中的刪除", "選單或確認彈窗中的刪除", "缺少完整頁面資訊時", "符合條件的刪除", "付款", "錢包"),
        ]

        for check in checks {
            localization.preference = check.lang
            let (_, off) = newChat(asking: .off)
            let offGreeting = greeting(off).last ?? ""
            XCTAssertEqual(offGreeting, localization.text(ApprovalCopy.neverAskGreeting), "\(check.lang) greeting mismatch")
            XCTAssertTrue(offGreeting.contains(check.menuOrDialogToken), "\(check.lang) greeting: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.noTreeToken), "\(check.lang) greeting missing no-tree exception: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.matchingDeleteToken), "\(check.lang) greeting missing matching-deletion scope: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.paymentToken), "\(check.lang) greeting: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.walletToken), "\(check.lang) greeting: \(offGreeting)")

            // Shared resource used by PokiDetailsView (ApprovalsSettingsView banner), MainTabs (ApprovalsSections), and PokiStatusCard (approval menu header).
            let banner = localization.text(ApprovalCopy.alwaysConfirm)
            XCTAssertTrue(banner.contains(check.menuOrDialogToken), "\(check.lang) banner: \(banner)")
            XCTAssertTrue(banner.contains(check.noTreeToken), "\(check.lang) banner missing no-tree exception: \(banner)")
            XCTAssertTrue(banner.contains(check.matchingDeleteToken), "\(check.lang) banner missing matching-deletion scope: \(banner)")
            XCTAssertTrue(banner.contains(check.paymentToken), "\(check.lang) banner: \(banner)")
            XCTAssertTrue(banner.contains(check.walletToken), "\(check.lang) banner: \(banner)")

            // Shared resource used by MainTabs (ApprovalsSections .off footer) and PokiDetailsView (ApprovalsSettingsView Learn More .off footer).
            let offFooter = localization.text(ApprovalCopy.neverAskFooter)
            XCTAssertTrue(offFooter.contains(check.menuOrDialogToken), "\(check.lang) offFooter: \(offFooter)")
            XCTAssertTrue(offFooter.contains(check.noTreeToken), "\(check.lang) offFooter missing no-tree exception: \(offFooter)")
            XCTAssertTrue(offFooter.contains(check.matchingDeleteToken), "\(check.lang) offFooter missing matching-deletion scope: \(offFooter)")
            XCTAssertTrue(offFooter.contains(check.paymentToken), "\(check.lang) offFooter: \(offFooter)")
            XCTAssertTrue(offFooter.contains(check.walletToken), "\(check.lang) offFooter: \(offFooter)")

            // Shared resource used by MainTabs (ApprovalsSections) and PokiDetailsView (ApprovalsSettingsView Learn More).
            let sensitive = localization.text(ApprovalCopy.sensitiveSteps)
            XCTAssertTrue(sensitive.contains(check.sensitiveDeleteToken), "\(check.lang) sensitive: \(sensitive)")
            XCTAssertTrue(sensitive.contains(check.noTreeToken), "\(check.lang) sensitive missing no-tree exception: \(sensitive)")
            XCTAssertTrue(sensitive.contains(check.matchingDeleteToken), "\(check.lang) sensitive missing matching-deletion scope: \(sensitive)")
            XCTAssertTrue(sensitive.contains(check.walletToken), "\(check.lang) sensitive: \(sensitive)")

            XCTAssertEqual(storage.defaults.string(forKey: AppLocalization.key), check.lang)
            XCTAssertEqual(storage.appGroupDefaults.string(forKey: AppLocalization.effectiveKey), check.lang)
            hostLocalization.assertUnchanged()
        }
    }
}
