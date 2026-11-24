import XCTest

extension SimFixtureTests {
    // Phone: one run, our fixture only. 2013 on the nav bar, then one direct 95005 read.
    func testPHONE_back() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        say("PHONE | front after setup \(String(frontSummary().prefix(50)))")
        navDump("phone setup")
        let r = barEscape(); say("PHONE | 2013 \(r)")
        sleep(2); navDump("phone +2s after 2013")
        guard let app = snap() else { say("PHONE | no app snapshot"); fixture.terminate(); return }
        let t0 = Date()
        let k = PBHelper.rawParamAttribute(95005, onSnapshot: app, parameter: ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]] as NSDictionary)
        let dt = String(format: "%.2f", Date().timeIntervalSince(t0))
        let code = k.hasPrefix("err ") ? String(k.dropFirst(4).prefix(while: { $0 != " " })) : "?"
        say("PHONE | direct 95005 \(dt) s | err \(code) | len \(k.count)")
        say("PHONE | front \(String(frontSummary().prefix(50)))")
        sleep(1); navDump("phone +1s after read")
        sleep(4); navDump("phone +5s after read")
        say("PHONE | last=\(lastEvent())")
        fixture.terminate()
    }
}
