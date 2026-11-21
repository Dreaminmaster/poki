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

    func testOnlySelectedOpeningLineStaysVisibleAfterActualSearchScroll() throws {
        let oldSample = UserDefaults.standard.object(forKey: "pokiChat")
        UserDefaults.standard.removeObject(forKey: "pokiChat")
        defer { UserDefaults.standard.set(oldSample, forKey: "pokiChat") }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        let greeting = ChatEntry(.poki("Synthetic greeting match"))
        let unrelated = ChatEntry(.poki("Synthetic previous approval setting"))
        let user = ChatEntry(.you("Synthetic ordinary hit", delivered: true))
        let saved = SavedSession(id: UUID().uuidString, kind: .poki, title: "Synthetic saved chat",
                                 started: .now, updated: .now, live: false, outcome: .done,
                                 entries: [greeting, unrelated, user], calls: [])
        chat.restore(saved)
        let feed = SelectionFeed()
        let window = try show(NavigationStack {
            SelectedSearchChatHost(feed: feed)
        }.environment(app).environment(chat))
        // The screenshots demonstrate the visual state, while this read-only
        // observer records the rows supplied by the hosted SwiftUI transcript.
        // UIHostingView does not expose all virtual SwiftUI elements through
        // UIView.accessibilityElements in an in-process unit test.
        func visible(_ entry: ChatEntry) -> Bool { feed.renderedRows.contains(entry.id) }
        func select(_ entry: ChatEntry, query: String) {
            let snapshot = ConversationSearchIndex.snapshot(in: [saved])
            let hits = ConversationSearchIndex.resolve(ConversationSearchIndex.search(snapshot, query: query), in: [saved])
            XCTAssertEqual(hits.first?.entryID, entry.id)
            feed.navigation.open(ConversationSearchJump(sessionID: saved.id, entryID: entry.id), preview: false)
            settle { feed.navigation.pending == nil && visible(entry) }
            XCTAssertNil(feed.navigation.pending, "The transcript must acknowledge the one-shot scroll")
            captureNavigationEvidence(window, name: "Search hit - " + query)
            XCTAssertTrue(visible(entry), "Selected row vanished after scroll acknowledgement")
            XCTAssertFalse(visible(unrelated))
        }
        select(user, query: "ordinary hit")
        XCTAssertFalse(visible(greeting))
        select(greeting, query: "greeting match")
        XCTAssertTrue(visible(user))
        XCTAssertFalse(visible(unrelated))
    }

    private final class SelectionFeed: ObservableObject {
        @Published var navigation = ConversationSearchNavigation()
        var renderedRows: [UUID] = []
    }

    private struct SelectedSearchChatHost: View {
        @ObservedObject var feed: SelectionFeed
        @Environment(ChatModel.self) private var chat
        var body: some View {
            ChatView(openDetails: { _ in }, openVoice: {}, openSetup: {}, openModel: {},
                     searchJump: feed.navigation.pending,
                     revealedSearchEntryID: feed.navigation.revealedEntry(in: chat.sessionID),
                     onSearchJumpApplied: { feed.navigation.consume($0) }, openThreads: {},
                     onTranscriptRowsChanged: { feed.renderedRows = $0 })
        }
    }

    func testMemorySourceOpensOtherTranscriptOnWideLayoutWithoutReplacingComposer() throws {
        try assertMemorySourceNavigation(wide: true, running: false)
    }

    func testMemorySourceOpensOtherTranscriptDuringNarrowLiveTask() throws {
        try assertMemorySourceNavigation(wide: false, running: true)
    }

    /// Mount the actual RootView and Settings navigation, open a real Memory item from
    /// Recent Updates, and activate its Source button (not the routing predicate).
    /// All history and memory records are synthetic and stored in a disposable directory.
    private func assertMemorySourceNavigation(wide: Bool, running: Bool) throws {
        let keys = ["pokiScreen", "pokiChat", "pokiHome", "pokiDraft", "memory.recentSeen",
                    "chat.provider", "chat.customURL", "chat.customModel",
                    CustomProviders.storeKey, CustomProviders.selectedKey, "chat.model.custom", "models.enabled.custom"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = folder.appendingPathComponent("chats", isDirectory: true)
        let suite = "MemorySourceNavigation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer {
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        UserDefaults.standard.removeObject(forKey: "pokiChat")
        // Navigate through the app's actual launch route instead of relying on
        // in-process UIKit accessibility activation of virtual SwiftUI buttons.
        UserDefaults.standard.set("memoryRecent", forKey: "pokiScreen")
        UserDefaults.standard.removeObject(forKey: "pokiHome")
        let draft = "Synthetic unsent composer draft"
        UserDefaults.standard.set(draft, forKey: "pokiDraft")
        let marker = "Synthetic saved source transcript"
        func saved(_ id: String, _ text: String) -> SavedSession {
            SavedSession(id: id, kind: .poki, client: nil, title: text, started: .now, updated: .now,
                         live: false, outcome: .done, entries: [ChatEntry(.you(text, delivered: true))], calls: [])
        }
        let active = saved("active-" + UUID().uuidString, "Active synthetic chat")
        var source = saved("source-" + UUID().uuidString, marker)
        source.title = "Saved synthetic conversation"
        let targetID = "chat.entry.\(try XCTUnwrap(source.entries.first?.id))"
        for record in [active, source] {
            try JSONEncoder().encode(record).write(to: chats.appendingPathComponent(record.id + ".json"))
        }
        let store = SessionStore(folder: chats, defaults: defaults)
        let notes = RoutineStore(url: folder.appendingPathComponent("memory.json"))
        let note = try XCTUnwrap(notes.remember("Synthetic source memory", by: RoutineStore.owner,
                                               heard: NoteOrigin(session: source.id, app: nil)))
        let library = MemoryLibrary(store: notes)
        let change = try XCTUnwrap(library.changes.first { $0.item.id == note.id })
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        let server = try FakeCompletions(replies: [FakeCompletions.text("Held synthetic answer")], holdFirstReply: {})
        let provider = CustomProviders.upsert(CustomProvider(endpoints: [
            CustomEndpoint(url: "http://127.0.0.1:\(server.port)/v1", api: .chatCompletions)
        ], model: "fixture"))
        ModelKeys.selectedProvider = .custom
        ModelKeys.selectedModel = CustomProviders.choiceID(provider.id, provider.model)
        let chat = ChatModel(app: app, store: store)
        chat.restore(active)
        defer { chat.stop() }
        if running {
            chat.send("A synthetic task in progress")
            settle(for: 5) { !server.requests.isEmpty }
            XCTAssertTrue(chat.running, "The narrow path must really have a running chat")
            XCTAssertFalse(server.requests.isEmpty)
        }
        let originalEntries = chat.entries
        let size = wide ? CGSize(width: 951, height: 669) : CGSize(width: 476, height: 669)
        let container = UIViewController()
        let root = UIHostingController(rootView: RootView(sessionStore: store, memoryLibrary: library)
            .environment(app).environment(chat))
        container.addChild(root)
        root.view.frame = CGRect(origin: .zero, size: size)
        container.view.addSubview(root.view)
        root.didMove(toParent: container)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = DuoPaneWindow(windowScene: scene)
        self.window = window
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { container.dismiss(animated: false) }
        settle(for: 5) { Self.find(LaunchCurtain.Stage.self, in: root.view) == nil
            && Self.find(CapsuleTextView.self, in: root.view)?.plainText == draft }
        XCTAssertEqual(root.view.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(Self.find(CapsuleTextView.self, in: root.view)?.plainText, draft)
        // The real app has opened Settings → Memory → Recent Updates via
        // openLaunchScreen. Activate the actual memory row and Source link here.
        captureNavigationEvidence(window, name: wide ? "Wide Memory Recent Updates" : "Narrow live Memory Recent Updates")
        try activate("memory.openChange.\(change.id)", in: window)
        try activate("memory.source.conversation", in: window)
        settle(for: 5) { Self.accessible(in: window, matching: { $0 == targetID || $0 == marker }) != nil }
        captureNavigationEvidence(window, name: wide ? "Wide Memory source transcript" : "Narrow live Memory source transcript")
        XCTAssertNotNil(Self.accessible(in: window, matching: { $0 == targetID || $0 == marker }), "The actual source message, not merely its page title, must be visible")
        XCTAssertEqual(chat.sessionID, active.id)
        XCTAssertEqual(chat.entries, originalEntries)
        XCTAssertEqual(chat.running, running)
        // Dismissing Settings must return to the original composer, including its draft.
        container.dismiss(animated: false)
        window.makeKeyAndVisible()
        settle(for: 5) { Self.find(CapsuleTextView.self, in: root.view)?.plainText == draft }
        XCTAssertEqual(Self.find(CapsuleTextView.self, in: root.view)?.plainText, draft)
        XCTAssertEqual(chat.sessionID, active.id)
    }

    private func activate(_ id: String, in window: UIWindow, scroll: Bool = false) throws {
        // UIKit presents the Settings sheet/cover with its own hosting controller;
        // inspect its presented tree, not just subviews of the original chat.
        settle(for: 3) { Self.accessible(in: window, matching: { $0 == id }) != nil }
        if scroll && Self.accessible(in: window, matching: { $0 == id }) == nil {
            if let content = Self.frontController(window.rootViewController)?.view,
               let list = Self.transcriptScroll(in: content) {
                let end = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                for offset in stride(from: CGFloat(0), through: end + 1, by: max(100, list.bounds.height / 2)) {
                    list.setContentOffset(CGPoint(x: 0, y: min(offset, end)), animated: false)
                    pump(0.2)
                    if Self.accessible(in: window, matching: { $0 == id }) != nil { break }
                }
            }
        }
        if Self.accessible(in: window, matching: { $0 == id }) == nil {
            captureNavigationEvidence(window, name: "Missing " + id)
        }
        let item = try XCTUnwrap(Self.accessible(in: window, matching: { $0 == id }), "Missing actual control " + id)
        XCTAssertTrue(item.accessibilityActivate(), "Activate actual control " + id)
        pump(0.5)
    }

    private func captureNavigationEvidence(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func frontController(_ root: UIViewController?) -> UIViewController? {
        guard let root else { return nil }
        if let presented = root.presentedViewController, !presented.isBeingDismissed {
            return frontController(presented)
        }
        // UIKit may attach a SwiftUI sheet to a child UIHostingController,
        // not its parent container. Inspect child presentations as well.
        for child in root.children.reversed() {
            if let front = frontController(child) { return front }
        }
        return root
    }

    private static func accessible(in root: UIView, matching matches: (String) -> Bool) -> NSObject? {
        // Do not reduce the search to the deepest hosting controller. A SwiftUI
        // sheet/NavigationStack can install its list in a *sibling* host while
        // frontController() returns the composer behind it. Start from the full
        // window and visit every presented/child controller as well as UIKit's
        // virtual accessibility containers; the lookup still activates only the
        // real, on-screen control.
        var pending: [NSObject] = [root]
        if let window = root as? UIWindow, let rootController = window.rootViewController {
            var controllers: [UIViewController] = [rootController]
            var seenControllers = Set<ObjectIdentifier>()
            while let controller = controllers.popLast() {
                guard seenControllers.insert(ObjectIdentifier(controller)).inserted else { continue }
                pending.append(controller)
                pending.append(controller.view)
                controllers.append(contentsOf: controller.children)
                if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                    controllers.append(presented)
                }
            }
        }
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let id = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
            if id.map(matches) == true || item.accessibilityLabel.map(matches) == true {
                let frame = item.accessibilityFrame
                if !frame.isEmpty, (root.accessibilityFrame.isEmpty ? root.convert(root.bounds, to: nil) : root.accessibilityFrame).intersects(frame) { return item }
            }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return nil
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
