import XCTest

// Press route: accessibility actions 4000-4007 on the application element make UIKit build a UIPress
// in-process (-[UIApplicationAccessibility _iosAccessibilityPerformAction:withValue:fencePort:] ->
// _accessibilityActionIsPhysicalButton -> -[UIApplication _sendButtonEventWithPressInfo:]).
// 4000 select, 4002 menu, 4004 up, 4005 down, 4006 right, 4007 left. Fixture only.
extension SimFixtureTests {
    func press(_ id: Int) -> String {
        guard let app = snap() else { return "no app" }
        var err: NSString?
        let ok = PBHelper.pressSnapshot(app, action: id, value: nil, error: &err)
        return ok ? "ok" : "fail(\(err ?? ""))"
    }
    func pressCase(_ name: String, focus: ((XCUIElementSnapshot) -> Bool)?, _ id: Int = 4000) {
        var f = "-"
        if let focus { f = fkaFocus(find(snap(), focus)); usleep(700_000) }
        let before = lastEvent(); let nav = navTitle()
        let r = press(id); usleep(1_800_000)
        let after = lastEvent()
        say("PRESS | \(name) | focus \(f) | \(id) \(r) | handler: \(after == before ? "none" : after) | nav \(nav) -> \(navTitle())")
    }
    func pressRun(_ bg: Bool) {
        covLaunch(tab: "UIKit", bg: bg)
        pressCase("no focus, select", focus: nil)
        for (n, i) in [("UIButton configured", "cov.configured"), ("UIButton UIAction", "cov.uiaction"), ("UIButton target-action", "cov.target"), ("UISwitch", "cov.switch"), ("UIStepper", "cov.stepper"), ("UIButton menu open", "cov.menu")] {
            pressCase(n, focus: { $0.identifier == i })
        }
        covLaunch(tab: "UIKit", bg: bg)
        pressCase("tab bar button Lists", focus: { $0.label == "Lists" && $0.elementType == .button })
        covLaunch(tab: "UIKit", bg: bg)
        pressCase("push button", focus: { $0.identifier == "cov.push" })
        covLaunch(tab: "Lists", bg: bg)
        pressCase("list cell 1", focus: { $0.label == "ListCell 1" })
        pressCase("table cell 1", focus: { $0.label.hasPrefix("TableCell 1") })
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: bg)
        pressCase("back: menu press, no focus", focus: nil, 4002)
        for t in [3, 10, 30] { sleep(UInt32(t)); say("PRESS | back wait +\(t)s | nav \(navTitle()) | handler \(lastEvent())") }
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: bg)
        pressCase("back: focus back button, select", focus: { $0.elementType == .button && $0.label == "UIKit" })
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: bg)
        var err: NSString?
        let nb = find(snap()) { $0.elementType == .navigationBar }
        let ok = nb != nil && PBHelper.pressSnapshot(nb!, action: 2013, value: nil, error: &err)
        say("PRESS | back: 2013 on nav bar \(ok)")
        for t in [2, 8, 20, 30, 60] { sleep(UInt32(t)); say("PRESS | 2013 wait +\(t)s more | nav \(navTitle()) | handler \(lastEvent())") }
        covLaunch(tab: "UIKit", bg: bg)
        _ = fkaFocus(find(snap()) { $0.identifier == "cov.configured" }); usleep(600_000)
        for id in [4005, 4005, 4004] { say("PRESS | arrow \(id) \(press(id))"); usleep(900_000) }
        pressCase("select after arrows", focus: nil)
        if bg { say("PRESS | front after: \(String(frontSummary().prefix(50)))") }
    }
    func testPRESS_foreground() { pressRun(false) }
    func testPRESS_background() { pressRun(true) }
}
