import XCTest
@testable import PokiCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A decider that answers from a script and keeps what it was asked.
final class ScriptedDecider: Decider, @unchecked Sendable {
    let name = "test-decider"
    typealias Script = @Sendable (_ state: JSON, _ questions: [DecisionQuestion]) throws -> [String: DecisionAnswer]
    let asked = LockedBox<[(state: JSON, questions: [DecisionQuestion])]>([])
    let script: LockedBox<Script>
    init(_ script: @escaping Script) { self.script = LockedBox(script) }

    func decide(state: JSON, questions: [DecisionQuestion], timeout: Double) async throws -> [String: DecisionAnswer] {
        asked.update { $0.append((state, questions)) }
        return try script.value(state, questions)
    }

    /// The option id of the element whose line holds `text`.
    static func option(_ text: String, in questions: [DecisionQuestion]) -> String? {
        guard case .choice(let options)? = questions.first(where: { $0.id == "element" })?.kind else { return nil }
        return options.first { $0.means.contains("\"\(text)") }?.id
    }

    /// Move `move` on the element that reads `text`, as sure as `confidence`.
    static func answer(_ move: String, _ text: String? = nil, confidence: Double = 0.93) -> Script {
        { _, questions in
            let id = text.flatMap { option($0, in: questions) } ?? "none"
            var moves = ["stop": 1 - confidence, "wait": 0], elements = ["none": 1 - confidence]
            moves[move] = confidence
            elements[id] = confidence
            return ["move": DecisionAnswer(choice: move, confidence: confidence, probabilities: moves),
                    "element": DecisionAnswer(choice: id, confidence: confidence, probabilities: elements)]
        }
    }
}

/// Routines and paths fixed on the way: a popup closed, a renamed target found, and every case
/// where the run must still stop as it always did.
final class DeciderTests: XCTestCase {
    /// Settings whose rows open the next page, with a prompt that can sit over any page: a tap goes to
    /// what is under the point, as on a phone.
    final class App: @unchecked Sendable {
        let wda: FakeWDA
        let page = LockedBox(0)
        let prompt = LockedBox<[Node]?>(nil)
        var pages: [[Node]]
        /// The label that opens the next page, per page.
        var opens: [String]
        let tapped = LockedBox<[String]>([])
        init(_ wda: FakeWDA, pages: [[Node]], opens: [String]) {
            self.wda = wda
            self.pages = pages
            self.opens = opens
            show()
            wda.set("POST /wda/tap") { [self] body in
                let x = body?["x"]?.double ?? -1, y = body?["y"]?.double ?? -1
                func hit(_ nodes: [Node]) -> Node? {
                    for n in nodes.reversed() {
                        if let inner = hit(n.children) { return inner }
                        if n.frame[0] <= x, x <= n.frame[0] + n.frame[2], n.frame[1] <= y, y <= n.frame[1] + n.frame[3], !["Alert", "Sheet"].contains(n.type) { return n }
                    }
                    return nil
                }
                if let over = self.prompt.value {
                    // The prompt takes every tap: one on its buttons closes it.
                    if let button = hit(over), button.type == "Button" { self.tapped.update { $0.append(button.label ?? "") }; self.prompt.value = nil }
                } else if let node = hit(self.pages[self.page.value]) {
                    self.tapped.update { $0.append(node.label ?? "") }
                    if self.page.value < self.opens.count, node.label == self.opens[self.page.value] { self.page.value += 1 }
                }
                self.show()
                return (200, ["value": .null])
            }
        }
        func show() { wda.tree(pages[page.value] + (prompt.value ?? []), app: "Settings") }
        func go(_ i: Int) { page.value = i; show() }
    }

    static let notifications = [Node("Alert", "Turn On Notifications?", [45, 300, 300, 180], [
        Node("StaticText", "Get alerts about updates", [60, 340, 270, 40]),
        Node("Button", "Not Now", [60, 420, 130, 44]),
        Node("Button", "Allow", [200, 420, 130, 44]),
    ])]

    func core(_ store: RoutineStore, decider: Decider?, configure: @escaping (inout CoreConfig) -> Void = { _ in }) -> (PokiCore, FakeWDA, App) {
        let wda = FakeWDA()
        let app = App(wda, pages: [RoutineTests.home, RoutineTests.general, RoutineTests.about], opens: ["General", "About"])
        let (core, _, _) = makeCore(wda) {
            $0.memory = store
            $0.decider = { decider }
            $0.deciderPolicy.askAfterStill = 0.2
            configure(&$0)
        }
        return (core, wda, app)
    }

