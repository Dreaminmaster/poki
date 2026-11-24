import XCTest

// The back call (2013) is delivered in the background but the pop only shows once the app is frontmost again,
// so the navigation transition is waiting for a layout pass. This tries known accessibility calls that may
// drive one while the app stays in the background. Fresh launch per case so results do not mix.
extension SimFixtureTests {
    func appAct(_ id: Int, _ v: Any? = nil) -> String {
        guard let app = snap() else { return "no app" }
        var err: NSString?
        return PBHelper.pressSnapshot(app, action: id, value: v, error: &err) ? "ok" : "fail"
    }
    func barEscape() -> String {
        guard let bar = find(snap(), { $0.elementType == .navigationBar }) else { return "no bar" }
        var err: NSString?
        return PBHelper.pressSnapshot(bar, action: 2013, value: nil, error: &err) ? "ok" : "fail"
    }
    func layoutCase(_ name: String, _ kick: () -> String) {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        let r0 = barEscape(); usleep(1_500_000); navDump("\(name) | after 2013 \(r0)")
        let r = kick(); usleep(1_500_000); navDump("\(name) | after kick \(r)")
        sleep(5); navDump("\(name) | +5s")
    }
    func testLAYOUT_background() {
        layoutCase("none") { "-" }
        layoutCase("5313 focus update") { self.appAct(5313) }
        layoutCase("fka focus DetailItem") { self.fkaFocus(self.find(self.snap(), { $0.identifier == "cov.detailitem" })) }
        layoutCase("2003 on DetailItem") { self.act(self.find(self.snap(), { $0.identifier == "cov.detailitem" }), 2003) }
        layoutCase("5021 scroll amount") { self.appAct(5021, NSNumber(value: 1)) }
        layoutCase("5311 focus reset") { self.appAct(5311) }
        layoutCase("second 2013") { self.barEscape() }
        say("LAYOUT | front after: \(frontSummary())")
    }
}
