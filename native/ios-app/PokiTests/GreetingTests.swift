import XCTest
@testable import Poki

/// The chat's opening words say whether Poki asks before a sensitive step, as Poki’s Rules page has it.
@MainActor
final class GreetingTests: XCTestCase {
    private var language = AppLocalization.system
    private var storage: IsolatedTestStorage!
    private static let promise = "Asks before irreversible steps."
    private static let expectedOffGreetingEN = "Payments, deletions in menus and confirmation dialogs, and Wallet actions always require your confirmation; other sensitive steps go ahead without asking."

    override func setUp() async throws {
        language = AppLocalization.shared.preference
        storage = try IsolatedTestStorage(prefix: "greeting")
        storage.activate()
        AppLocalization.shared.preference = "en"
    }
    override func tearDown() async throws {
        AppLocalization.shared.preference = language
        if let storage {
            self.storage = nil
            try storage.tearDown()
        }
    }

    private func greeting(_ chat: ChatModel) -> [String] {
        chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }
    }

    private func newChat(asking mode: ApprovalClassifier.Mode) -> (AppModel, ChatModel) {
        PokiStorage.defaults.set(mode.rawValue, forKey: ApprovalClassifier.modeKey)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        chat.newConversation()
        return (app, chat)
    }

    /// With Never Ask the line under the bear says what still asks, as the top of Approvals has it:
    /// payments, deletions in menus and confirmation dialogs, and Wallet need the owner, and the
    /// other sensitive steps go ahead.
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

    /// English, Simplified Chinese, and Traditional Chinese approval copy must consistently state
    /// that only deletions in menus and confirmation dialogs (not all deletions unconditionally)
    /// always require confirmation, alongside payments and Wallet actions.
    func testApprovalCopyMatchesScopedDeletionRuleAcrossLocalizations() {
        let checks: [(lang: String, menuOrDialogToken: String, paymentToken: String, walletToken: String)] = [
            ("en", "menus and confirmation dialogs", "Payments", "Wallet"),
            ("zh-Hans", "菜单和确认弹窗中的删除", "付款", "钱包"),
            ("zh-Hant", "選單和確認彈窗中的刪除", "付款", "錢包"),
        ]
        let bannerKey = LocalizedStringResource("Payments, deletions in menus and confirmation dialogs, and Wallet actions always require your confirmation.")
        let offFooterKey = LocalizedStringResource("Optional steps continue without asking. Payments, deletions in menus and confirmation dialogs, and Wallet actions still require your confirmation.")
        let sensitiveKey = LocalizedStringResource("Sensitive steps are paying, deleting in menus or confirmation dialogs, sending a message, placing a call, typing a password, and anything in Wallet.")

        for check in checks {
            AppLocalization.shared.preference = check.lang
            let (_, off) = newChat(asking: .off)
            let offGreeting = greeting(off).last ?? ""
            XCTAssertTrue(offGreeting.contains(check.menuOrDialogToken), "\(check.lang) greeting: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.paymentToken), "\(check.lang) greeting: \(offGreeting)")
            XCTAssertTrue(offGreeting.contains(check.walletToken), "\(check.lang) greeting: \(offGreeting)")

            let banner = AppLocalization.text(bannerKey)
            XCTAssertTrue(banner.contains(check.menuOrDialogToken), "\(check.lang) banner: \(banner)")
            XCTAssertTrue(banner.contains(check.paymentToken), "\(check.lang) banner: \(banner)")
            XCTAssertTrue(banner.contains(check.walletToken), "\(check.lang) banner: \(banner)")

            let offFooter = AppLocalization.text(offFooterKey)
            XCTAssertTrue(offFooter.contains(check.menuOrDialogToken), "\(check.lang) offFooter: \(offFooter)")
            XCTAssertTrue(offFooter.contains(check.walletToken), "\(check.lang) offFooter: \(offFooter)")

            let sensitive = AppLocalization.text(sensitiveKey)
            let sensitiveDeleteToken = check.lang == "en" ? "menus or confirmation dialogs"
                : (check.lang == "zh-Hans" ? "菜单或确认弹窗中的删除" : "選單或確認彈窗中的刪除")
            XCTAssertTrue(sensitive.contains(sensitiveDeleteToken), "\(check.lang) sensitive: \(sensitive)")
        }
    }
}