    func number(of label: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains("\"\(label)") {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }

    func record(_ core: PokiCore, _ app: App) async {
        app.go(0)
        let first = await core.call("look", [:])
        let second = await core.call("do", ["actions": [["tap": .number(Double(number(of: "General", in: first.text)!)), "intent": "open General"]]])
        _ = await core.call("do", ["actions": [["tap": .number(Double(number(of: "About", in: second.text)!)), "intent": "open the About page"]]])
        let saved = await core.call("routines", ["action": "save", "name": "iOS version", "description": "read the iOS version in Settings", "read": ["iOS Version"]])
        XCTAssertFalse(saved.isError, saved.text)
        _ = await core.call("do", ["actions": [], "finish": true])
        app.go(0)
    }

    func run(_ core: PokiCore) async -> ToolResult {
        _ = await core.call("look", [:])
        return await core.call("do", ["actions": [["run": "iOS version"]]])
    }

    // MARK: A prompt in the way

    func testAPromptInTheWayIsClosedAndTheRunGoesOn() async throws {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Not Now"))
        let (core, _, app) = core(store, decider: decider)
        await record(core, app)
        app.go(1)
        app.go(0)
        // The prompt comes up over General's page, in front of step 2.
        app.opens = ["General", "About"]
        let wda = app.wda
        wda.set("POST /wda/tap") { [app] body in
            let x = body?["x"]?.double ?? -1, y = body?["y"]?.double ?? -1
            if app.prompt.value != nil {
                if (60...190).contains(x), (420...464).contains(y) { app.tapped.update { $0.append("Not Now") }; app.prompt.value = nil }
            } else if (100...144).contains(y) {
                app.tapped.update { $0.append(app.page.value == 0 ? "General" : "About") }
                app.page.value += 1
                if app.page.value == 1 { app.prompt.value = Self.notifications }
            }
            app.show()
            return (200, ["value": .null])
        }
        app.tapped.value = []

        let result = await run(core)

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(app.tapped.value, ["General", "Not Now", "About"])
        XCTAssertTrue(result.text.contains("run \"iOS version\": 2 steps"), result.text)
        XCTAssertTrue(result.text.contains("fixed on the way: step 2: closed Button \"Not Now\" (decided in"), result.text)
        XCTAssertTrue(result.text.contains("read: iOS Version = 27.3"), result.text)
        XCTAssertEqual(decider.asked.value.count, 1)
        let routine = try XCTUnwrap(store.routine(named: "iOS version"))
        XCTAssertEqual(routine.fixes, 1)
        XCTAssertEqual(routine.failuresInARow, 0)
        XCTAssertEqual(routine.steps[1].clears?.map(\.label), ["Not Now"])
    }

    func testAFixThatWorkedIsRememberedSoTheNextRunAsksNothing() async throws {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Not Now"))
        let (core, _, app) = core(store, decider: decider)
        await record(core, app)
        // The prompt is over the first page this time, in front of step 1.
        app.prompt.value = Self.notifications
        app.show()
        let first = await run(core)
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(decider.asked.value.count, 1)
        XCTAssertEqual(store.routine(named: "iOS version")?.steps[0].clears?.map(\.label), ["Not Now"])

        // Again, with nothing to ask: the decider now refuses everything.
        decider.script.value = { _, _ in throw DeciderError("must not be asked") }
        _ = await core.call("do", ["actions": [], "finish": true])
        app.go(0)
        app.prompt.value = Self.notifications
        app.show()
        app.tapped.value = []

        let second = await run(core)

        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(app.tapped.value, ["Not Now", "General", "About"])
        XCTAssertTrue(second.text.contains("closed Button \"Not Now\" (remembered)"), second.text)
        XCTAssertEqual(decider.asked.value.count, 1, "the remembered fix asks nothing")
    }

    func testTheStateHoldsTheGoalTheStepAndTheScreenAsText() async throws {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Not Now"))
        let (core, _, app) = core(store, decider: decider)
        await record(core, app)
        app.prompt.value = Self.notifications + [Node("SecureTextField", "Password", [16, 700, 358, 44], value: "hunter2")]
        app.show()

        _ = await run(core)

        let asked = try XCTUnwrap(decider.asked.value.first)
        XCTAssertEqual(asked.state["task"]?.string, "iOS version: read the iOS version in Settings")
        XCTAssertEqual(asked.state["progress"]?.string, "step 1 of 2")
        XCTAssertEqual(asked.state["wanted"]?["element"]?.string, "Button \"General\"")
        XCTAssertEqual(asked.state["wanted"]?["purpose"]?.string, "open General")
        XCTAssertEqual(asked.state["then"]?.string, "tap Button \"About\" (open the About page)")
        let screen = asked.state["screen"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(screen.contains { $0.contains("Button \"Not Now\"") && $0.contains("in Alert \"Turn On Notifications?\"") }, "\(screen)")
        let whole = asked.state.serialized()
        XCTAssertFalse(whole.contains("hunter2"), "what a secure field holds never leaves the phone")
        XCTAssertFalse(screen.contains { $0.contains("SecureTextField") })
        XCTAssertEqual(asked.questions.map(\.id), ["move", "element"])
    }

    // MARK: A renamed target

    func testARenamedTargetIsUsedAndKeptOnceTheRunWorked() async throws {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("target", "General Settings"))
        let (core, _, app) = core(store, decider: decider)
        await record(core, app)
        app.pages[0] = [Node("Button", "General Settings", [16, 100, 358, 44]), Node("Button", "Privacy", [16, 144, 358, 44])]
        app.opens = ["General Settings", "About"]
        app.go(0)

        let first = await run(core)

        XCTAssertFalse(first.isError, first.text)
        XCTAssertTrue(first.text.contains("used Button \"General Settings\" for Button \"General\""), first.text)
        let routine = try XCTUnwrap(store.routine(named: "iOS version"))
        XCTAssertEqual(routine.steps[0].target?.label, "General", "the recorded target stays")
        XCTAssertEqual(routine.steps[0].also?.map(\.label), ["General Settings"])

        decider.script.value = { _, _ in throw DeciderError("must not be asked") }
        _ = await core.call("do", ["actions": [], "finish": true])
        app.go(0)
        let second = await run(core)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertFalse(second.text.contains("fixed on the way"), second.text)
        XCTAssertEqual(decider.asked.value.count, 1)
    }

    // MARK: When it must still stop

    func testADecisionThatIsNotSureEnoughStopsTheRunAndTapsNothing() async {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Not Now", confidence: 0.45))
        let (core, _, app) = core(store, decider: decider) { $0.actionCap = 1.2 }
        await record(core, app)
        app.prompt.value = Self.notifications
        app.show()
        app.tapped.value = []

        let result = await run(core)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("stopped at step 1 of 2"), result.text)
        XCTAssertTrue(result.text.contains("test-decider was not sure enough how to go on (0.45, needs 0.60)"), result.text)
        XCTAssertEqual(app.tapped.value, [])
        XCTAssertEqual(decider.asked.value.count, 1, "asked once, not again and again")
        XCTAssertEqual(store.routine(named: "iOS version")?.failuresInARow, 1)
        XCTAssertNil(store.routine(named: "iOS version")?.steps[0].clears)
    }

