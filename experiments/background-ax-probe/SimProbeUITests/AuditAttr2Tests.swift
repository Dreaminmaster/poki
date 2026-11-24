import XCTest

extension SimFixtureTests {
    func fixturePid() -> Int32 { (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1 }
    func pidAlive(_ p: Int32) -> String { p > 0 ? (kill(p, 0) == 0 ? "alive \(p)" : "gone \(p)") : "no pid" }
    func xct2Case(_ name: String, _ dict: [String: Any]) {
        layoutCase(name) {
            self.say("AUDITATTR2 | \(name) | setAXTimeout(60) \(PBHelper.setAXTimeout(60))")
            let pid = self.fixturePid()
            let t0 = Date(); var r = ""
            do { let v = try PBHelper.paramAttribute(95005, onSnapshot: self.snap()!, parameter: dict as NSDictionary); r = "value \(String(describing: v).count) chars" }
            catch { r = "error \(error)" }
            let dt = Date().timeIntervalSince(t0)
            self.say("AUDITATTR2 | \(name) | \(String(format: "%.1f", dt)) s | \(r.prefix(300)) | \(self.pidAlive(pid)) | state \(self.fixture.state.rawValue)")
            sleep(1); self.navDump("\(name) +1s")
            sleep(5); self.navDump("\(name) +6s")
            self.say("AUDITATTR2 | \(name) | last=\(self.lastEvent()) | \(self.pidAlive(pid))")
            return String(r.prefix(60))
        }
    }
    func testAUDITATTR_background_xct2_X3() { xct2Case("X3 xct", ["AXAuditClippingTest": ["AXAuditShouldRunTestOption": true]]) }
    func testAUDITATTR_background_xct2_X1() { xct2Case("X1 xct", ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]]) }

    func frameOf(_ s: XCUIElementSnapshot?, label: String) -> String { (find(s) { $0.label == label }?.frame).map { "\($0)" } ?? "nil" }
    func countAll(_ s: XCUIElementSnapshot?) -> Int { guard let s else { return 0 }; return 1 + s.children.map { countAll($0) }.reduce(0, +) }
    func testAUDITATTR_background_after() {
        let x1: NSDictionary = ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]]
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        let s0 = snap()
        var rows: [String] = []
        func w(_ e: XCUIElementSnapshot) { if e.identifier.hasPrefix("DetailRow "), rows.count < 3 { rows.append("\(e.identifier) \(e.frame)") }; e.children.forEach(w) }
        if let s0 { w(s0) }
        say("AFTER | a | DetailItem \(frameOf(s0, label: "DetailItem")) | rows \(rows)")
        say("AFTER | b | 2013 \(barEscape())")
        var t0 = Date(); var r = PBHelper.rawParamAttribute(95005, onSnapshot: snap()!, parameter: x1)
        say("AFTER | b | raw \(String(format: "%.1f", Date().timeIntervalSince(t0))) s | len \(r.count) | \(r.prefix(80))")
        say("AFTER | b | front \(frontSummary())")
        sleep(1); navDump("after b +1s")
        let s1 = snap()
        say("AFTER | c | Present alert \(frameOf(s1, label: "Present alert")) | Push detail \(frameOf(s1, label: "Push detail")) | count \(countAll(s1))")
        t0 = Date(); r = PBHelper.rawParamAttribute(95005, onSnapshot: snap()!, parameter: x1)
        say("AFTER | c | raw2 \(String(format: "%.1f", Date().timeIntervalSince(t0))) s | len \(r.count) | \(r.prefix(80))")
        navDump("after c"); say("AFTER | c | last=\(lastEvent())")
        let target = find(snap()) { $0.elementType == .segmentedControl } ?? find(snap()) { $0.elementType == .button && $0.label == "BarItem" }
        let before = lastEvent()
        say("AFTER | d | 2010 on \(target.map { "\($0.elementType.rawValue) \($0.label)" } ?? "none") \(act(target, 2010)) | handler \(lastEvent() == before ? "none" : lastEvent())")
        sleep(1); say("AFTER | d | last=\(lastEvent())")
        fixture.activate(); sleep(1)
        navDump("e after activate"); let s2 = snap()
        say("AFTER | e | activated | last=\(lastEvent()) | Present alert \(frameOf(s2, label: "Present alert")) | Push detail \(frameOf(s2, label: "Push detail"))")
        covLaunch(tab: "UIKit", bg: false)
        let s3 = snap()
        say("AFTER | e | fresh FG | Present alert \(frameOf(s3, label: "Present alert")) | Push detail \(frameOf(s3, label: "Push detail"))")
    }
}
