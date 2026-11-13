import SwiftUI
import UserNotifications
import XCTest
@testable import Poki

/// An approval measured whole on every surface that shows it, as the system lays the surface out: the
/// Lock Screen card, the expanded and the compact island, the card in the app and the notification.
/// Every Dynamic Type size, one to five kinds (the longest labels in the language), a batch of one
/// step, of several, and the same Delete pressed four times, with and without a screenshot, the rules'
/// sentence and the longest sentence an agent can write.
///
/// The one rule: a surface that shows Allow shows each kind the rules saw whole and inside what the
/// system shows, with both answers inside it too, and is no larger than the system allows. A Lock
/// Screen card or an expanded island that cannot promise that shows no Allow, and a button into Poki
/// instead. The card in the app always answers: its buttons stay on screen, every kind and every step
/// is on it. The notification names every kind in its body.
///
/// The language is the process's: run it once per language, `TEST_LANGUAGE=zh-Hans
/// TEST_ONLY=ApprovalFitTests scripts/app-tests.sh UDID`. Each cell that fails prints a line starting
/// with `FIT`, with the points it misses by.
@MainActor
final class ApprovalFitTests: XCTestCase {
    /// The system's sizes, in points. The Lock Screen card and the expanded island: Apple's Live
    /// Activity sizes for a 393-point iPhone, the narrowest with the Dynamic Island. The island's clip
    /// is its outline drawn in by 12.33 with a corner of about 36, measured on a real Live Activity on
    /// the iOS 27 simulator. The card in the app: a 393 by 852 iPhone's width less the chat's margins,
    /// and the room over the message field that leaves the top bar and the last message in sight.
    private enum System {
        static let width: CGFloat = 371
        /// The Lock Screen card on a 375-point iPhone without the island, as the reviews measured it.
        static let narrowWidth: CGFloat = 353
        static let maxHeight: CGFloat = 160
        static let lockCorner: CGFloat = 24
        static let cameraRow: CGFloat = 36.67
        static let islandClip: CGFloat = 12.33
        static let islandClipCorner: CGFloat = 36
        static let compactHeight: CGFloat = 36.67
        static let cardWidth: CGFloat = 361
        static let cardRoom: CGFloat = 480
        static let cardCorner: CGFloat = 30
    }

    private enum Surface: String, CaseIterable { case lock, narrowLock = "lock 353", island, compact, card }
    private enum Sentence: String { case rules, agent }

    /// What the rules saw, as PokiCore hands it over: one step per kind, or one kind pressed again and again.
    private struct Batch {
        var kinds: [String]
        var steps: [String]
        var name: String
    }

    private struct Cell: CustomStringConvertible {
        var size: DynamicTypeSize
        var batch: Batch
        var shot: Bool
        var sentence: Sentence
        var surface: Surface
        var description: String {
            "\(Locale.preferredLanguages.first ?? "?")\t\(size)\t\(batch.name)\t\(shot ? "shot" : "no shot")\t\(sentence)\t\(surface.rawValue)"
        }
    }

    private struct Seen {
        var label: String
        var frame: CGRect
        var traits: UIAccessibilityTraits
    }

    /// The area the system shows: a rounded rectangle, and for the expanded island nothing above the
    /// row beside the camera.
    private struct Area {
        var rect: CGRect
        var corner: CGFloat
        var top: CGFloat = 0
    }

