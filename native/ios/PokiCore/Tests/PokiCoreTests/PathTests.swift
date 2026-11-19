import XCTest
@testable import PokiCore

/// Paths: steps written ahead by the text of their targets, crossed in one call with no model, and
/// every case where a path must stop as a routine does.
final class PathTests: XCTestCase {
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


    func core(_ store: RoutineStore, configure: @escaping (inout CoreConfig) -> Void = { _ in }) -> (PokiCore, FakeWDA, App) {
        let wda = FakeWDA()
        let app = App(wda, pages: [RoutineTests.home, RoutineTests.general, RoutineTests.about], opens: ["General", "About"])
        let (core, _, _) = makeCore(wda) {
            $0.memory = store
            configure(&$0)
        }
        return (core, wda, app)
    }

    // MARK: A path

    func testAPathCrossesScreensInOneCallByTheTextOfItsTargets() async throws {
        let store = RoutineStore(url: nil)
        let (core, wda, app) = core(store)
        app.go(0)
        _ = await core.call("look", [:])
        let taps = wda.bodies("POST /wda/tap").count

        let result = await core.call("do", ["actions": [["path": ["goal": "read the iOS version", "steps": [["tap": "General"], ["tap": "about"]], "expect": ["iOS Version"]]]]])

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
    }

