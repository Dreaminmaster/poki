import XCTest
@testable import Poki

/// The chat's opening words say whether Poki asks before a sensitive step, as Poki’s Rules page has it.
@MainActor
final class GreetingTests: XCTestCase {
    private var language = AppLocalization.system
    private var saved: Any?
    private static let promise = "Asks before irreversible steps."

    override func setUp() async throws {
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        saved = UserDefaults.standard.object(forKey: ApprovalClassifier.modeKey)
    }
    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: ApprovalClassifier.modeKey)
        AppLocalization.shared.preference = language
    }

    private func greeting(_ chat: ChatModel) -> [String] {
        chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }
    }

    private func newChat(asking mode: ApprovalClassifier.Mode) -> (AppModel, ChatModel) {
        UserDefaults.standard.set(mode.rawValue, forKey: ApprovalClassifier.modeKey)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        chat.newConversation()
        return (app, chat)
    }

    /// With Never Ask the line under the bear says what still asks, as the top of Approvals has it:
    /// payments, deletions and Wallet need the owner, and the other sensitive steps go ahead.
    func testTheGreetingPromisesToAskOnlyWhenAskingIsOn() {
        let (_, off) = newChat(asking: .off)
        XCTAssertFalse(greeting(off).contains(Self.promise), "\(greeting(off))")
        XCTAssertEqual(greeting(off).last, "Payments, deletions, and Wallet actions always require your confirmation; other sensitive steps go ahead without asking.")
        let (_, on) = newChat(asking: .confirm)
        XCTAssertTrue(greeting(on).contains(Self.promise), "\(greeting(on))")
    }

    /// Turning asking off while a new conversation shows only its greeting changes the greeting.
    func testTurningAskingOffChangesAnUntouchedGreeting() {
        let (app, chat) = newChat(asking: .reply)
        app.approvalMode = .off
        XCTAssertFalse(greeting(chat).contains(Self.promise), "\(greeting(chat))")
    }
}
