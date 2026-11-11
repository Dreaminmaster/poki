import XCTest
@testable import Poki

/// The chat's opening words say whether Poki asks before a sensitive step, as Poki’s Rules page has it.
@MainActor
final class GreetingTests: XCTestCase {
    private var saved: Any?
    private static let promise = "I’ll ask before anything you can’t undo."

    override func setUp() async throws { saved = UserDefaults.standard.object(forKey: ApprovalClassifier.modeKey) }
    override func tearDown() async throws { UserDefaults.standard.set(saved, forKey: ApprovalClassifier.modeKey) }

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

    func testTheGreetingPromisesToAskOnlyWhenAskingIsOn() {
        let (_, off) = newChat(asking: .off)
        XCTAssertFalse(greeting(off).contains(Self.promise), "\(greeting(off))")
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
