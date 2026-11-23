import XCTest

// Parameterized attribute 95005 (app-side accessibility audit) on the fixture, after a background 2013 back.
extension SimFixtureTests {
    var auditRun: [String: Any] { ["AXAuditShouldRunTestOption": true] }
    var auditRunSpin: [String: Any] { ["AXAuditShouldRunTestOption": true, "AXAuditSpinRunLoopOption": true] }
    var auditDicts: [(String, [String: Any])] {
        [("1", ["AXAuditDynamicTextSupportTest": auditRun]),
         ("2", ["AXAuditDynamicTextSupportTest": auditRunSpin]),
         ("3", ["AXAuditClippingTest": auditRun]),
         ("4", ["AXAuditDynamicTextSupportTest": auditRunSpin, "AXAuditClippingTest": auditRun, "AXAuditInaccessibileElementTest": auditRun, "AXAuditContrastDetectionTest": auditRun]),
         ("5", [String: Any]())]
    }
    func auditCall(_ raw: Bool, _ target: XCUIElementSnapshot?, _ dict: [String: Any]) -> String {
        guard let t = target else { return "no target" }
        if raw { return PBHelper.rawParamAttribute(95005, onSnapshot: t, parameter: dict as NSDictionary) }
        do {
            let v = try PBHelper.paramAttribute(95005, onSnapshot: t, parameter: dict as NSDictionary)
            return "value \(String(describing: v).prefix(600))"
        } catch { return "error \(error)" }
    }
    func auditKick(_ name: String, raw: Bool, onBar: Bool, _ dict: [String: Any]) -> String {
        let target = onBar ? find(snap(), { $0.elementType == .navigationBar }) : snap()
        let r = auditCall(raw, target, dict)
        say("AUDITATTR | \(name) | \(r.prefix(800)) | \(String(frontSummary().prefix(60))) | last=\(lastEvent())")
        sleep(1); navDump("\(name) +1s")
        sleep(3); navDump("\(name) +4s")
        sleep(4); navDump("\(name) +8s")
        return String(r.prefix(80))
    }
    func testAUDITATTR_background() {
        for (n, d) in auditDicts { layoutCase("A\(n) raw") { self.auditKick("A\(n) raw", raw: true, onBar: false, d) } }
        let a2 = auditDicts[1].1
        layoutCase("C1 raw bar") { self.auditKick("C1 raw bar", raw: true, onBar: true, a2) }
    }
    // Separate run of the xct cases only (the raw helper throws NSUnknownKeyException before any xct case runs).
    func testAUDITATTR_background_xct() {
        for (n, d) in auditDicts { layoutCase("B\(n) xct") { self.auditKick("B\(n) xct", raw: false, onBar: false, d) } }
        layoutCase("C2 xct bar") { self.auditKick("C2 xct bar", raw: false, onBar: true, self.auditDicts[1].1) }
    }
    func testAUDITATTR_foreground_xct() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: false)
        say("AUDITATTR | FG B2 xct | \(auditCall(false, snap(), auditDicts[1].1).prefix(800)) | last=\(lastEvent())")
        navDump("FG after B2")
    }
    func testAUDITATTR_foreground() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: false)
        let a2 = auditDicts[1].1
        say("AUDITATTR | FG A2 raw | \(auditCall(true, snap(), a2).prefix(800)) | last=\(lastEvent())")
        navDump("FG after A2")
    }
}
