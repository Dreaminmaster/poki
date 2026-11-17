import Foundation

// Fixing a step on the way. A routine or a path stops at the first screen that differs, which is
// what keeps it from tapping the wrong thing, and also what made it give up at a notification prompt
// or a renamed button and hand the whole task back to the agent's model. A stopped step already says
// what it wants (its target, and why), so one decision is enough to go on:
//
//   the target is here, under another name or in another place    → use that element for the step
//   something is in the way                                       → close it, then try the step again
//   the target is further down or up                              → scroll, then try again
//   the screen is still loading                                   → wait
//   none of these, or not sure                                    → stop, as before
//
// The options are built here from the elements on screen, so the answer is always one of them. The
// decision is trusted only above the policy's confidence and margin, a tap it leads to is held by the
// same approval rules as any other, and a fix that worked is remembered in the routine so the next
// run needs no decision at all.

/// What a step wants, as the decider is told.
struct StepWant {
    /// The routine's name and description, or a path's goal.
    var goal: String
    var index: Int
    var total: Int
    /// "tap", "type" or "long_press".
    var action: String
    var target: RoutineTarget
    var intent: String?
    /// The steps before this one, and the one after, in words.
    var done: [String]
    var next: String?
    /// Why the step could not be done as recorded.
    var why: String
}

enum FixMove {
    /// The step's target, as it is now.
    case target(Element)
    /// What is in the way: tapping this closes it.
    case clear(Element)
    /// "up" or "down": where more of the screen is.
    case scroll(String)
    case wait
    /// Stop, and why (for the answer).
    case stop(String)
}

/// A fix made during a run.
struct Fix: Equatable {
    enum Kind: String { case renamed, cleared, scrolled, waited, chosen }
    var step: Int
    var kind: Kind
    /// For the answer and the log: "closed Button \"Not Now\"".
    var text: String
    /// Came from the routine's own memory of an earlier fix: no decision was asked for.
    var remembered: Bool
    var ms: Int?
    var confidence: Double?
    /// In place of "remembered", when the fix came from what a path allows.
    var via: String? = nil

    var line: String {
        var how = via ?? (remembered ? "remembered" : "decided")
        if let ms, !remembered { how += " in \(ms) ms" }
        if let confidence, !remembered { how += " at \(String(format: "%.2f", confidence))" }
        return "step \(step + 1): \(text) (\(how))"
    }
}

struct FixCandidate {
    var id: String
    var element: Element
    var line: String
}

extension Computer {
    /// What sits over an app's own content: closing it is what "something is in the way" means.
    static let overlays: Set<String> = ["Alert", "Sheet", "Popover", "Dialog", "Menu", "ActivityListView"]
    /// Types that take a tap.
    static let tappable: Set<String> = ["Button", "Cell", "Link", "Switch", "Toggle", "Tab", "MenuItem", "SegmentedControl", "Icon", "TextField", "SearchField", "TextView", "CheckBox", "RadioButton", "DisclosureTriangle", "PopUpButton", "MenuButton"]

    /// The overlay an element is in, when it is in one.
    static func overlay(of e: Element, in all: [Element]) -> Element? {
        all.last { overlays.contains($0.type) && $0.contains(e) }
    }