    /// Each kind in ApprovalKind's order (most serious first): its label in the Live Activity's table,
    /// the button the fixture batch presses for it, and PokiCore's reason for that press.
    private static let kindTable: [(kind: String, label: String.LocalizationValue, step: String, reason: String)] = [
        ("payment", "Payment", "Check out", #"a payment ("check out")"#),
        ("deleting", "Deletion", "Clear", #"deleting ("clear")"#),
        ("sending", "Sending", "Send", #"sending a message ("send")"#),
        ("call", "Call", "Call", #"a call ("call")"#),
        ("password", "Password", "Sign in", "typing into a password field"),
        ("input", "Protected app", "Transfer", "input in Bank"),
        ("unread", "Unchecked step", "", "a tap at a point on a screen that may have changed since it was read"),
    ]
    private static func word(_ kind: String) -> String { String(activity: kindTable.first { $0.kind == kind }!.label) }
    private static let unreadPoint = "200, 640"

    /// The step's label as PokiCore writes it, and as the app says it in this language.
    private static func step(_ kind: String) -> (core: String, said: String) {
        let name = kindTable.first { $0.kind == kind }!.step
        if name.isEmpty { return ("Tap at \(unreadPoint)", String(activity: "Tap at \(unreadPoint)")) }
        return ("Tap “\(name)”", String(activity: "Tap “\(name)”"))
    }

    private static var batches: [Batch] {
        let longest = kindTable.map(\.kind).sorted { word($0).count > word($1).count }
        var batches = (1...5).map { count -> Batch in
            let kinds = kindTable.map(\.kind).filter(longest.prefix(count).contains)
            return Batch(kinds: kinds, steps: kinds, name: "\(count) [\(kinds.map(word).joined(separator: ", "))]")
        }
        batches.append(Batch(kinds: ["deleting"], steps: Array(repeating: "deleting", count: 4), name: "Delete pressed 4 times"))
        return batches
    }

    private static var chinese: Bool { (Locale.preferredLanguages.first ?? "").hasPrefix("zh") }
    /// The longest sentence PokiCore passes on from an agent: 119 characters and an ellipsis.
    private static var agentAsk: String {
        let words = chinese
            ? String(repeating: "从午餐应用的购物车里清空旧的订单然后为全家下单一份大号套餐并付款", count: 6)
            : String(repeating: "Clear the old order from the Lunch cart, then order the large family meal and pay for it. ", count: 3)
        return String(words.prefix(119)) + "…"
    }

    private static func approval(_ batch: Batch, sentence: Sentence) -> PendingApproval {
        let reasons = batch.steps.map { kind in kindTable.first { $0.kind == kind }!.reason }
        let reason = reasons.count == 1 ? reasons[0]
            : "multiple sensitive actions: " + reasons.enumerated().map { "action \($0.offset + 1): \($0.element)" }.joined(separator: "; ")
        let summary = batch.steps.enumerated().map { index, kind in
            let label = step(kind).core
            return index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        }.joined(separator: ", then ")
        return PendingApproval(id: "a", app: "Lunch", summary: summary, reason: reason, expires: .now.addingTimeInterval(100),
                               ask: sentence == .agent ? agentAsk : "Delete in Lunch", byAgent: sentence == .agent, kinds: batch.kinds)
    }

    private static let allowWords: Set<String> = [String(activity: "Allow"), String(localized: "Allow")]
    private static let dontAllowWords: Set<String> = [String(activity: "Don’t Allow"), String(localized: "Don’t Allow")]

    override class func setUp() {
        super.setUp()
        // SwiftUI builds its accessibility elements only while the app's accessibility is on, as under
        // VoiceOver or the Accessibility Inspector.
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let enable = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else { return }
        unsafeBitCast(enable, to: (@convention(c) (Bool) -> Void).self)(true)
    }

    override func tearDown() {
        Thumbnail.previewImage = nil
        super.tearDown()
    }

    func testAllowShowsOnlyWithEveryKindWholeOnScreen() {
        if !Self.chinese { XCTAssertNotNil(UIFont(name: "Geist-SemiBold", size: 11), "Geist is not loaded: the English widths would be another typeface's") }
        var failures: [String] = []
        var withoutAllow: [String: Int] = [:]
        var cells = 0
        for size in DynamicTypeSize.allCases {
            for batch in Self.batches {
                for sentence in [Sentence.rules, .agent] {
                    for surface in Surface.allCases {
                        // Only the Lock Screen card shows the screenshot.
                        for shot in surface == .lock || surface == .narrowLock ? [false, true] : [false] {
                            let cell = Cell(size: size, batch: batch, shot: shot, sentence: sentence, surface: surface)
                            cells += 1
                            let (problems, allows) = check(cell)
                            failures += problems.map { "FIT\t\(cell)\t\($0)" }
                            if !allows, surface != .compact {
                                withoutAllow[surface.rawValue, default: 0] += 1
                                print("NOALLOW\t\(cell)")
                            }
                        }
                    }
                }
            }
        }
        // What the design draws, and the usual batches at the default size, keep Allow: a surface that
        // gave it up everywhere would pass the rule above.
        let drawn = Batch(kinds: ["deleting"], steps: ["deleting"], name: "the design's one deletion")
        for batch in [drawn] + Self.batches.prefix(2) {
            for sentence in [Sentence.rules, .agent] {
                for surface in [Surface.lock, .narrowLock, .island, .card] {
                    let cell = Cell(size: .large, batch: batch, shot: false, sentence: sentence, surface: surface)
                    if !measure(cell).seen.contains(where: isAllow) { failures.append("FIT\t\(cell)\tno Allow at the default size") }
                }
            }
        }
        for batch in Self.batches {
            for sentence in [Sentence.rules, .agent] {
                let approval = Self.approval(batch, sentence: sentence)
                let body = ApprovalNotice.content(approval).body
                // The banner cuts a long body: the kinds come before the sentence.
                let lead = body.range(of: approval.sentence).map { String(body[..<$0.lowerBound]) } ?? body
                cells += 1
                for kind in batch.kinds where !lead.contains(Self.word(kind)) {
                    failures.append("FIT\t\(Locale.preferredLanguages.first ?? "?")\t-\t\(batch.name)\t-\t\(sentence)\tnotification\t\(Self.word(kind)) not before the sentence in the body")
                }
            }
        }
        print("FIT\t\(Locale.preferredLanguages.first ?? "?")\t\(cells) cells\t\(failures.count) failures\twithout Allow: \(withoutAllow.sorted { $0.key < $1.key })")
        failures.forEach { print($0) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) approval cells do not fit; see the FIT lines")
    }

    /// The cell's problems, and whether it shows Allow.
    private func check(_ cell: Cell) -> ([String], Bool) {
        let measured = measure(cell)
        let seen = measured.seen
        var problems: [String] = []
        let limit = cell.surface == .card ? System.cardRoom : cell.surface == .compact ? System.compactHeight : System.maxHeight
        if measured.natural > limit + 0.5 {
            problems.append(String(format: "%.2f tall, %.2f over the %.0f the system gives", measured.natural, measured.natural - limit, limit))
        }
        let area = area(cell.surface, size: measured.size)

        if cell.surface == .compact {
            if seen.contains(where: isAllow) { problems.append("Allow in the compact island") }
            for element in seen where outside(element.frame, area) > 0.5 {
                problems.append(String(format: "“%@” %.2f outside the compact island", element.label, outside(element.frame, area)))
            }
            return (problems, false)
        }

        guard let allow = seen.first(where: isAllow) else {
            if cell.surface == .card { problems.append("no Allow on the card in the app") }
            else if !seen.contains(where: { ($0.traits.contains(.button) || $0.traits.contains(.link)) && outside($0.frame, area, capsule: true) <= 0.5 }) {
                problems.append("no Allow and no button into Poki")
            }
            return (problems, false)
        }
        for (name, button) in [("Allow", Optional(allow)), ("Don’t Allow", seen.first { Self.dontAllowWords.contains($0.label) })] {
            guard let button else { problems.append("\(name) missing"); continue }
            let out = outside(button.frame, area, capsule: true)
            if out > 0.5 { problems.append(String(format: "\(name) %.2f outside the visible area", out)) }
        }
        let words = Set(cell.batch.kinds.map(Self.word))
        for kind in cell.batch.kinds {
            let word = Self.word(kind)
            if let label = seen.first(where: { $0.label == word }) {
                let out = outside(label.frame, area)
                if out > 0.5 { problems.append(String(format: "\(word) %.2f outside the visible area", out)) }
                // A tag on one line is as wide as its word at least; a cut one is narrower.
                let font = Self.tagFont(cell)
                let lines = (label.frame.height / font.lineHeight).rounded(.down)
                let needed = (word as NSString).size(withAttributes: [.font: font]).width
                if lines < 2, needed - label.frame.width > 0.5 {
                    problems.append(String(format: "\(word) cut: %.2f of %.2f wide", label.frame.width, needed))
                }
            } else if let group = seen.first(where: { element in
                let parts = element.label.components(separatedBy: CharacterSet(charactersIn: ",，、")).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.contains(word) && Set(parts).isSubset(of: words)
            }) {
                // The tags read as one element: the group's frame holds each of them.
                let out = outside(group.frame, area)
                if out > 0.5 { problems.append(String(format: "\(word) %.2f outside the visible area", out)) }
            } else {
                problems.append(seen.contains { $0.label.contains(word) } ? "\(word) only inside a longer line" : "\(word) not shown")
            }
        }
        if cell.surface == .card {
            let text = seen.map(\.label).joined(separator: "\n")
            for kind in Set(cell.batch.steps) {
                let said = Self.step(kind).said
                let shown = text.components(separatedBy: said).count - 1, pressed = cell.batch.steps.filter { $0 == kind }.count
                if shown < pressed { problems.append("step “\(said)” on the card \(shown) of \(pressed) times") }
            }
        }
        // Tags, the answers and the countdown never lie over one another.
        let timer = String(localized: "Time left")
        let solid = seen.filter { words.contains($0.label) || Self.allowWords.contains($0.label) || Self.dontAllowWords.contains($0.label)
            || $0.label == timer || $0.label.range(of: #"^\d+:\d\d$"#, options: .regularExpression) != nil }
        for (i, a) in solid.enumerated() {
            for b in solid[(i + 1)...] {
                let overlap = a.frame.intersection(b.frame)
                if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
                    problems.append(String(format: "“%@” and “%@” overlap by %.2f", a.label, b.label, min(overlap.width, overlap.height)))
                }
            }
        }
        return (problems, true)
    }

    /// The tag's typeface at the cell's text size, as the surface sets it: on the Live Activity Geist
    /// SemiBold 11 (the system font for Chinese) up to xxLarge, in the app the caption's up to accessibility1.
    private static func tagFont(_ cell: Cell) -> UIFont {
        if cell.surface == .card {
            let size = min(cell.size, .accessibility1)
            let base = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
            return UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        }
        let size = min(cell.size, ActivityMetrics.largestType)
        guard ActivityTheme.usesGeist, let geist = UIFont(name: "Geist-SemiBold", size: 11) else { return .systemFont(ofSize: 11, weight: .semibold) }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: geist, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
    }

    private func isAllow(_ element: Seen) -> Bool {
        element.traits.contains(.button) && Self.allowWords.contains(element.label)
    }

    /// The surface hosted as the system lays it out: at its width, up to the height the system gives,
    /// with the accessibility elements' frames in the surface's own coordinates.
    private func measure(_ cell: Cell, width: CGFloat? = nil) -> (seen: [Seen], size: CGSize, natural: CGFloat) {
        Thumbnail.previewImage = cell.shot ? UIGraphicsImageRenderer(size: CGSize(width: 39, height: 84)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 39, height: 84))
        } : nil
        let approval = Self.approval(cell.batch, sentence: cell.sentence)
        // A screenshot left in the shared container (by the debug screen's demo) would stand in every
        // card: a cell without one could not be measured.
        XCTAssertEqual(Thumbnail.picture != nil, cell.shot, "a screenshot file is in the shared container; remove it to measure")
        var state = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: cell.shot ? 1 : 0)
        state.approval = approval
        state.app = "Lunch"
        let face = state.face
        let root: AnyView
        var proposed = CGSize(width: width ?? System.width, height: System.maxHeight)
        switch cell.surface {
        case .lock, .narrowLock:
            root = AnyView(LockScreenCard(face: face).environment(\.cardDark, true))
            if cell.surface == .narrowLock { proposed.width = width ?? System.narrowWidth }
        case .island:
            root = AnyView(VStack(spacing: 0) {
                Color.clear.frame(height: System.cameraRow)
                IslandBottom(face: face)
            })
        case .compact:
            root = AnyView(CompactTrailing(face: face).fixedSize(horizontal: true, vertical: false))
            proposed = CGSize(width: width ?? 200, height: System.compactHeight)
        case .card:
            root = AnyView(ApprovalAskCard(approval: approval, words: nil, answer: { _ in }))
            proposed = CGSize(width: width ?? System.cardWidth, height: System.cardRoom)
        }
        let host = UIHostingController(rootView: AnyView(root.frame(width: cell.surface == .compact ? nil : proposed.width)
            .environment(\.dynamicTypeSize, cell.size)))
        host.safeAreaRegions = []
        let natural = host.sizeThatFits(in: CGSize(width: proposed.width, height: .infinity))
        let fitted = host.sizeThatFits(in: proposed)
        let size = CGSize(width: cell.surface == .compact ? min(natural.width, proposed.width) : proposed.width,
                          height: min(fitted.height, proposed.height))
        // On a simulator's first launch the app's scene connects a moment after the tests start.
        var scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        for _ in 0..<100 where scene == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        }
        guard let scene else { XCTFail("the app has no window scene"); return ([], .zero, 0) }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1) + 400)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        var seen: [Seen] = []
        // The elements take their frames once SwiftUI has committed the layout, and a scroll view's
        // a turn or two later: collected until the same elements come back twice, with frames.
        var previous: [String] = []
        for _ in 0..<20 {
            seen = []
            var visited = Set<ObjectIdentifier>()
            collect(host.view, into: &seen, in: host.view, visited: &visited)
            let labels = seen.map(\.label)
            if labels == previous, seen.contains(where: { !$0.frame.isEmpty }) { break }
            previous = labels
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        window.isHidden = true
        return (seen, size, natural.height)
    }

