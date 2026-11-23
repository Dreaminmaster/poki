import XCTest

extension SimFixtureTests {
    var dDicts: [String: NSDictionary] { [
        "D1": ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]],
        "D3": ["AXAuditClippingTest": ["AXAuditShouldRunTestOption": true]]] }
    func daemonCall(_ name: String, _ dict: NSDictionary) {
        guard let app = snap() else { say("DAEMON | \(name) | no app"); return }
        let t0 = Date()
        let r = PBHelper.daemonParamAttribute(95005, onSnapshot: app, parameter: dict)
        say("DAEMON | \(name) | \(String(format: "%.2f", Date().timeIntervalSince(t0))) s | \(r.prefix(300))")
    }
    func daemonCase(_ name: String, _ key: String, twice: Bool) {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        say("DAEMON | \(name) | 2013 \(barEscape())"); usleep(1_500_000); navDump("\(name) after 2013")
        daemonCall(name, dDicts[key]!)
        say("DAEMON | \(name) | front \(String(frontSummary().prefix(50)))")
        sleep(1); navDump("\(name) +1s"); sleep(4); navDump("\(name) +5s")
        say("DAEMON | \(name) | last=\(lastEvent())")
        if twice { daemonCall("\(name) second", dDicts[key]!); navDump("\(name) after second") }
        var n = 0; func c(_ e: XCUIElementSnapshot) { n += 1; e.children.forEach(c) }
        if let s = snap() { c(s) }
        say("DAEMON | \(name) | session check snap elements \(n)")
    }
    func testDAEMONATTR_background_D1() { daemonCase("D1", "D1", twice: false) }
    func testDAEMONATTR_background_D3() { daemonCase("D3", "D3", twice: false) }
    func testDAEMONATTR_background_D0() { daemonCase("D0", "D1", twice: true) }
}
