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

    private enum Surface: String, CaseIterable { case lock, island, compact, card }
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
        var failures: [String] = []
        var cells = 0
        for size in DynamicTypeSize.allCases {
            for batch in Self.batches {
                for sentence in [Sentence.rules, .agent] {
                    for surface in Surface.allCases {
                        // Only the Lock Screen card shows the screenshot.
                        for shot in surface == .lock ? [false, true] : [false] {
                            let cell = Cell(size: size, batch: batch, shot: shot, sentence: sentence, surface: surface)
                            cells += 1
                            failures += check(cell).map { "FIT\t\(cell)\t\($0)" }
                        }
                    }
                }
            }
        }
        // The approval the design draws: one kind, the default size, the rules' sentence.
        let drawn = Batch(kinds: ["deleting"], steps: ["deleting"], name: "the design's one deletion")
        for surface in [Surface.lock, .island, .card] {
            let cell = Cell(size: .large, batch: drawn, shot: false, sentence: .rules, surface: surface)
            if !measure(cell).seen.contains(where: isAllow) { failures.append("FIT\t\(cell)\tno Allow on the design's own approval") }
        }
        for batch in Self.batches {
            for sentence in [Sentence.rules, .agent] {
                let body = ApprovalNotice.content(Self.approval(batch, sentence: sentence)).body
                cells += 1
                for kind in batch.kinds where !body.contains(Self.word(kind)) {
                    failures.append("FIT\t\(Locale.preferredLanguages.first ?? "?")\t-\t\(batch.name)\t-\t\(sentence)\tnotification\t\(Self.word(kind)) not in the body")
                }
            }
        }
        print("FIT\t\(Locale.preferredLanguages.first ?? "?")\t\(cells) cells\t\(failures.count) failures")
        failures.forEach { print($0) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) approval cells do not fit; see the FIT lines")
    }

    private func check(_ cell: Cell) -> [String] {
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
            return problems
        }

        guard let allow = seen.first(where: isAllow) else {
            if cell.surface == .card { problems.append("no Allow on the card in the app") }
            else if !seen.contains(where: { ($0.traits.contains(.button) || $0.traits.contains(.link)) && outside($0.frame, area, capsule: true) <= 0.5 }) {
                problems.append("no Allow and no button into Poki")
            }
            return problems
        }
        for (name, button) in [("Allow", Optional(allow)), ("Don’t Allow", seen.first { Self.dontAllowWords.contains($0.label) })] {
            guard let button else { problems.append("\(name) missing"); continue }
            let out = outside(button.frame, area, capsule: true)
            if out > 0.5 { problems.append(String(format: "\(name) %.2f outside the visible area", out)) }
        }
        let words = Set(cell.batch.kinds.map(Self.word))
        var wide: [Seen]?
        for kind in cell.batch.kinds {
            let word = Self.word(kind)
            if let label = seen.first(where: { $0.label == word }) {
                let out = outside(label.frame, area)
                if out > 0.5 { problems.append(String(format: "\(word) %.2f outside the visible area", out)) }
                wide = wide ?? measure(cell, width: 1600).seen
                if let full = wide?.first(where: { $0.label == word }), full.frame.width - label.frame.width > 0.5 {
                    problems.append(String(format: "\(word) cut: %.2f of %.2f wide", label.frame.width, full.frame.width))
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
            for kind in Set(cell.batch.steps) where !text.contains(Self.step(kind).said) {
                problems.append("step “\(Self.step(kind).said)” not on the card")
            }
        }
        return problems
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
        var state = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: cell.shot ? 1 : 0)
        state.approval = approval
        state.app = "Lunch"
        let face = state.face
        let root: AnyView
        var proposed = CGSize(width: width ?? System.width, height: System.maxHeight)
        switch cell.surface {
        case .lock:
            root = AnyView(LockScreenCard(face: face).environment(\.cardDark, true))
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
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1) + 400)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        var seen: [Seen] = []
        // The elements take their frames once SwiftUI has committed the layout, a turn of the run loop later.
        for _ in 0..<10 {
            seen = []
            var visited = Set<ObjectIdentifier>()
            collect(host.view, into: &seen, in: host.view, visited: &visited)
            if seen.contains(where: { !$0.frame.isEmpty }) { break }
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
        case .lock: Area(rect: rect, corner: System.lockCorner)
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
