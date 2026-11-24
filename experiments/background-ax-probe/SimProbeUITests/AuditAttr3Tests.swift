import XCTest

extension SimFixtureTests {
    // XCTest-channel 95005 on a background queue; probe the fixture while that call is pending.
    func testAUDITATTR_background_xct3() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        say("XCT3 | 2013 \(barEscape())")
        usleep(1_500_000); navDump("xct3 after 2013 ok")
        guard let app = snap() else { say("XCT3 | no app snapshot"); return }
        let dict: NSDictionary = ["AXAuditClippingTest": ["AXAuditShouldRunTestOption": true]]
        let done = DispatchSemaphore(value: 0)
        var result = ""; var secs = 0.0
        let t0 = Date()
        DispatchQueue.global().async {
            do { let v = try PBHelper.paramAttribute(95005, onSnapshot: app, parameter: dict); result = "value \(String(describing: v).count) chars" }
            catch { result = "error \(error)" }
            secs = Date().timeIntervalSince(t0); done.signal()
        }
        sleep(5)
        say("XCT3 | +5s pending=\(done.wait(timeout: .now()) == .timedOut)")
        let s = snap()
        say("XCT3 | +5s snap \(s == nil ? "no app" : "ok")")
        navDump("xct3 +5s"); say("XCT3 | +5s last=\(lastEvent())")
        _ = done.wait(timeout: .now() + 180)
        say("XCT3 | call returned after \(String(format: "%.1f", secs)) s | \(result.prefix(300))")
        navDump("xct3 after return"); say("XCT3 | last=\(lastEvent())")
    }
}
