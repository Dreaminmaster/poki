import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class MessageMarkdownTests: XCTestCase {
    private var window: UIWindow?
    private var chat: ChatModel?
    private var session: SavedSession?
    private var savedSample: Any?
    private var coveredWindows: [UIWindow] = []
    private var output: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkdownEvidence", isDirectory: true)
    }

    override func setUpWithError() throws {
        savedSample = UserDefaults.standard.object(forKey: "pokiChat")
        UserDefaults.standard.set("empty", forKey: "pokiChat")
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app)
        self.chat = chat
        session = SavedSession(id: UUID().uuidString, kind: .poki, title: "Answer formatting",
                               started: Date(), updated: Date(), live: false,
                               entries: [ChatEntry(.you("Show the answer with formatting.", delivered: true)),
                                         ChatEntry(.poki("Ready"))], calls: [])
        chat.restore(try XCTUnwrap(session))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        coveredWindows = scene.windows.filter { !$0.accessibilityElementsHidden }
        coveredWindows.forEach { $0.accessibilityElementsHidden = true }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(openDetails: { _ in }, openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(app).environment(chat)
            .accessibilityElement(children: .contain).accessibilityIdentifier("markdown.conversation"))
        window.makeKeyAndVisible()
        self.window = window
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        coveredWindows.forEach { $0.accessibilityElementsHidden = false }
        coveredWindows = []
        chat = nil
        UserDefaults.standard.set(savedSample, forKey: "pokiChat")
    }

    func testHeadingsInTheConversationDoNotShowMarkdownMarkers() async throws {
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            window?.overrideUserInterfaceStyle = style
            await show("# Heading one\n## Heading two\n### Dune: Part Two Reissue\nBody text stays the same size.")
            let source = try await screen()
            try source.write(to: output.appendingPathComponent("headings-\(name).xml"), atomically: true, encoding: .utf8)
            try await capture("headings-\(name)")
            XCTAssertTrue(source.contains("Dune: Part Two Reissue"), "The answer must actually be on screen")
            XCTAssertFalse(source.contains("# Heading") || source.contains("### Dune"), "Heading markers reached the conversation: \(source)")
        }
        if UserDefaults.standard.bool(forKey: "markdownEvidence") {
            try await recordFormatsAndPerformance()
        }
    }

    func testStreamingPrefixesDoNotExposeMarkersOrRestyleCompletedWords() async throws {
        let samples: [(String, [String])] = [
            ("### Title", ["", "", "", "", "T", "Ti", "Tit", "Titl", "Title"]),
            ("**加粗**", ["", "", "加", "加粗", "加粗", "加粗"]),
            ("*word*", ["", "w", "wo", "wor", "word", "word"]),
            ("`code`", ["", "c", "co", "cod", "code", "code"]),
            ("[Link](https://example.com)", ["", "L", "Li", "Lin", "Link"] + Array(repeating: "Link", count: 22)),
            ("```\nx\n```", ["", "", "", "", "x", "x", "x", "x", "x"])
        ]
        var observations: [[String: String]] = []
        for (sample, expected) in samples {
            var previous: (String, String)?
            for length in 1...sample.count {
                let prefix = String(sample.prefix(length))
                await show(prefix)
                let source = try await screen()
                let labels = Labels()
                let parser = XMLParser(data: Data(source.utf8))
                parser.delegate = labels
                XCTAssertTrue(parser.parse())
                let answer = labels.text.filter { $0 != "Show the answer with formatting." }
                    .filter { !$0.isEmpty && $0 != "Poki" && $0 != "Not set up" }
                let wanted = expected[length - 1]
                observations.append(["input": prefix, "expected": wanted, "labels": answer.joined(separator: " | ")])
                XCTAssertFalse(answer.contains { $0.contains("#") || $0.contains("*") || $0.contains("`") || $0.contains("[") || $0.contains("](http") }, "Raw markers at prefix \(prefix.debugDescription): \(answer)")
                if !wanted.isEmpty {
                    XCTAssertTrue(answer.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }, "Missing visible content at \(prefix.debugDescription): \(answer)")
                    if let previous, previous.0 == wanted {
                        XCTAssertEqual(labels.frames[wanted], previous.1, "Closing a marker moved the already visible words")
                    }
                    previous = (wanted, labels.frames[wanted] ?? "")
                }
                if UserDefaults.standard.bool(forKey: "markdownEvidence") {
                    try await capture("stream-\(samples.firstIndex(where: { $0.0 == sample })!)-\(length)")
                }
            }
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("stream.json"))
    }

    private func show(_ text: String) async {
        guard var session else { return }
        session.entries[1].kind = .poki(text)
        chat?.restore(session)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.window?.layoutIfNeeded()
                CATransaction.flush()
                continuation.resume()
            }
        }
    }

    private func screen() async throws -> String {
        let deadline = CACurrentMediaTime() + 5
        repeat {
            let source = await Task.detached {
                var code: NSString?
                return PKInProcess.shared().sourceXML(nil, code: &code)
            }.value
            if let source, source.contains("markdown.conversation") { return source }
        } while CACurrentMediaTime() < deadline
        throw NSError(domain: "MessageMarkdownTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The test conversation did not become accessible"])
    }

    private func capture(_ name: String) async throws {
        let data = await Task.detached {
            var code: NSString?
            return PKInProcess.shared().screenshot(&code)
        }.value
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(data)))
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
    }

    private func recordFormatsAndPerformance() async throws {
        let formats: [(String, String)] = [
            ("lists", "- First item\n- Second item\n  - Nested item\n\n1. First step\n2. Second step"),
            ("inline", "**Bold** and *italic*, `inline code`.\n\n[Read more](https://example.com)"),
            ("blocks", "> A quoted sentence.\n\n---\n\n```swift\nlet answer = 42\nprint(answer)\n```"),
            ("table", "| Name | Value |\n| --- | --- |\n| Answer | 42 |")
        ]
        for (name, text) in formats {
            await show(text)
            try await screen().write(to: output.appendingPathComponent("\(name).xml"), atomically: true, encoding: .utf8)
            try await capture(name)
        }
        let paragraph = "这是一段用于检查长回答显示和滚动的文字。每一项内容都应该清晰可读，阅读时可以随时返回上一段。"
        let long = String(repeating: paragraph, count: 43) + "\n\n- First item\n- Second item\n\n```swift\nlet answer = 42\nprint(answer)\n```"
        var rows: [[String: Double]] = []
        for run in 0..<6 {
            await show("Ready")
            let start = CACurrentMediaTime()
            await show(long)
            let render = (CACurrentMediaTime() - start) * 1000
            let scroll = try XCTUnwrap(findScroll(in: try XCTUnwrap(window)))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            let scrolling = CACurrentMediaTime()
            for step in 0..<120 {
                let end = max(0, scroll.contentSize.height - scroll.bounds.height)
                scroll.setContentOffset(CGPoint(x: 0, y: end * CGFloat(step % 60) / 59), animated: false)
                scroll.layoutIfNeeded()
                CATransaction.flush()
            }
            rows.append(["run": Double(run), "characters": Double(long.count), "render_ms": render,
                         "scroll_120_steps_ms": (CACurrentMediaTime() - scrolling) * 1000,
                         "content_height": scroll.contentSize.height, "end_offset": scroll.contentOffset.y])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("performance.json"))
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !(scroll is UITextView), !(scroll is MarqueeScrollView) { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}

private final class Labels: NSObject, XMLParserDelegate {
    var text: [String] = []
    var frames: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard elementName == "XCUIElementTypeStaticText", let label = attributes["label"] else { return }
        text.append(label)
        frames[label.trimmingCharacters(in: .whitespacesAndNewlines)] = ["x", "y", "width", "height"].map { attributes[$0] ?? "" }.joined(separator: ",")
    }
}