    func testAPathStopsAtTheStepItCannotDoAndSaysWhatWasSent() async {
        let (core, _, app) = core(RoutineStore(url: nil)) { $0.actionCap = 1.2 }
        app.go(0)
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "General"], ["tap": "Storage"]]]]]])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("path stopped at step 2 of 2: \"Storage\" is not on screen"), result.text)
        XCTAssertTrue(result.text.contains("steps 1 to 1 were sent"), result.text)
        XCTAssertEqual(app.page.value, 1)
    }

    // MARK: What a path allows

    func testAPathClosesWhatItSaysMayBeClosedWithNoModel() async {
        let (core, _, app) = core(RoutineStore(url: nil))
        app.go(1)
        app.prompt.value = Self.notifications
        app.show()
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["goal": "read the iOS version", "steps": [["tap": "About"]], "dismiss": ["Later", "Not Now"], "read": ["iOS Version"]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(app.tapped.value, ["Not Now", "About"])
        XCTAssertTrue(result.text.contains("closed Button \"Not Now\" (allowed by the path)"), result.text)
        XCTAssertTrue(result.text.contains("read: iOS Version = 27.3"), result.text)
    }

    func testWhatAPathDidNotAllowIsNotClosed() async {
        let (core, _, app) = core(RoutineStore(url: nil)) { $0.actionCap = 1.2 }
        app.go(1)
        app.prompt.value = Self.notifications
        app.show()
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "About"]], "dismiss": ["Later"]]]]])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("behind an alert"), result.text)
        XCTAssertEqual(app.tapped.value, [])
    }

    func testAnOptionalStepIsLeftOutWhenItsTargetIsNotThere() async {
        let (core, _, app) = core(RoutineStore(url: nil))
        app.go(0)
        _ = await core.call("look", [:])
        let began = Date()

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "General"], ["tap": "Not Now", "optional": true], ["tap": "About"]]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(app.tapped.value, ["General", "About"])
        XCTAssertTrue(result.text.contains("1 optional step was left out"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
    }

    func testAnOptionalStepIsTakenWhenItsTargetIsThere() async {
        let (core, _, app) = core(RoutineStore(url: nil))
        app.go(1)
        app.prompt.value = Self.notifications
        app.show()
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "Not Now", "optional": true], ["tap": "About"]]]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(app.tapped.value, ["Not Now", "About"])
    }

    func testAStepsExpectIsReadFromTheScreenWithNoModel() async {
        let (core, _, app) = core(RoutineStore(url: nil))
        app.go(0)
        _ = await core.call("look", [:])

        let ok = await core.call("do", ["actions": [["path": ["steps": [["tap": "General", "expect": "Software Update"], ["tap": "About", "expect": ["iOS Version", "Model Name"]]]]]]])
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertEqual(app.page.value, 2)

        app.go(0)
        _ = await core.call("look", [:])
        let stopped = await core.call("do", ["actions": [["path": ["steps": [["tap": "General", "expect": "Storage"], ["tap": "About"]]]]]])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("stopped at step 1 of 2: the step was sent, but \"Storage\" did not appear after it"), stopped.text)
        XCTAssertEqual(app.page.value, 1)
    }

    func testAPathReadsAsItsGoalOrItsSteps() {
        let (core, _, _) = makeCore()
        XCTAssertEqual(core.computer.label(["path": ["goal": "check the version", "steps": [["tap": "General"]]]]), "Run “check the version”")
        XCTAssertEqual(core.computer.label(["path": ["steps": [["tap": "General"], ["tap": ["label": "About", "type": "Cell"]], ["swipe": "up"]]]]),
                       "Tap “General”, then tap “About”, then swipe up")
        XCTAssertEqual(core.computer.label(["path": [["long_press": "Photo"], ["tap": [200, 122]]]]), "Press and hold “Photo”, then tap at 200, 122")
    }

    func testASwipeInAPathTakesNoListNumber() async {
        for step: JSON in [["swipe": ["direction": "up", "in": 3]], ["swipe": "up", "in": 3]] {
            let wda = FakeWDA()
            wda.tree([Node("Button", "General", [16, 100, 358, 44])], app: "Settings")
            let (core, _, _) = makeCore(wda)
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "General"], step]]]]])
            XCTAssertTrue(result.text.contains("not in: a number from an earlier read"), "\(step): \(result.text)")
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "\(step): nothing was sent")
        }
    }

    func testADismissNamingAPaymentControlDoesNotPressIt() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Pay", [16, 100, 358, 44])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.actionCap = 1.5 }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "About"]], "dismiss": ["Pay"]]]]])

        XCTAssertTrue(result.text.contains("closing it needs the owner's approval"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "Pay was not pressed")
    }

    // MARK: Poki's own screen

    /// Poki in front once it is launched, showing its approval settings.
    func pokiOnLaunch(_ wda: FakeWDA) {
        wda.set("POST /wda/apps/activate") { [wda] body in
            if body?["bundleId"]?.string == "nz.zheha.poki" {
                wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
                wda.tree([Node("Button", "Never Ask", [16, 100, 358, 44])], app: "Poki")
            }
            return (200, ["value": .null])
        }
    }

    func testAPathSendsNoInputIntoPoki() async {
        let cases: [(steps: [JSON], dismiss: [JSON], rules: Bool, fromPoki: Bool)] = [
            ([["launch": "com.example.other"], ["launch": "nz.zheha.poki"], ["tap": "Never Ask"]], [], true, false),
            ([["launch": "nz.zheha.poki"], ["tap": [200, 122]]], [], false, false),
            ([["launch": "nz.zheha.poki"], ["tap": "Continue"]], ["Never Ask"], true, false),
            // A launch that did not open its app leaves Poki in front.
            ([["launch": "com.example.gone"], ["tap": [200, 122]]], [], false, true),
        ]
        for c in cases {
            let wda = FakeWDA()
            wda.tree([Node("Button", "General", [16, 100, 358, 44])], app: "Settings")
            pokiOnLaunch(wda)
            if c.fromPoki {
                wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
                wda.tree([Node("Button", "Never Ask", [16, 100, 358, 44])], app: "Poki")
            }
            let (core, _, _) = makeCore(wda) { $0.sensitive.enabled = c.rules; $0.actionCap = 1.5 }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["path": ["steps": .array(c.steps), "dismiss": .array(c.dismiss)]]]])

            XCTAssertTrue(result.text.contains("Poki takes no taps or typing inside the Poki app"), "\(c.steps): \(result.text)")
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "\(c.steps): nothing was tapped in Poki")
        }
    }

    // MARK: Optional extras with a decision model

    func testAPathRefusesNumbersFromAnEarlierRead() async {
        let (core, wda, app) = core(RoutineStore(url: nil))
        app.go(0)
        _ = await core.call("look", [:])
        let taps = wda.bodies("POST /wda/tap").count
        let result = await core.call("do", ["actions": [["path": ["steps": [["tap": "General"], ["tap": 3]]]]]])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("a target in a path is the element's text"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps, "nothing was sent")
    }
}