    func testAPickThatBarelyLeadsIsNotADecision() async {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider { _, questions in
            let id = ScriptedDecider.option("Not Now", in: questions)!, other = ScriptedDecider.option("Allow", in: questions)!
            return ["move": DecisionAnswer(choice: "blocked", confidence: 0.9, probabilities: ["blocked": 0.9, "stop": 0.1]),
                    "element": DecisionAnswer(choice: id, confidence: 0.62, probabilities: [id: 0.52, other: 0.46])]
        }
        let (core, _, app) = core(store, decider: decider) { $0.actionCap = 1.2 }
        await record(core, app)
        app.prompt.value = Self.notifications
        app.show()
        app.tapped.value = []

        let result = await run(core)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("was not sure enough which element"), result.text)
        XCTAssertEqual(app.tapped.value, [])
    }

    func testClosingSomethingThatNeedsTheOwnersApprovalIsNotDone() async {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Delete Account"))
        let (core, _, app) = core(store, decider: decider) { $0.actionCap = 1.2 }
        await record(core, app)
        app.prompt.value = [Node("Alert", "Remove everything?", [45, 300, 300, 180], [Node("Button", "Delete Account", [60, 420, 270, 44])])]
        app.show()
        app.tapped.value = []

        let result = await run(core)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("closing it needs the owner's approval"), result.text)
        XCTAssertEqual(app.tapped.value, [])
    }

    func testADeciderThatFailsLeavesTheRunAsItWasWithoutOne() async {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider { _, _ in throw DeciderError("the provider answered 500") }
        let (core, _, app) = core(store, decider: decider) { $0.actionCap = 1.2 }
        await record(core, app)
        app.pages[0] = [Node("Button", "Privacy", [16, 100, 358, 44])]
        app.go(0)
        app.tapped.value = []

        let result = await run(core)

        XCTAssertTrue(result.text.contains("stopped at step 1 of 2: Button \"General\" is not on screen"), result.text)
        XCTAssertTrue(result.text.contains("test-decider gave no decision (the provider answered 500)"), result.text)
        XCTAssertEqual(app.tapped.value, [])
    }

    /// Asked early, the decider says this is another screen; the page was only slow. The step still
    /// has its time, as it had without a decider.
    func testAPageThatWasOnlySlowStillGetsTheStepsWholeTime() async {
        let store = RoutineStore(url: nil)
        let decider = ScriptedDecider(ScriptedDecider.answer("stop"))
        let (core, _, app) = core(store, decider: decider) { $0.actionCap = 3 }
        await record(core, app)
        let real = app.pages[0]
        app.pages[0] = [Node("StaticText", "Loading", [16, 100, 358, 44])]
        app.go(0)
        Task { await sleep(seconds: 1.0); app.pages[0] = real; app.show() }

        let result = await run(core)

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("run \"iOS version\": 2 steps"), result.text)
        XCTAssertEqual(decider.asked.value.count, 1)
    }

    func testNoMoreFixesThanThePolicyAllowsForOneStep() async {
        let store = RoutineStore(url: nil)
        // It keeps saying the same prompt is in the way; closing it brings it straight back.
        let decider = ScriptedDecider(ScriptedDecider.answer("blocked", "Not Now"))
        let (core, wda, app) = core(store, decider: decider) { $0.actionCap = 1.2; $0.deciderPolicy.maxFixesPerStep = 2 }
        await record(core, app)
        // Not Now is renamed each time, so the remembered fix cannot stand in for the decider.
        let count = LockedBox(0)
        func prompt() -> [Node] { [Node("Alert", "Rate this app", [45, 300, 300, 180], [Node("Button", "Not Now", [60, 420, 130, 44], value: "\(count.value)")])] }
        app.prompt.value = prompt()
        app.show()
        wda.set("POST /wda/tap") { [app] _ in
            count.update { $0 += 1 }
            app.prompt.value = prompt()
            app.show()
            return (200, ["value": .null])
        }

        let result = await run(core)

        XCTAssertTrue(result.isError)
        XCTAssertEqual(count.value, 2, result.text)
        XCTAssertTrue(result.text.contains("stopped at step 1 of 2"), result.text)
    }

    // MARK: A path

    func testAPathCrossesScreensInOneCallByTheTextOfItsTargets() async throws {
        let store = RoutineStore(url: nil)
        let (core, wda, app) = core(store, decider: nil)
        app.go(0)
        _ = await core.call("look", [:])
        let taps = wda.bodies("POST /wda/tap").count

        let result = await core.call("do", ["actions": [["path": ["goal": "read the iOS version", "steps": [["tap": "General"], ["tap": "about", "intent": "open the About page"]], "expect": ["iOS Version"]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("path: 2 steps"), result.text)
        XCTAssertTrue(result.text.contains("end check passed"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps + 2)
        XCTAssertEqual(app.page.value, 2)

        // What the path did saves as a routine like steps sent by hand, with real targets.
        let saved = await core.call("routines", ["action": "save", "name": "version", "description": "read the iOS version"])
        XCTAssertFalse(saved.isError, saved.text)
        let routine = try XCTUnwrap(store.routine(named: "version"))
        XCTAssertEqual(routine.steps.map { $0.target?.type }, ["Button", "Button"])
        XCTAssertEqual(routine.steps.map { $0.target?.label }, ["General", "About"])
        XCTAssertEqual(routine.steps[1].intent, "open the About page")
    }

    func testAPathIsFixedOnTheWayLikeARoutine() async {
        let decider = ScriptedDecider(ScriptedDecider.answer("target", "About This iPhone"))
        let (core, _, app) = core(RoutineStore(url: nil), decider: decider)
        app.pages[1] = [Node("NavigationBar", "General", [0, 50, 390, 44]), Node("Button", "About This iPhone", [16, 100, 358, 44])]
        app.opens = ["General", "About This iPhone"]
        app.go(0)
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["goal": "read the iOS version", "steps": [["tap": "General"], ["tap": "About"]]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("fixed on the way: step 2: used Button \"About This iPhone\" for \"About\""), result.text)
        XCTAssertEqual(app.page.value, 2)
        XCTAssertEqual(decider.asked.value.first?.state["task"]?.string, "read the iOS version")
    }

    // MARK: Optional extras with a decision model

    func testATargetGivenByDescriptionIsChosenFromTheScreen() async {
        let decider = ScriptedDecider(ScriptedDecider.answer("target", "About"))
        let (core, _, app) = core(RoutineStore(url: nil), decider: decider)
        app.go(0)
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["goal": "read the iOS version", "steps": [["tap": "General"], ["tap": ["find": "the row that shows details of this iPhone"]]]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(app.page.value, 2)
        XCTAssertTrue(result.text.contains("chosen by description: step 2: chose Button \"About\""), result.text)
        XCTAssertFalse(result.text.contains("fixed on the way"), result.text)
        XCTAssertEqual(decider.asked.value.first?.state["wanted"]?["element"]?.string, "the element described as \"the row that shows details of this iPhone\"")
    }

    func testADescriptionWithoutADeciderIsRefusedBeforeAnythingIsSent() async {
        let (core, wda, app) = core(RoutineStore(url: nil), decider: nil)
        app.go(0)
        _ = await core.call("look", [:])
        let taps = wda.bodies("POST /wda/tap").count

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "General"], ["tap": ["find": "the About row"]]]]]]])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("needs a fast decision model"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
    }

    func testADescriptionThatIsNotFoundStopsWithoutWaitingOutTheStep() async {
        let decider = ScriptedDecider(ScriptedDecider.answer("stop"))
        let (core, _, app) = core(RoutineStore(url: nil), decider: decider) { $0.actionCap = 8 }
        app.go(0)
        _ = await core.call("look", [:])
        let began = Date()

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": ["find": "the Bluetooth row"]]]]]]])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("was not found"), result.text)
        XCTAssertEqual(app.tapped.value, [])
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testAStepsCheckIsAnsweredYesOrNoAndANoStopsTheRun() async {
        let yes = ScriptedDecider { _, _ in ["holds": DecisionAnswer(choice: nil, confidence: 0.95)] }
        let (core, _, app) = core(RoutineStore(url: nil), decider: yes)
        app.go(0)
        _ = await core.call("look", [:])
        let passed = await core.call("do", ["actions": [["path": ["steps": [["tap": "General", "check": "the General page is open"], ["tap": "About"]]]]]])
        XCTAssertFalse(passed.isError, passed.text)
        XCTAssertTrue(passed.text.contains("1 check passed"), passed.text)
        XCTAssertEqual(yes.asked.value.first?.state["expected"]?.string, "the General page is open")
        XCTAssertEqual(app.page.value, 2)

        let no = ScriptedDecider { _, _ in ["holds": DecisionAnswer(choice: nil, confidence: 0.04)] }
        let (core2, _, app2) = self.core(RoutineStore(url: nil), decider: no)
        app2.go(0)
        _ = await core2.call("look", [:])
        let stopped = await core2.call("do", ["actions": [["path": ["steps": [["tap": "General", "check": "the Wi-Fi page is open"], ["tap": "About"]]]]]])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("its check does not hold"), stopped.text)
        XCTAssertEqual(app2.tapped.value, ["General"])

        // Not sure either way: the run goes on and says the check was not answered.
        let unsure = ScriptedDecider { _, _ in ["holds": DecisionAnswer(choice: nil, confidence: 0.5)] }
        let (core3, _, app3) = self.core(RoutineStore(url: nil), decider: unsure)
        app3.go(0)
        _ = await core3.call("look", [:])
        let open = await core3.call("do", ["actions": [["path": ["steps": [["tap": "General", "check": "the General page is open"], ["tap": "About"]]]]]])
        XCTAssertFalse(open.isError, open.text)
        XCTAssertTrue(open.text.contains("1 check was not answered"), open.text)
    }

    func testAnIntentIsKeptWithTheStepAndNotSentWithIt() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, app) = core(store, decider: nil)
        await record(core, app)
        let routine = try XCTUnwrap(store.routine(named: "iOS version"))
        XCTAssertEqual(routine.steps.map(\.intent), ["open General", "open the About page"])
        XCTAssertNil(routine.steps[0].action["intent"])
        let shown = await core.call("routines", ["action": "show", "name": "iOS version"])
        XCTAssertTrue(shown.text.contains("(open the About page)"), shown.text)
    }

    func testAMemoryFileFromBeforeFixesStillLoads() throws {
        let old = #"{"schema":"poki.agent-backup/1","routines":[{"name":"x","description":"","steps":[{"action":{"tap":"@"},"target":{"type":"Button","label":"General","x":195,"y":122}}],"params":{},"expect":[],"read":[],"runs":3,"ok":3,"failuresInARow":0,"savedBy":"Poki","created":"2026-11-01T00:00:00Z","updated":"2026-11-01T00:00:00Z"}],"notes":[],"runs":[{"routine":"x","at":"2026-11-01T00:00:00Z","ms":900,"outcome":"ok","steps":["1 tap"]}]}"#
        let store = RoutineStore(url: nil)
        _ = try store.importData(Data(old.utf8), by: "test")
        let routine = try XCTUnwrap(store.routine(named: "x"))
        XCTAssertNil(routine.fixes)
        XCTAssertNil(routine.steps[0].clears)
        XCTAssertTrue(routine.steps[0].target!.hasPlace)
    }

    // MARK: The wire

    func testTheRequestIsTheSystemOneShapeAndCarriesTheToken() async throws {
        let sent = LockedBox<URLRequest?>(nil)
        let settings = DeciderSettings(provider: .cloudflare, model: "", account: "abc123")
        let decider = try XCTUnwrap(settings.decider(token: " secret ", send: { request in
            sent.value = request
            return (200, Data(#"{"result":{"model":"clef-flash","answers":{"move":{"type":"choice","choice":"stop","confidence":0.7,"probabilities":{"stop":0.8,"wait":0.2}},"ok":{"type":"noul","noul":0.98}},"usage":{"input_tokens":120,"output_tokens":12}},"success":true}"#.utf8))
        }))
        let questions = [DecisionQuestion(id: "move", instructions: "How to go on?", kind: .choice([("stop", "Stop"), ("wait", "Wait")])),
                         DecisionQuestion(id: "ok", instructions: "Is it fine?", kind: .yesNo)]

        let answers = try await decider.decide(state: ["task": "x"], questions: questions, timeout: 2)

        let request = try XCTUnwrap(sent.value)
        XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/abc123/ai/run/@cf/cloudflare/clef-flash")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try JSON.parse(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"]?.string, "clef-flash")
        XCTAssertEqual(body["state"]?["task"]?.string, "x")
        XCTAssertEqual(body["questions"]?["move"]?["type"]?.string, "choice")
        XCTAssertEqual(body["questions"]?["move"]?["criteria"]?["wait"]?.string, "Wait")
        XCTAssertEqual(body["questions"]?["ok"]?["type"]?.string, "noul")
        XCTAssertEqual(answers["move"], DecisionAnswer(choice: "stop", confidence: 0.7, probabilities: ["stop": 0.8, "wait": 0.2]))
        XCTAssertEqual(answers["move"]!.margin, 0.6, accuracy: 0.0001)
        XCTAssertEqual(answers["ok"]?.confidence, 0.98)
    }

    /// OpenAI's Decisions API, as its guide gives it: questions in an array with choices of value and
    /// description, answers in an array named after their questions.
    func testOpenAIDecisionsHasItsOwnRequestAndAnswerShape() async throws {
        let sent = LockedBox<URLRequest?>(nil)
        let settings = DeciderSettings(provider: .openai, model: "gpt-6-luna")
        XCTAssertNil(settings.decider(token: ""), "OpenAI needs a key")
        let decider = try XCTUnwrap(settings.decider(token: "sk-test", send: { request in
            sent.value = request
            return (200, Data(#"{"answers":[{"type":"predicate","name":"ok","probability":0.92},{"type":"choice","name":"move","choice":"stop","probabilities":[{"value":"stop","probability":0.95},{"value":"wait","probability":0.05}],"confidence":0.93}]}"#.utf8))
        }))
        let questions = [DecisionQuestion(id: "move", instructions: "How to go on?", kind: .choice([("stop", "Stop"), ("wait", "Wait")])),
                         DecisionQuestion(id: "ok", instructions: "Is it fine?", kind: .yesNo)]

        let answers = try await decider.decide(state: ["task": "x"], questions: questions, timeout: 2)

        let request = try XCTUnwrap(sent.value)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/decisions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try JSON.parse(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"]?.string, "gpt-6-luna")
        XCTAssertNil(body["state"])
        XCTAssertEqual(body["input"]?[0]?["role"]?.string, "user")
        XCTAssertEqual(body["input"]?[0]?["content"]?[0]?["type"]?.string, "input_json")
        XCTAssertEqual(body["input"]?[0]?["content"]?[0]?["data"]?["task"]?.string, "x")
        XCTAssertEqual(body["questions"]?[0]?["type"]?.string, "choice")
        XCTAssertEqual(body["questions"]?[0]?["name"]?.string, "move")
        XCTAssertEqual(body["questions"]?[0]?["choices"]?[1]?["value"]?.string, "wait")
        XCTAssertEqual(body["questions"]?[0]?["choices"]?[1]?["description"]?.string, "Wait")
        XCTAssertEqual(body["questions"]?[1]?["type"]?.string, "predicate")
        XCTAssertEqual(answers["move"], DecisionAnswer(choice: "stop", confidence: 0.93, probabilities: ["stop": 0.95, "wait": 0.05]))
        XCTAssertEqual(answers["ok"]?.confidence, 0.92)

        // Text goes as text; a refusal or a key error is an error, never a guess.
        XCTAssertEqual(SystemOneDecider.openAIBody(model: "gpt-6-luna", state: "A check.", questions: questions)["input"]?.string, "A check.")
        let refusal = Data(#"{"answers":[{"type":"refusal","name":"move"}]}"#.utf8)
        XCTAssertThrowsError(try SystemOneDecider.openAIAnswers(in: refusal, to: [questions[0]])) { XCTAssertTrue("\($0)".contains("refused"), "\($0)") }
        let denied = Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8)
        XCTAssertThrowsError(try SystemOneDecider.openAIAnswers(in: denied, to: questions)) { XCTAssertTrue("\($0)".contains("Incorrect API key"), "\($0)") }
    }

    /// A sign-in in place of a key: the token is asked for at each call, and none is an error.
    func testATokenSourceGivesTheTokenAtEachCall() async throws {
        let sent = LockedBox<URLRequest?>(nil), token = LockedBox<String?>("plan-1")
        let settings = DeciderSettings(provider: .openai, model: "gpt-6-luna")
        let decider = try XCTUnwrap(settings.decider(token: "", tokenSource: { token.value }, send: { request in
            sent.value = request
            return (403, Data(#"{"error":{"message":"This endpoint is not available for ChatGPT plan usage."}}"#.utf8))
        }))
        let check = await decider.check(timeout: 1)
        XCTAssertEqual(sent.value?.value(forHTTPHeaderField: "Authorization"), "Bearer plan-1")
        XCTAssertEqual(check, .failure(DeciderError("the provider answered 403: This endpoint is not available for ChatGPT plan usage.")))
        token.value = nil
        sent.value = nil
        let signedOut = await decider.check(timeout: 1)
        XCTAssertEqual(signedOut, .failure(DeciderError("the sign-in gave no token; sign in again")))
        XCTAssertNil(sent.value, "nothing is sent without a token")
    }

    /// A model on the phone answers in words: the JSON in them is read as strictly as a decision
    /// model's answer.
    func testAModelOnThePhoneAnswersThroughAPromptAndIsReadStrictly() async throws {
        let asked = LockedBox<(String, String)?>(nil), reply = LockedBox<String?>("Here it is:\n```json\n{\"move\": {\"choice\": \"wait\", \"confidence\": 0.8}, \"ok\": {\"yes\": 0.9}}\n```")
        let decider = PromptDecider(name: "Apple Intelligence", maxState: 40) { prompt, instructions in
            asked.value = (prompt, instructions)
            return reply.value
        }
        let questions = [DecisionQuestion(id: "move", instructions: "How to go on?", kind: .choice([("stop", "Stop"), ("wait", "Wait")])),
                         DecisionQuestion(id: "ok", instructions: "Is it fine?", kind: .yesNo)]

        let answers = try await decider.decide(state: ["task": .string(String(repeating: "x", count: 200))], questions: questions, timeout: 2)

        XCTAssertEqual(answers["move"], DecisionAnswer(choice: "wait", confidence: 0.8))
        XCTAssertEqual(decider.patience, 8, "a model on the phone gets longer than the policy's 2.5 s")
        XCTAssertNil(ScriptedDecider { _, _ in [:] }.patience)
        XCTAssertEqual(answers["move"]!.margin, 0.8, accuracy: 0.0001)
        XCTAssertEqual(answers["ok"]?.confidence, 0.9)
        let prompt = try XCTUnwrap(asked.value).0
        XCTAssertTrue(prompt.contains("option \"wait\": Wait"), prompt)
        XCTAssertTrue(prompt.contains("\"ok\" (yes or no): Is it fine?"), prompt)
        XCTAssertTrue(prompt.contains("(cut)") && !prompt.contains(String(repeating: "x", count: 60)), "the state is cut to the model's window")

        for (words, why) in [("I think you should wait.", "not JSON"), (#"{"move":{"choice":"tap","confidence":0.9},"ok":{"yes":1}}"#, "not an option"),
                             (#"{"move":{"choice":"wait"},"ok":{"yes":1}}"#, "without a confidence"), (#"{"move":{"choice":"wait","confidence":0.9}}"#, "no answer to")] {
            reply.value = words
            do { _ = try await decider.decide(state: "s", questions: questions, timeout: 2); XCTFail(words) } catch { XCTAssertTrue("\(error)".contains(why), "\(error)") }
        }
        reply.value = nil
        let none = await decider.check(timeout: 1)
        XCTAssertEqual(none, .failure(DeciderError("the model on this iPhone gave no answer")))
    }

    func testAnAnswerThatIsNotAnOptionIsAnErrorNotAGuess() {
        let questions = [DecisionQuestion(id: "move", instructions: "", kind: .choice([("stop", "Stop"), ("wait", "Wait")]))]
        let bare = Data(#"{"answers":{"move":{"type":"choice","choice":"tap","confidence":0.9,"probabilities":{}}}}"#.utf8)
        XCTAssertThrowsError(try SystemOneDecider.answers(in: bare, to: questions)) { XCTAssertTrue("\($0)".contains("not an option"), "\($0)") }
        let refused = Data(#"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#.utf8)
        XCTAssertThrowsError(try SystemOneDecider.answers(in: refused, to: questions)) { XCTAssertTrue("\($0)".contains("Authentication error"), "\($0)") }
        let good = Data(#"{"model":"jev-latest","answers":{"move":{"type":"choice","choice":"wait","confidence":0.7,"probabilities":{"stop":0.2,"wait":0.8}}}}"#.utf8)
        XCTAssertEqual(try SystemOneDecider.answers(in: good, to: questions)["move"]?.choice, "wait")
    }

    func testAFailedCallSaysTheStatusAndNeverTheRequest() async {
        let decider = SystemOneDecider(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, model: "jev-latest", token: "t",
                                       send: { _ in (401, Data(#"{"detail":"Invalid API key"}"#.utf8)) })
        let check = await decider.check(timeout: 1)
        XCTAssertEqual(check, .failure(DeciderError("the provider answered 401: Invalid API key")))
    }

    func testOnlyCompleteSettingsMakeADecider() {
        XCTAssertNil(DeciderSettings(provider: .cloudflare, account: "").url)
        XCTAssertNil(DeciderSettings(provider: .cloudflare, account: "../evil").url)
        XCTAssertNil(DeciderSettings(provider: .cloudflare, account: "abc").decider(token: ""))
        XCTAssertEqual(DeciderSettings(provider: .cloudflare, model: "clef", account: "abc").url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/abc/ai/run/@cf/cloudflare/clef")
        XCTAssertEqual(DeciderSettings(provider: .typesafe).url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(DeciderSettings(provider: .typesafe).modelInUse, "jev-latest")
        XCTAssertNil(DeciderSettings(provider: .custom, address: "http://example.com/v1/systemone").url, "plain http only on a private network")
        XCTAssertNotNil(DeciderSettings(provider: .custom, address: "http://192.168.1.20:8000/v1/systemone").url)
        XCTAssertNotNil(DeciderSettings(provider: .custom, address: "https://clef.example.com/v1/systemone").url)
    }
}
