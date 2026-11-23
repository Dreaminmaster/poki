import XCTest

extension SimFixtureTests {
    func selectedTab() -> String {
        guard let tb = find(snap(), { $0.elementType == .tabBar }) else { return "no tabbar" }
        return find(tb, { $0.elementType == .button && $0.isSelected })?.label ?? "none selected"
    }
    func kickAllCase(_ name: String, _ pick: (XCUIElementSnapshot?) -> XCUIElementSnapshot?) {
        covLaunch(tab: "UIKit", bg: true)
        let before = lastEvent()
        let r = act(pick(snap()), 2010); usleep(1_000_000)
        let afterPress = lastEvent()
        var kick = "no app"
        let t0 = Date()
        if let app = snap() {
            kick = PBHelper.rawParamAttribute(95005, onSnapshot: app, parameter: ["AXAuditDynamicTextSupportTest": ["AXAuditShouldRunTestOption": true]] as NSDictionary)
        }
        let dt = String(format: "%.2f", Date().timeIntervalSince(t0))
        let kickShort = kick.hasPrefix("err ") ? String(kick.prefix(while: { $0 != "v" })).trimmingCharacters(in: .whitespaces) + " len \(kick.count)" : kick
        sleep(1); let e1 = lastEvent(); navDump("\(name) +1s"); let t1 = selectedTab()
        sleep(3); let e4 = lastEvent(); navDump("\(name) +4s"); let t4 = selectedTab()
        say("KICKALL | \(name) | 2010 \(r) | before \(before) | afterPress \(afterPress) | kick \(dt) s \(kickShort) | +1s \(e1) tab \(t1) | +4s \(e4) tab \(t4) | front \(String(frontSummary().prefix(40)))")
        fixture.terminate()
    }
    func testKICKALL_background() {
        kickAllCase("configured") { s in self.find(s) { $0.identifier == "cov.configured" } }
        kickAllCase("target") { s in self.find(s) { $0.identifier == "cov.target" } }
        kickAllCase("push") { s in self.find(s) { $0.identifier == "cov.push" } }
        kickAllCase("firstRow") { s in self.find(s) { $0.elementType == .cell } }
        kickAllCase("tabLists") { s in self.find(s) { $0.elementType == .button && $0.label == "Lists" } }
        kickAllCase("switch") { s in self.find(s) { $0.identifier == "cov.switch" } }
        kickAllCase("stepperInc") { s in
            guard let st = self.find(s, { $0.identifier == "cov.stepper" }) else { return nil }
            return self.find(st) { $0.elementType == .button && ($0.label.lowercased().contains("increment") || $0.identifier.lowercased().contains("increment")) } ?? st.children.last
        }
        kickAllCase("menu") { s in self.find(s) { $0.identifier == "cov.menu" } }
    }
}
