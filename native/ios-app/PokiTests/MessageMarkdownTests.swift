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

    private static let priceTable = """
    | Phone | Storage | Price |
    | --- | --- | --- |
    | iPhone 17 | 128 GB | $799 |
    | iPhone 17 Pro | 256 GB | $1,099 |
    | iPhone Air | 512 GB | $999 |
    """
    private static let priceAnswer = "Prices on the Apple Store today:\n\n" + priceTable + "\n\nPrices include tax."
    private static let priceRows = [["Phone", "Storage", "Price"], ["iPhone 17", "128 GB", "$799"],
                                    ["iPhone 17 Pro", "256 GB", "$1,099"], ["iPhone Air", "512 GB", "$999"]]

    func testATableInAnAnswerShowsAsRowsAndColumns() async throws {
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            window?.overrideUserInterfaceStyle = style
            await show(Self.priceAnswer)
            let source = try await screen()
            try source.write(to: output.appendingPathComponent("price-table-\(name).xml"), atomically: true, encoding: .utf8)
            try await capture("price-table-\(name)")
            let labels = try Labels(source)
            XCTAssertFalse(labels.text.contains { $0.contains("|") || $0.contains("·") }, "Table markers reached the conversation: \(labels.text)")
            XCTAssertTrue(labels.rect("Prices on the Apple Store today:") != nil && labels.rect("Prices include tax.") != nil, "The words around the table must stay: \(labels.text)")
            let frames = try Self.priceRows.map { row in try row.map { cell in try XCTUnwrap(labels.rect(cell), "\(cell) is not its own cell: \(labels.text)") } }
            for row in frames {
                XCTAssertTrue(Self.lineUp(row.map(\.midY)), "A row's cells must sit on one line: \(row)")
                XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0.maxX < $1.minX }, "A row's cells must run left to right: \(row)")
            }
            XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0[0].maxY <= $1[0].minY }, "Rows must stack top to bottom")
            XCTAssertTrue(Self.lineUp(frames.map { $0[0].minX }), "The first column must line up on its left edge")
            XCTAssertTrue(Self.lineUp(frames.map { $0[2].maxX }), "The price column must line up on its right edge")
        }
    }

    /// Equal to within the point the accessibility frames are rounded to.
    private static func lineUp(_ values: [CGFloat]) -> Bool { (values.max() ?? 0) - (values.min() ?? 0) <= 1 }

    func testAStreamingTableNeverShowsMarkersOrDropsFinishedCells() async throws {
        let sample = Self.priceAnswer
        var header: CGRect?
        for length in 1...sample.count {
            let prefix = String(sample.prefix(length))
            await show(prefix)
            let labels = try Labels(try await screen())
            XCTAssertFalse(labels.text.contains { $0.contains("|") || $0.contains("·") || $0.contains("--") }, "Markers at prefix \(prefix.debugDescription): \(labels.text)")
            // Each row's cells stay on screen from the moment its line ends.
            for (i, row) in Self.priceRows.enumerated() {
                let line = Self.priceTable.components(separatedBy: "\n")[i == 0 ? 0 : i + 1]
                guard let end = sample.range(of: line).map({ sample.distance(from: sample.startIndex, to: $0.upperBound) }), length > end else { continue }
                for cell in row { XCTAssertNotNil(labels.rect(cell), "\(cell) left the screen at prefix \(prefix.debugDescription): \(labels.text)") }
            }
            if let shown = labels.rect("Phone") {
                if let header { XCTAssertEqual(shown.origin, header.origin, "The header moved at prefix \(prefix.debugDescription)") }
                header = shown
            }
            if UserDefaults.standard.bool(forKey: "markdownEvidence"), [80, 120, 150].contains(length) {
                try await capture("stream-table-\(length)")
            }
        }
        XCTAssertNotNil(header, "The table's header never appeared")
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
        let wide = """
        | Phone | Price | Storage | Screen | Battery | Weight | Colors |
        | :--- | ---: | ---: | :---: | --- | --- | --- |
        | iPhone 17 | $799 | 256 GB | 6.3 in | 30 hours video | 177 g | Black, White, Mist Blue, Sage, Lavender |
        | iPhone 17 Pro | $1,099 | 256 GB | 6.3 in | 33 hours video | 204 g | Silver, Cosmic Orange, Deep Blue |
        | iPhone Air | $999 | 256 GB | 6.5 in | 27 hours video | 165 g | Space Black, Cloud White, Light Gold, Sky Blue |
        """
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            window?.overrideUserInterfaceStyle = style
            await show("Here is how they compare:\n\n" + wide)
            try await capture("wide-table-\(name)")
            if let table = try XCTUnwrap(window).allSubviews.compactMap({ $0 as? UIScrollView }).first(where: { $0.contentSize.width > $0.bounds.width + 1 }) {
                table.setContentOffset(CGPoint(x: table.contentSize.width - table.bounds.width, y: 0), animated: false)
                try await capture("wide-table-scrolled-\(name)")
            }
        }
        window?.overrideUserInterfaceStyle = .light
        window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        await show(Self.priceAnswer)
        try await capture("price-table-largest-text")
        window?.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        let paragraph = "这是一段用于检查长回答显示和滚动的文字。每一项内容都应该清晰可读，阅读时可以随时返回上一段。"
        let long = String(repeating: paragraph, count: 43) + "\n\n- First item\n- Second item\n\n```swift\nlet answer = 42\nprint(answer)\n```"
        let tables = (0..<4).map { "\n\n" + String(repeating: paragraph, count: 4) + "\n\n" + ($0.isMultiple(of: 2) ? Self.priceTable : wide) }.joined()
        var rows: [[String: Double]] = []
        for run in 0..<12 {
            let withTables = run >= 6
            await show("Ready")
            let start = CACurrentMediaTime()
            await show(withTables ? long + tables : long)
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
            rows.append(["run": Double(run), "tables": withTables ? 4 : 0, "characters": Double((withTables ? long + tables : long).count), "render_ms": render,
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

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}

private final class Labels: NSObject, XMLParserDelegate {
    var text: [String] = []
    var frames: [String: String] = [:]

    override init() {}

    convenience init(_ source: String) throws {
        self.init()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "MessageMarkdownTests", code: 2) }
    }

    /// Where the label that reads exactly `label` is on screen.
    func rect(_ label: String) -> CGRect? {
        guard text.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == label }), let frame = frames[label] else { return nil }
        let n = frame.split(separator: ",").compactMap { Double($0) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard elementName == "XCUIElementTypeStaticText", let label = attributes["label"] else { return }
        text.append(label)
        frames[label.trimmingCharacters(in: .whitespacesAndNewlines)] = ["x", "y", "width", "height"].map { attributes[$0] ?? "" }.joined(separator: ",")
    }
}