    private func collect(_ node: NSObject, into seen: inout [Seen], in view: UIView, visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        if node.isAccessibilityElement, let label = node.accessibilityLabel, !label.isEmpty {
            seen.append(Seen(label: label, frame: view.convert(node.accessibilityFrame, from: view.window!.screen.coordinateSpace), traits: node.accessibilityTraits))
        }
        let children = (node.accessibilityElements as? [NSObject])
            ?? (0..<Self.childCount(node)).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        for child in children { collect(child, into: &seen, in: view, visited: &visited) }
        if let parent = node as? UIView { for sub in parent.subviews { collect(sub, into: &seen, in: view, visited: &visited) } }
    }

    /// A container's element count; a view that is no container answers NSNotFound.
    private static func childCount(_ node: NSObject) -> Int {
        let count = node.accessibilityElementCount()
        return count == NSNotFound || count < 0 ? 0 : count
    }

    private func area(_ surface: Surface, size: CGSize) -> Area {
        let rect = CGRect(origin: .zero, size: size)
        return switch surface {
        case .lock, .narrowLock: Area(rect: rect, corner: System.lockCorner)
        case .island: Area(rect: rect.insetBy(dx: System.islandClip, dy: System.islandClip), corner: System.islandClipCorner, top: System.cameraRow)
        case .compact: Area(rect: rect, corner: 0)
        case .card: Area(rect: rect, corner: System.cardCorner)
        }
    }

    /// How far, in points, a rectangle (or a capsule in it, as the buttons are drawn) reaches outside
    /// the area at its worst point.
    private func outside(_ frame: CGRect, _ area: Area, capsule: Bool = false) -> CGFloat {
        let radius = capsule ? min(frame.width, frame.height) / 2 : 0
        let inner = frame.insetBy(dx: radius, dy: radius)
        let points = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                      CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)]
        return points.map { point in
            // The signed distance from the rounded rectangle's edge, out positive.
            let r = area.rect, c = area.corner
            let qx = abs(point.x - r.midX) - (r.width / 2 - c), qy = abs(point.y - r.midY) - (r.height / 2 - c)
            let edge = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - c
            return max(edge + radius, area.top - (point.y - radius), 0)
        }.max() ?? 0
    }
}
