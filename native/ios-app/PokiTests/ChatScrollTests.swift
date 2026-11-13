import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// The conversation's scrolling (ESP-468): what you send is in view at once, the newest stays in view
/// above the keyboard and the approval card while you are at it, and reading back is never pulled away
/// from but offered a way back.
@MainActor
final class ChatScrollTests: XCTestCase {
    private var window: UIWindow?
    private var feed: Feed?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        feed = nil
    }

    func testSendingWhileReadingBackShowsTheNewMessage() throws {
        let (scroll, feed) = try transcript()
        readBack(scroll)
        XCTAssertGreaterThan(gap(scroll), 400)

        feed.entries.append(ChatEntry(.you("Order my usual coffee", delivered: false)))
        settle { self.gap(scroll) < 2 }
        XCTAssertLessThan(gap(scroll), 2, "The message just sent must be in view")
    }

    func testAReplyDoesNotPullYouAwayFromWhatYouAreReading() throws {
        let (scroll, feed) = try transcript()
        readBack(scroll)
        let reading = scroll.contentOffset.y

        feed.entries.append(ChatEntry(.poki("Sent. Mom has it. Anything else?")))
        pump(1)
        XCTAssertEqual(scroll.contentOffset.y, reading, accuracy: 1, "A reply must not pull you away from what you are reading")
    }

    func testSearchJumpToAnOlderMessageMovesScrollAwayFromNewest() throws {
        let (scroll, feed) = try transcript()
        XCTAssertLessThan(gap(scroll), 2)
        let target = feed.entries[8].id
        let jump = ConversationSearchJump(sessionID: "search-fixture", entryID: target)
        feed.jump = jump
        settle { self.gap(scroll) > 200 && feed.appliedJump == jump.requestID }
        XCTAssertGreaterThan(gap(scroll), 200, "A matching saved message should be in view, not the newest message")
        XCTAssertEqual(feed.appliedJump, jump.requestID, "Navigation must acknowledge the exact request")
    }

    /// The owner's case, on the chat page itself with its demo conversation: a new conversation, the
    /// keyboard up, a message sent, then Poki's reply, the task card growing step by step and the
    /// approval card over the message field. The page stayed at its top, and the reply and the task
    /// card went under the approval card and the keyboard.
    func testANewConversationOnTheChatPageFollowsTheNewestUnderTheKeyboard() throws {
        let saved = UserDefaults.standard.object(forKey: "pokiChat")
        UserDefaults.standard.set("demo", forKey: "pokiChat")
        defer { UserDefaults.standard.set(saved, forKey: "pokiChat") }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        let window = try show(NavigationStack {
            ChatView(openDetails: { _ in }, openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(app).environment(chat))
        settle { Self.find(CapsuleTextView.self, in: window) != nil }
        let field = try XCTUnwrap(Self.find(CapsuleTextView.self, in: window))
        field.becomeFirstResponder()
        settle { field.isFirstResponder }
        pump(1)

        chat.send("Text Mom I’m on my way")
        // The approval card slides in over the message field after the last step.
        settle(for: 12) { chat.demoAsk != nil }
        XCTAssertNotNil(chat.demoAsk, "The demo must reach its approval card")
        pump(1)
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: window))
        XCTAssertLessThan(gap(scroll), 2, "The task card must stay in view above the approval card and the keyboard")
    }

    // MARK: Fixture

    /// A conversation longer than the screen, under a top bar and above a message field, as on the chat.
    private func transcript() throws -> (UIScrollView, Feed) {
        let feed = Feed()
        self.feed = feed
        let window = try show(Host(feed: feed))
        settle { Self.transcriptScroll(in: window).map { $0.contentSize.height > 2000 } ?? false }
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: window))
        settle { self.gap(scroll) < 2 }
        return (scroll, feed)
    }

    private func show(_ page: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: page)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    /// The user drags up to read back toward the start of the conversation.
    private func readBack(_ scroll: UIScrollView) {
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y - 900), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        pump(0.5)
    }

    /// How far the end of the conversation is below the visible part, in points.
    private func gap(_ scroll: UIScrollView) -> CGFloat {
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom
        return end - (scroll.contentOffset.y + scroll.bounds.height)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func settle(for seconds: TimeInterval = 3, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The conversation's scroll view: the first one on the page, in front of the home page's.
    private static func transcriptScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !(scroll is UITextView), !(scroll is MarqueeScrollView) { return scroll }
        for child in view.subviews { if let found = transcriptScroll(in: child) { return found } }
        return nil
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }

    private final class Feed: ObservableObject {
        @Published var jump: ConversationSearchJump?
        @Published var appliedJump: UUID?
        @Published var entries: [ChatEntry] = (0..<30).flatMap { i in
            [ChatEntry(.you("Question \(i): what is on my calendar this afternoon?", delivered: true)),
             ChatEntry(.poki("Answer \(i): a design review at three and a call with the bank at five."))]
        }
    }

    private struct Host: View {
        @ObservedObject var feed: Feed
        var body: some View {
            ChatTranscript(entries: feed.entries, jump: feed.jump,
                           onSearchJumpApplied: { feed.appliedJump = $0 }) { EmptyView() }
                .topBar { Color.clear.frame(height: 110) }
                .bottomBar { Color.clear.frame(height: 80) }
        }
    }
}
