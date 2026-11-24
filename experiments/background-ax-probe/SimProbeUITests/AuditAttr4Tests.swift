import XCTest

extension SimFixtureTests {
    func xct4Case(_ name: String, _ dict: NSDictionary) {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        say("XCT4 | \(name) | 2013 \(barEscape())"); usleep(1_500_000); navDump("\(name) after 2013")
        guard let app = snap() else { say("XCT4 | \(name) | no app"); return }
        let t0 = Date(); var r = ""
        do {
            let v = try PBHelper.paramAttributeString("95005", onSnapshot: app, parameter: dict)
            r = "value \(type(of: v)) len \(String(describing: v).count)"
        } catch { r = "error \(error)" }
        say("XCT4 | \(name) | \(String(format: "%.1f", Date().timeIntervalSince(t0))) s | \(r.prefix(300))")
        say("XCT4 | \(name) | front \(String(frontSummary().prefix(60)))")
        sleep(1); navDump("\(name) +1s"); sleep(5); navDump("\(name) +6s")
        say("XCT4 | \(name) | last=\(lastEvent())")
    }
    func testAUDITATTR_background_xct4_S3() { xct4Case("S3", ["AXAuditClippingTest": ["AXAuditShouldRunTestOption": true]]) }
    func testAUDITATTR_background_xct4_S1() { xct4Case("S1", ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]]) }
}
