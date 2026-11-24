import XCTest

extension SimFixtureTests {
    // Phone, one run, fixture only: 2013 on the nav bar, then one testmanagerd 95005 request (Clipping).
    func testPHONE_back2() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        say("PHONE2 | front after setup \(String(frontSummary().prefix(50)))")
        navDump("phone2 setup")
        say("PHONE2 | 2013 \(barEscape())")
        sleep(2); navDump("phone2 +2s after 2013")
        guard let app = snap() else { say("PHONE2 | no app snapshot"); fixture.terminate(); return }
        let t0 = Date()
        let r = PBHelper.daemonParamAttribute(95005, onSnapshot: app, parameter: ["AXAuditClippingTest": ["AXAuditShouldRunTestOption": true]] as NSDictionary)
        say("PHONE2 | daemon 95005 \(String(format: "%.2f", Date().timeIntervalSince(t0))) s | \(r.prefix(250))")
        say("PHONE2 | front \(String(frontSummary().prefix(50)))")
        sleep(1); navDump("phone2 +1s"); sleep(4); navDump("phone2 +5s")
        say("PHONE2 | last=\(lastEvent())")
        var n = 0; func c(_ e: XCUIElementSnapshot) { n += 1; e.children.forEach(c) }
        if let s = snap() { c(s) }
        say("PHONE2 | session check snap elements \(n)")
        fixture.terminate()
    }
}
