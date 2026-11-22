import SwiftUI
import UIKit
import PokiCore
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

    /// Opening and dismissing a saved-message jump only changes scroll position: it must not
    /// unmount the composer, discard unsent text, or replace the active conversation.
    func testSearchJumpAndCancellationKeepUnsentChatDraft() throws {
        let savedChat = UserDefaults.standard.object(forKey: "pokiChat")
        UserDefaults.standard.set("demo", forKey: "pokiChat")
        defer { UserDefaults.standard.set(savedChat, forKey: "pokiChat") }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        let feed = Feed()
        self.feed = feed
        let window = try show(NavigationStack {
            SearchChatHost(feed: feed)
        }.environment(app).environment(chat))
        settle { Self.find(CapsuleTextView.self, in: window) != nil }
        let field = try XCTUnwrap(Self.find(CapsuleTextView.self, in: window))
        // ChatView's standalone draft is local state, not RootView's persisted pokiDraft.
        // Exercise the actual composer input before navigation, as the owner would.
        let draft = "Draft that must remain unsent"
        field.becomeFirstResponder()
        field.insertText(draft)
        settle { field.plainText == draft }
        XCTAssertEqual(field.plainText, draft)
        field.resignFirstResponder()
        let originalID = chat.sessionID
        let originalEntries = chat.entries

        let selected = try XCTUnwrap(chat.entries.first?.id)
        feed.jump = ConversationSearchJump(sessionID: originalID, entryID: selected)
        pump(0.4)
        let afterJump = try XCTUnwrap(Self.find(CapsuleTextView.self, in: window))
        XCTAssertTrue(afterJump === field, "search navigation must not unmount the active composer")
        XCTAssertEqual(afterJump.plainText, "Draft that must remain unsent")
        XCTAssertEqual(chat.entries, originalEntries)
        XCTAssertEqual(chat.sessionID, originalID)

        feed.jump = nil
        pump(0.3)
        let afterCancel = try XCTUnwrap(Self.find(CapsuleTextView.self, in: window))
        XCTAssertTrue(afterCancel === field, "cancelling a search jump must keep the same composer")
        XCTAssertEqual(afterCancel.plainText, "Draft that must remain unsent")
        XCTAssertEqual(chat.entries, originalEntries)
        XCTAssertEqual(chat.sessionID, originalID)
    }

    /// Opening-line selection: the actual scrolling and source navigation
    /// are covered by the separate black-box UI test target.
    func testSelectedOpeningGreetingDoesNotExposeUnrelatedOpeningLines() {
        let greeting = ChatEntry(.poki("Synthetic greeting match"))
        let unrelated = ChatEntry(.poki("Synthetic previous approval setting"))
        let owner = ChatEntry(.you("Synthetic ordinary hit", delivered: true))
        let entries = [greeting, unrelated, owner]

        XCTAssertEqual(ChatView.transcriptEntries(entries, revealed: nil).map(\.id), [owner.id])
        XCTAssertEqual(ChatView.transcriptEntries(entries, revealed: greeting.id).map(\.id),
                       [greeting.id, owner.id])
        XCTAssertEqual(ChatView.transcriptEntries(entries, revealed: owner.id).map(\.id), [owner.id])
        XCTAssertFalse(ChatView.transcriptEntries(entries, revealed: greeting.id).contains { $0.id == unrelated.id })
    }

    func testHomeComposerKeepsItsMarginsInTheDuoLeftPane() throws {
        let (reference, actual) = try duoHomeComposerFrames(size: CGSize(width: 469, height: 669), inDuoSplitView: true)
        XCTAssertEqual(actual.minX, reference.minX, accuracy: 1, "The left safe area moved the composer")
        XCTAssertEqual(actual.maxX, reference.maxX, accuracy: 1, "The right side of the composer moved")
    }

    func testFoldedDuoHomeRespectsItsLeadingSafeArea() throws {
        try XCTSkipUnless(PKInProcess.canUseDuoSplitView(), "Run on the iPhone Duo simulator.")
        XCTAssertFalse(PKInProcess.shared().hasDuoCompanion)
        let (reference, actual) = try duoHomeComposerFrames()
        XCTAssertGreaterThan(actual.minX, reference.minX, "The folded home must respond to the leading safe area")
        XCTAssertGreaterThanOrEqual(actual.minX, 84, "The folded home must keep the composer inside the safe area")
    }

    func testDuoHomeRestoresItsLeadingSafeAreaWhenFoldedDuringACompanionTask() throws {
        try XCTSkipUnless(PKInProcess.canUseDuoSplitView(), "Run on the iPhone Duo simulator.")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let appWindow = try XCTUnwrap(scene.keyWindow)
        let root = try XCTUnwrap(appWindow.rootViewController)
        let fullFrame = appWindow.frame
        let savedInsets = root.additionalSafeAreaInsets
        let native = PKInProcess.shared()
        defer {
            native.endDuoCompanionTask()
            root.additionalSafeAreaInsets = savedInsets
            appWindow.frame = fullFrame
        }

        func composerFrame() -> CGRect? {
            guard let field = Self.find(CapsuleTextView.self, in: root.view), field.bounds.width > 100 else { return nil }
            return field.convert(field.bounds, to: root.view)
        }

        let leadingInset: CGFloat = 84
        // Simulate the system resizing the app window while its scene stays visible.
        appWindow.frame.size.width = (fullFrame.width * 0.75).rounded(.down)
        root.additionalSafeAreaInsets.left = leadingInset
        settle {
            Self.find(LaunchCurtain.Stage.self, in: root.view) == nil &&
                (composerFrame()?.minX ?? leadingInset) < leadingInset
        }
        XCTAssertLessThan(try XCTUnwrap(composerFrame()).minX, leadingInset, "Split View must reclaim the leading inset")
        guard native.beginDuoCompanionTask() else { return XCTFail("The task must start in Split View") }

        appWindow.frame = fullFrame
        settle { (composerFrame()?.minX ?? 0) >= leadingInset }
        XCTAssertEqual(root.view.bounds.width, fullFrame.width, accuracy: 1)
        XCTAssertEqual(native.duoPlacement(), "fullscreen")
        XCTAssertTrue(native.hasDuoCompanionTask)
        let foldedHome = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: foldedHome)
        attachment.name = "Folded Duo home during a companion task"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(composerFrame()).minX, leadingInset,
                                   "The folded home must keep the composer inside the safe area during the task")
    }

    private func duoHomeComposerFrames(size: CGSize? = nil, inDuoSplitView: Bool = false) throws -> (CGRect, CGRect) {
        try XCTSkipUnless(PKInProcess.canUseDuoSplitView(), "Run on the iPhone Duo simulator.")
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        let root = UIHostingController(rootView: RootView().environment(app).environment(chat)
            .environment(\.inDuoSplitView, inDuoSplitView))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = size ?? scene.screen.bounds.size
        let pane = DuoPaneWindow(windowScene: scene)
        pane.frame = CGRect(origin: .zero, size: size)
        pane.rootViewController = root
        pane.makeKeyAndVisible()
        window = pane

        func composerFrame() throws -> CGRect {
            settle {
                Self.find(LaunchCurtain.Stage.self, in: root.view) == nil
                    && (Self.find(CapsuleTextView.self, in: root.view)?.bounds.width ?? 0) > 100
            }
            XCTAssertNil(Self.find(LaunchCurtain.Stage.self, in: root.view))
            let field = try XCTUnwrap(Self.find(CapsuleTextView.self, in: root.view))
            return field.convert(field.bounds, to: root.view)
        }

        let reference = try composerFrame()
        XCTAssertEqual(root.view.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(root.view.bounds.height, size.height, accuracy: 1)
        XCTAssertEqual(root.view.safeAreaInsets.left, 0, accuracy: 1)
        XCTAssertEqual(root.view.safeAreaInsets.right, 0, accuracy: 1)
        root.additionalSafeAreaInsets.left = 84
        settle { root.view.safeAreaInsets.left == 84 }
        XCTAssertEqual(root.view.safeAreaInsets.left, 84, accuracy: 1)
        root.view.layoutIfNeeded()
        let actual = try composerFrame()

        let screenshot = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Duo home with a leading safe area"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (reference, actual)
    }

    func testResizingTheRootKeepsAnUnsentDraftInTheSameConversation() throws {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        let session = chat.sessionID
        let container = UIViewController()
        let root = UIHostingController(rootView: RootView().environment(app).environment(chat))
        container.addChild(root)
        root.view.frame = CGRect(x: 0, y: 0, width: 476, height: 669)
        container.view.addSubview(root.view)
        root.didMove(toParent: container)
        let window = try show(Color.clear)
        window.rootViewController = container
        settle { Self.find(CapsuleTextView.self, in: window) != nil }
        let field = try XCTUnwrap(Self.find(CapsuleTextView.self, in: window))
        let draft = "Keep this draft through rotation"
        field.becomeFirstResponder()
        field.insertText(draft)
        settle { field.text == draft }
        XCTAssertEqual(field.text, draft)
        field.resignFirstResponder()

        for size in [CGSize(width: 669, height: 951), CGSize(width: 951, height: 669), CGSize(width: 476, height: 669)] {
            root.view.frame.size = size
            root.view.setNeedsLayout()
            root.view.layoutIfNeeded()
            pump(0.45)
            XCTAssertEqual(Self.find(CapsuleTextView.self, in: window)?.text, draft)
            XCTAssertEqual(chat.sessionID, session)
        }

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

    private struct SearchChatHost: View {
        @ObservedObject var feed: Feed
        var body: some View {
            ChatView(openDetails: { _ in }, openVoice: {}, openSetup: {},
                     openModel: {}, searchJump: feed.jump, openThreads: {})
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

private final class DuoPaneWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0) }
}