    /// The elements a fix may tap, the likeliest first in the choosing and in screen order in the
    /// asking: on screen, reachable, not a container, not a key, never a secure field.
    func fixCandidates(for want: StepWant, all: [Element], screen: ScreenSize, limit: Int) -> [FixCandidate] {
        let layout = Layout(all: all, screen: screen)
        let keyboards = all.filter { $0.type == "Keyboard" }
        let wanted = Set(RoutineStore.words(want.target.label ?? want.target.identifier ?? "") + RoutineStore.words(want.intent ?? ""))
        let area = screen.width * screen.height
        let scored: [(Element, Double)] = listable(all, screen).compactMap { e in
            guard !e.fromPicture, !e.isSecure, !Self.containers.contains(e.type), !["Key", "Keyboard", "StatusBar", "ScrollBar", "PageIndicator"].contains(e.type) else { return nil }
            guard !keyboards.contains(where: { $0.contains(e) }), e.frame.area < area * 0.6, layout.touchPoint(e) != nil else { return nil }
            var score = 0.0
            if e.type == want.target.type { score += 3 }
            if Self.tappable.contains(e.type) { score += 1.5 }
            if Self.overlay(of: e, in: all) != nil { score += 4 }
            let words = Set(RoutineStore.words(e.text))
            if !wanted.isEmpty, !words.isEmpty { score += 5 * Double(wanted.intersection(words).count) / Double(wanted.count) }
            if want.target.hasPlace, hypot(e.frame.centre.x - want.target.x, e.frame.centre.y - want.target.y) < 80 { score += 2 }
            // Long texts are content, seldom controls.
            if e.text.count > 80 { score -= 2 }
            return (e, score)
        }
        let kept = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.node < $1.0.node }.prefix(max(1, limit)).map(\.0)
        return kept.sorted { $0.frame.y != $1.frame.y ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x }.enumerated().map { i, e in
            var line = "\(e.type) \"\(e.text.prefix(70))\" at \(Int(e.frame.centre.x.rounded())),\(Int(e.frame.centre.y.rounded()))"
            if let over = Self.overlay(of: e, in: all) { line += " in \(over.type)\(over.text.isEmpty ? "" : " \"\(over.text.prefix(50))\"")" }
            return FixCandidate(id: "e\(i + 1)", element: e, line: line)
        }
    }

    /// The state a decision is made from: the goal, where the run is, what it wants, and the screen
    /// as text. No picture, and nothing a secure field holds.
    func fixState(_ want: StepWant, candidates: [FixCandidate], all: [Element], screen: ScreenSize) -> JSON {
        var wanted: [String: JSON] = ["action": .string(want.action), "element": .string(want.target.describe)]
        if let intent = want.intent, !intent.isEmpty { wanted["purpose"] = .string(intent) }
        if want.target.hasPlace { wanted["was_at"] = [.number(want.target.x.rounded()), .number(want.target.y.rounded())] }
        let offered = Set(candidates.map(\.element.node))
        // Headings and notices that are not options still say which screen this is.
        let context = listable(all, screen).filter { !offered.contains($0.node) && !$0.fromPicture && !$0.isSecure && ["NavigationBar", "StaticText", "Heading", "Alert", "Sheet"].contains($0.type) && $0.text.count <= 120 }
            .prefix(12).map { JSON.string("\($0.type) \"\($0.text)\"") }
        var state: [String: JSON] = [
            "task": .string(want.goal),
            "app": .string(lastForeground?.describe ?? "unknown"),
            "progress": .string("step \(want.index + 1) of \(want.total)"),
            "wanted": .object(wanted),
            "problem": .string(want.why),
            "screen": .array(candidates.map { .string("\($0.id) \($0.line)") }),
        ]
        if !want.done.isEmpty { state["done"] = .array(want.done.suffix(4).map(JSON.string)) }
        if let next = want.next { state["then"] = .string(next) }
        if !context.isEmpty { state["also_on_screen"] = .array(Array(context)) }
        return .object(state)
    }

    static let fixMoveQuestion = "A saved path through an iPhone app is being replayed and its next step cannot find the element it wants. From `screen`, decide how to go on. Choose stop whenever you are not sure."
    static let fixElementQuestion = "Which element of `screen` should be tapped now? When the wanted element is there under another name or in another place, that element. When something is in the way, the control that closes or declines it (Close, Not Now, Later, Skip, Cancel, Don't Allow, or OK on a plain notice), unless the task itself needs it accepted. Choose none when nothing fits, or when the tap could buy, send, delete, sign in, share or grant something the task did not ask for."

    func fixQuestions(_ candidates: [FixCandidate]) -> [DecisionQuestion] {
        [
            DecisionQuestion(id: "move", instructions: Self.fixMoveQuestion, kind: .choice([
                ("target", "The wanted element is on this screen under another name or in another place"),
                ("blocked", "A popup, alert, sheet, banner, tip or permission prompt is in the way and can be closed"),
                ("scroll_down", "This is the right screen and the wanted element is likely further down"),
                ("scroll_up", "This is the right screen and the wanted element is likely further up"),
                ("wait", "The screen is still loading or changing"),
                ("stop", "This is another screen, the way on is unclear, or going on would commit something the task did not ask for"),
            ])),
            DecisionQuestion(id: "element", instructions: Self.fixElementQuestion,
                             kind: .choice(candidates.map { ($0.id, $0.line) } + [("none", "No listed element should be tapped")])),
        ]
    }

    enum CheckResult {
        case holds(ms: Int, p: Double)
        case fails(ms: Int, p: Double)
        /// Not answered, or not clearly: the run goes on and says so.
        case open(String)
    }

    static let checkQuestion = "A step of a task on an iPhone was just done. `expected` says what should be true of the screen now. From `screen`, is it true?"

    /// Whether the screen a step led to shows what the step's check says, on a screen that has held
    /// still across two reads (or after 1.5 s). Never throws.
    func decideCheck(_ check: String, goal: String, step: String, decider: Decider, screen: ScreenSize, until: Double) async -> CheckResult {
        let policy = config.deciderPolicy
        let ends = min(until - 0.5, now() + 1.5)
        var last: String?
        var elements: [Element] = listable(lastAll, screen)
        while now() < ends {
            guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, ends - now())), format: config.treeFormat) else { break }
            lastAll = tree.elements
            lastForeground = tree.foreground
            elements = listable(tree.elements, screen)
            let signature = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            if signature == last { break }
            last = signature
            await sleep(seconds: 0.15)
        }
        let lines = elements.filter { !$0.fromPicture && !$0.isSecure && !$0.text.isEmpty && !["Key", "Keyboard", "StatusBar", "ScrollBar"].contains($0.type) }
            .prefix(policy.maxCandidates + 20).map { JSON.string("\($0.type) \"\($0.text.prefix(70))\"") }
        let state: JSON = ["task": .string(goal), "app": .string(lastForeground?.describe ?? "unknown"), "step_done": .string(step), "expected": .string(check), "screen": .array(Array(lines))]
        let began = now()
        do {
            let answers = try await decider.decide(state: state, questions: [DecisionQuestion(id: "holds", instructions: Self.checkQuestion, kind: .yesNo)],
                                                   timeout: max(0.3, min(policy.timeout, until - now() - 0.3)))
            guard let p = answers["holds"]?.confidence else { return .open("no answer") }
            let ms = Int(((now() - began) * 1000).rounded())
            if p >= policy.minConfidence { return .holds(ms: ms, p: p) }
            if 1 - p >= policy.minConfidence { return .fails(ms: ms, p: p) }
            return .open("\(decider.name) was not sure (\(String(format: "%.2f", p)))")
        } catch {
            return .open(error is DeadlineExceeded ? "no answer in time" : "\(error)")
        }
    }

    /// One decision on a step that cannot go on as recorded. Never throws: whatever goes wrong is a stop.
    func decideFix(_ want: StepWant, decider: Decider, all: [Element], screen: ScreenSize, until: Double) async -> (move: FixMove, ms: Int, confidence: Double) {
        let policy = config.deciderPolicy
        let candidates = fixCandidates(for: want, all: all, screen: screen, limit: policy.maxCandidates)
        let began = now()
        func took() -> Int { Int(((now() - began) * 1000).rounded()) }
        let answers: [String: DecisionAnswer]
        do {
            answers = try await decider.decide(state: fixState(want, candidates: candidates, all: all, screen: screen), questions: fixQuestions(candidates),
                                               timeout: max(0.3, min(policy.timeout, until - now() - 0.5)))
        } catch {
            return (.stop("\(decider.name) gave no decision (\(error is DeadlineExceeded ? "no answer in time" : "\(error)"))"), took(), 0)
        }
        guard let move = answers["move"], let choice = move.choice else { return (.stop("\(decider.name) gave no decision"), took(), 0) }
        let sure = move.confidence >= policy.minConfidence && move.margin >= policy.minMargin
        func unsure(_ a: DecisionAnswer, _ what: String) -> FixMove {
            .stop("\(decider.name) was not sure enough \(what) (\(String(format: "%.2f", a.confidence)), needs \(String(format: "%.2f", policy.minConfidence)))")
        }
        guard sure else { return (unsure(move, "how to go on"), took(), move.confidence) }
        switch choice {
        case "wait": return (.wait, took(), move.confidence)
        case "scroll_down": return (.scroll("up"), took(), move.confidence)
        case "scroll_up": return (.scroll("down"), took(), move.confidence)
        case "target", "blocked":
            guard let element = answers["element"], let id = element.choice, id != "none", let picked = candidates.first(where: { $0.id == id }) else {
                return (.stop("\(decider.name) found no element to \(choice == "target" ? "use" : "close what is in the way")"), took(), move.confidence)
            }
            guard element.confidence >= policy.minConfidence, element.margin >= policy.minMargin else { return (unsure(element, "which element"), took(), element.confidence) }
            let confidence = min(move.confidence, element.confidence)
            return (choice == "target" ? .target(picked.element) : .clear(picked.element), took(), confidence)
        default:
            return (.stop("\(decider.name) saw another screen"), took(), move.confidence)
        }
    }
}
