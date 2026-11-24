import XCTest

// Diagnostic for the back route: accessibility escape (2013) on the navigation bar calls
// -[UINavigationBar _accessibility_triggerBackButton] directly, no touch. This checks what the hierarchy
// looks like after it in the background. The final activate is a simulator-only diagnostic, not a route.
extension SimFixtureTests {
    func navDump(_ tag: String) {
        guard let app = snap() else { say("BACK | \(tag) | no app"); return }
        var bars: [String] = [], btns: [String] = []
        func w(_ e: XCUIElementSnapshot, _ inBar: Bool) {
            let bar = inBar || e.elementType == .navigationBar
            if e.elementType == .navigationBar { bars.append(e.identifier) }
            if bar, e.elementType == .button { btns.append(e.label.isEmpty ? e.identifier : e.label) }
            e.children.forEach { w($0, bar) }
        }
        w(app, false)
        let d = find(app) { $0.identifier == "cov.detailitem" } != nil
        let c = find(app) { $0.identifier == "cov.configured" } != nil
        say("BACK | \(tag) | bars \(bars) | barButtons \(btns) | detailitem \(d) | configured \(c) | last \(lastEvent())")
    }
    func esc(_ name: String, _ e: XCUIElementSnapshot?) {
        guard let e else { say("BACK | 2013 on \(name) | not found"); return }
        var err: NSString?
        let ok = PBHelper.pressSnapshot(e, action: 2013, value: nil, error: &err)
        say("BACK | 2013 on \(name) | \(ok) \(err ?? "")")
        usleep(2_000_000); navDump("after \(name) +2s")
    }
    func backRun(_ bg: Bool) {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: bg)
        navDump("start")
        esc("nav bar 1", find(snap()) { $0.elementType == .navigationBar })
        esc("nav bar 2", find(snap()) { $0.elementType == .navigationBar })
        esc("detail bar item", find(snap()) { $0.identifier == "cov.detailitem" })
        esc("app", snap())
        sleep(10); navDump("+10s more")
        if bg {
            fixture.activate(); usleep(300_000); navDump("diagnostic foreground +0.3s")
            sleep(2); navDump("diagnostic foreground +2.3s")
        }
    }
    func testBACK_foreground() { backRun(false) }
    func testBACK_background() { backRun(true) }
}
