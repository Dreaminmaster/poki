import XCTest

// Coverage table: every control of the fixture's -coverage mode, read and activate in foreground and background.
// Background = Settings in front, fixture kept running by testmanagerd's background assertion.
extension SimFixtureTests {
    struct CovRow { let name: String; let find: (XCUIElementSnapshot) -> Bool; let actions: [String] }
    struct CovGroup { let tab: String; let presenter: String?; let rows: [CovRow] }

    func id(_ s: String) -> (XCUIElementSnapshot) -> Bool { { $0.identifier == s } }
    func lbl(_ s: String, _ t: XCUIElement.ElementType? = nil) -> (XCUIElementSnapshot) -> Bool { { $0.label == s && (t == nil || $0.elementType == t!) } }

    var covGroups: [CovGroup] {
        let tap = ["2010", "2036"]
        let adj = ["2004", "2010"]
        let toggle = ["2010", "fka-right"]
        let text = ["set+2054", "set+key-return"]
        return [
            CovGroup(tab: "UIKit", presenter: nil, rows: [
                CovRow(name: "UIButton Configuration + primaryAction", find: id("cov.configured"), actions: tap + ["fka-space"]),
                CovRow(name: "UIButton addAction(UIAction)", find: id("cov.uiaction"), actions: tap),
                CovRow(name: "UIButton target-action", find: id("cov.target"), actions: tap),
                CovRow(name: "UISwitch", find: id("cov.switch"), actions: toggle),
                CovRow(name: "UIStepper", find: id("cov.stepper"), actions: adj + ["fka-stepper"]),
                CovRow(name: "UIPageControl", find: id("cov.page"), actions: adj),
                CovRow(name: "UIDatePicker (compact)", find: id("cov.date"), actions: adj),
                CovRow(name: "UIPickerView", find: { $0.elementType == .pickerWheel }, actions: adj),
                CovRow(name: "UISearchBar Return", find: id("cov.search"), actions: text),
                CovRow(name: "UITextField Return", find: id("cov.field"), actions: text),
                CovRow(name: "UIButton menu (open)", find: id("cov.menu"), actions: tap),
                CovRow(name: "UIBarButtonItem (primaryAction)", find: id("cov.baritem"), actions: tap),
                CovRow(name: "Push button (nav)", find: id("cov.push"), actions: tap),
                CovRow(name: "Tab bar: Lists tab (UITab)", find: lbl("Lists", .button), actions: tap),
            ]),
            CovGroup(tab: "UIKit", presenter: "cov.alert", rows: [CovRow(name: "UIAlertController alert button", find: lbl("AlertOK"), actions: tap)]),
            CovGroup(tab: "UIKit", presenter: "cov.sheet", rows: [CovRow(name: "UIAlertController action sheet row", find: lbl("AlertOther"), actions: tap)]),
            CovGroup(tab: "UIKit", presenter: "cov.menu", rows: [CovRow(name: "UIMenu item (button menu)", find: lbl("MenuItemA"), actions: tap)]),
            CovGroup(tab: "UIKit", presenter: "cov.push", rows: [
                CovRow(name: "Nav bar item on pushed VC (target-action)", find: id("cov.detailitem"), actions: tap),
                CovRow(name: "Nav back button", find: { $0.elementType == .button && $0.label == "UIKit" }, actions: tap + ["2013"]),
            ]),
            CovGroup(tab: "Lists", presenter: nil, rows: [
                CovRow(name: "UICollectionViewListCell select", find: lbl("ListCell 0"), actions: tap),
                CovRow(name: "UICollectionViewListCell detail accessory", find: { $0.elementType == .button && $0.label.contains("More Info") || $0.label.contains("Detail") }, actions: tap),
                CovRow(name: "UITableViewCell (content configuration)", find: { $0.label.hasPrefix("TableCell 0") }, actions: tap),
            ]),
            CovGroup(tab: "SwiftUI", presenter: nil, rows: [
                CovRow(name: "SwiftUI Button", find: id("sui.button"), actions: tap),
                CovRow(name: "SwiftUI Toggle", find: id("sui.toggle"), actions: toggle),
                CovRow(name: "SwiftUI Stepper", find: id("sui.stepper"), actions: adj),
                CovRow(name: "SwiftUI Slider", find: id("sui.slider"), actions: adj),
                CovRow(name: "SwiftUI segmented Picker (P1)", find: lbl("P1", .button), actions: tap),
                CovRow(name: "SwiftUI TextField onSubmit", find: id("sui.field"), actions: text),
                CovRow(name: "SwiftUI NavigationLink row", find: id("sui.link"), actions: tap),
                CovRow(name: "SwiftUI TabView tab", find: lbl("InnerTabB", .button), actions: tap),
            ]),
            CovGroup(tab: "SwiftUI", presenter: nil, rows: [CovRow(name: "SwiftUI menu Picker (open)", find: id("sui.menupicker"), actions: tap)]),
            CovGroup(tab: "SwiftUI", presenter: nil, rows: [CovRow(name: "SwiftUI Menu (open)", find: { $0.label == "SUIMenu" }, actions: tap)]),
            CovGroup(tab: "SwiftUI", presenter: "sui.sheet", rows: [CovRow(name: "SwiftUI sheet button", find: id("sui.sheetbutton"), actions: tap)]),
            CovGroup(tab: "SwiftUI", presenter: "sui.alert", rows: [CovRow(name: "SwiftUI alert button", find: lbl("SUIAlertOK"), actions: tap)]),
            CovGroup(tab: "SwiftUI", presenter: "sui.menu", rows: [CovRow(name: "SwiftUI Menu item", find: lbl("SUIMenuItem"), actions: tap)]),
            CovGroup(tab: "Web", presenter: nil, rows: [
                CovRow(name: "WKWebView link", find: lbl("WebLink", .link), actions: tap),
                CovRow(name: "WKWebView button", find: lbl("WebButton", .button), actions: tap),
                CovRow(name: "WKWebView checkbox", find: { $0.label == "WebCheck" && ($0.elementType == .checkBox || $0.elementType == .switch) }, actions: tap),
                CovRow(name: "WKWebView text input", find: { $0.elementType == .textField }, actions: text),
                CovRow(name: "WKWebView submit", find: lbl("WebSubmit", .button), actions: tap),
            ]),
            CovGroup(tab: "UIKit", presenter: nil, rows: [CovRow(name: "Context menu (open, 2059)", find: id("cov.context"), actions: ["2059"])]),
        ]
    }

    func covAct(_ e: XCUIElementSnapshot, _ a: String) -> String {
        var err: NSString?
        switch a {
        case "2010", "2036", "2004", "2013":
            return PBHelper.pressSnapshot(e, action: Int(a)!, value: nil, error: &err) ? "ok" : "fail"
        case "2059":
            let f = e.frame; let p = NSValue(cgPoint: CGPoint(x: f.midX, y: f.midY))
            return PBHelper.pressSnapshot(e, action: 2059, value: p, error: &err) ? "ok" : "fail"
        case "set+2054", "set+key-return":
            let s = PBHelper.setAttribute("XC_kAXXCAttributeValue", value: "hello" as NSString, onSnapshot: e, error: &err) ? "ok" : "fail"
            usleep(300_000)
            if a == "set+2054" { var e2: NSString?; return "set \(s), 2054 " + (PBHelper.pressSnapshot(e, action: 2054, value: nil, error: &e2) ? "ok" : "fail") }
            return "set \(s), Return " + sendKey("\r")
        case "fka-right", "fka-space", "fka-stepper":
            guard let app = snap() else { return "no app" }
            let sid = (find(snap()) { $0.identifier == "sceneId" }?.value as? String) ?? ""
            _ = PBHelper.pressSnapshot(app, action: 5305, value: NSNumber(value: true), error: &err)
            if !sid.isEmpty { _ = PBHelper.pressSnapshot(app, action: 5310, value: sid as NSString, error: &err) }
            usleep(500_000)
            let f = PBHelper.pressSnapshot(e, action: 2044, value: nil, error: &err) ? "ok" : "fail"; usleep(600_000)
            return "focus \(f), key " + sendKey(a == "fka-space" ? " " : "UIKeyInputRightArrow")
        default: return "?"
        }
    }

    func runCoverage(_ bg: Bool) {
        background = bg
        for g in covGroups {
            usleep(500_000)
            fixture.launchArguments = ["-coverage", "-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
            fixture.launch()
            let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
            if g.tab != "UIKit" { fixture.tabBars.buttons[g.tab].tap(); sleep(1) }
            if let p = g.presenter { fixture.descendants(matching: .any)[p].firstMatch.tap(); sleep(1) }
            if g.tab == "Web" { sleep(3) }
            if bg { _ = PBHelper.requestBackgroundAssertion(forPID: pid); settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(1) }
            let fb = bg ? String(frontSummary().prefix(40)) : "-"
            for r in g.rows {
                guard let e = find(snap(), r.find) else { say("COV | \(r.name) | read: NOT FOUND"); continue }
                var tried: [String] = []; var fired = "none"
                for a in r.actions {
                    guard let e2 = find(snap(), r.find) ?? Optional(e) else { break }
                    let before = lastEvent(); let res = covAct(e2, a); usleep(1_200_000)
                    let after = lastEvent()
                    tried.append("\(a): \(res)")
                    if after != before { fired = "\(a) → \(after)"; break }
                }
                say("COV | \(r.name) | read: ok (\(e.elementType.rawValue)) | fired: \(fired) | tried: \(tried.joined(separator: "; "))")
            }
            if bg { say("COV | front check \(g.tab)/\(g.presenter ?? "-") | before: \(fb) | after: \(String(frontSummary().prefix(40)))") }
        }
    }
    func testCOV_foreground() { runCoverage(false) }
    func testCOV_background() { runCoverage(true) }
}

extension SimFixtureTests {
    func covLaunch(tab: String, presenter: String? = nil, bg: Bool) {
        background = bg
        fixture.launchArguments = ["-coverage", "-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        fixture.launch()
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        if tab != "UIKit" { fixture.tabBars.buttons[tab].tap(); sleep(1) }
        if let p = presenter { fixture.descendants(matching: .any)[p].firstMatch.tap(); sleep(1) }
        if bg { _ = PBHelper.requestBackgroundAssertion(forPID: pid); settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(1) }
    }
    func tryAct(_ name: String, _ e: XCUIElementSnapshot?, _ id: Int, _ v: Any? = nil) {
        guard let e else { say("ALT | \(name) | not found"); return }
        let before = lastEvent(); var err: NSString?
        let ok = PBHelper.pressSnapshot(e, action: id, value: v, error: &err); usleep(1_200_000)
        say("ALT | \(name) | \(id) \(ok ? "ok" : "fail") | handler: \(lastEvent() == before ? "none" : lastEvent())")
    }
    func fkaFocus(_ e: XCUIElementSnapshot?) -> String {
        guard let app = snap(), let e else { return "no" }
        var err: NSString?
        let sid = (find(snap()) { $0.identifier == "sceneId" }?.value as? String) ?? ""
        _ = PBHelper.pressSnapshot(app, action: 5305, value: NSNumber(value: true), error: &err)
        if !sid.isEmpty { _ = PBHelper.pressSnapshot(app, action: 5310, value: sid as NSString, error: &err) }
        usleep(500_000)
        return PBHelper.pressSnapshot(e, action: 2044, value: nil, error: &err) ? "ok" : "fail"
    }
    func altRun(_ bg: Bool) {
        // back: escape on app, on the pushed screen's nav bar, on the detail item
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: bg)
        tryAct("back: 2013 on app", snap(), 2013)
        tryAct("back: 2013 on nav bar", find(snap()) { $0.elementType == .navigationBar }, 2013)
        tryAct("back: 2013 on detail item", find(snap()) { $0.identifier == "cov.detailitem" }, 2013)
        // tabs: actions on the tab bar itself
        covLaunch(tab: "UIKit", bg: bg)
        for id in [2008, 2009, 2004, 2005, 2019, 2020, 2006, 2007] { tryAct("tabs: \(id) on tab bar", find(snap()) { $0.elementType == .tabBar }, id) }
        // cells: focus (selection follows focus?), then Return/Space keys
        covLaunch(tab: "Lists", bg: bg)
        for (n, p) in [("list cell 1", { (s: XCUIElementSnapshot) in s.label == "ListCell 1" }), ("table cell 1", { (s: XCUIElementSnapshot) in s.label.hasPrefix("TableCell 1") })] {
            let before = lastEvent(); let f = fkaFocus(find(snap(), p)); usleep(1_200_000)
            say("ALT | \(n): FKA focus \(f) | handler: \(lastEvent() == before ? "none" : lastEvent())")
            for k in ["\r", " ", "UIKeyInputDownArrow"] {
                let b2 = lastEvent(); let r = sendKey(k); usleep(1_000_000)
                say("ALT | \(n): key \(k == "\r" ? "Return" : k == " " ? "Space" : "Down") \(r) | handler: \(lastEvent() == b2 ? "none" : lastEvent())")
            }
        }
        // text field: becomeFirstResponder via attribute 3002, set value, Return key event
        covLaunch(tab: "UIKit", bg: bg)
        for fid in ["cov.field", "cov.search"] {
            guard let f = find(snap(), { $0.identifier == fid }) else { continue }
            var err: NSString?
            let fr = PBHelper.setAttribute("XC_kAXXCAttributeFocused", value: NSNumber(value: true), onSnapshot: f, error: &err) || PBHelper.setAttribute("3002", value: NSNumber(value: true), onSnapshot: f, error: &err)
            let sv = PBHelper.setAttribute("XC_kAXXCAttributeValue", value: "hello" as NSString, onSnapshot: f, error: &err); usleep(500_000)
            let before = lastEvent(); let r = sendKey("\r"); usleep(1_000_000)
            say("ALT | \(fid): 3002 \(fr), set \(sv), key Return \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
            tryAct("\(fid): 2054 after first responder", find(snap(), { $0.identifier == fid }), 2054)
        }
        if bg { say("ALT | front after: \(String(frontSummary().prefix(50)))") }
    }
    func testALT_foreground() { altRun(false) }
    func testALT_background() { altRun(true) }
}

extension SimFixtureTests {
    // Covered-but-foreground: fixture in front, then an overlay. Log state, then the in-process tap ("j"),
    // the switch via FKA focus + arrow, and a plain 2010 for reference.
    func overlayRun(_ overlay: String) {
        background = false
        fixture.launchArguments = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        fixture.launch(); sleep(3)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        switch overlay {
        case "notification-center":
            let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.0)); let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: end)
        case "control-center":
            let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.0)); let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: end)
        case "app-switcher":
            let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999)); let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragHoldTo: end) 
        default: break
        }
        sleep(3)
        say("OV | \(overlay) | fixture state \(fixture.state.rawValue)")
        var before = lastEvent(); _ = sendKey("j"); sleep(2)
        say("OV | \(overlay) | in-process tap (j) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        if let sw = find(snap(), { $0.elementType == .switch }) {
            let f = fkaFocus(sw); usleep(600_000)
            before = lastEvent(); _ = sendKey("UIKeyInputRightArrow"); usleep(1_200_000)
            say("OV | \(overlay) | switch FKA focus \(f) + Right | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        if let b = find(snap(), { $0.label == "Plain button" && $0.elementType == .button }), let lab = find(snap(), { $0.identifier == "sceneId" })?.label, lab.hasPrefix("ctx:"), let ctx = UInt32(lab.dropFirst(4)) {
            let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
            let p = CGPoint(x: b.frame.midX, y: b.frame.midY)
            before = lastEvent(); let r = PBHelper.postTap(at: p, contextId: ctx, pid: pid, displayId: 0, down: 1, up: 6); sleep(1)
            say("OV | \(overlay) | context-addressed AX touch ctx=\(ctx) at \(p) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        } else { say("OV | \(overlay) | no ctx label") }
        tryAct("\(overlay) | plain button 2010", find(snap()) { $0.label == "Plain button" && $0.elementType == .button }, 2010)
        XCUIDevice.shared.press(.home); sleep(1)
    }
    func testOV_notificationCenter() { overlayRun("notification-center") }
    func testOV_controlCenter() { overlayRun("control-center") }
    func testOV_appSwitcher() { overlayRun("app-switcher") }
}

extension XCUICoordinate {
    func press(forDuration d: TimeInterval, thenDragHoldTo end: XCUICoordinate) { press(forDuration: d, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0) }
}

extension SimFixtureTests {
    // Round trip: background fixture -> front -> tap plain button (normal synthesized tap) -> back to Settings. Timings.
    func testRT_roundTrip() {
        background = true
        fixture.launchArguments = []
        fixture.launch(); sleep(2)
        settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(2)
        for i in 1...3 {
            let t0 = Date()
            fixture.activate(); _ = fixture.wait(for: .runningForeground, timeout: 10)
            let t1 = Date()
            let b = fixture.buttons["Plain button"]; let before = lastEvent()
            b.tap()
            var t2 = Date(); for _ in 0..<50 { if lastEvent() != before { t2 = Date(); break }; usleep(20_000) }
            settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10)
            let t3 = Date()
            func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
            say("RT | run \(i) | to front \(ms(t0, t1)) ms | tap+handler \(ms(t1, t2)) ms | back to Settings \(ms(t2, t3)) ms | total \(ms(t0, t3)) ms | handler: \(lastEvent())")
            sleep(2)
        }
    }
}

extension SimFixtureTests {
    func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
    func frameOf(_ pred: (XCUIElementSnapshot) -> Bool) -> CGRect? { find(snap(), pred)?.frame }
    // One turn: target to front, tap each point once the scene reports foreground, back to Settings.
    func fastTurn(_ points: [(String, CGPoint)], earlyPoll: Bool) -> String {
        let t0 = Date()
        fixture.activate(); let a = "activate()"
        let t1 = Date()
        if earlyPoll { for _ in 0..<100 { if fixture.state == .runningForeground { break }; usleep(10_000) } }
        let t2 = Date()
        var legs: [String] = []
        for (name, p) in points { let s = Date(); let r = PBHelper.synthTap(at: p, timeout: 5); legs.append("\(name) \(r) \(ms(s, Date())) ms") }
        let t3 = Date()
        settings.activate(); let b = "activate()"
        let t4 = Date()
        return "activate \(ms(t0, t1)) ms (\(a.prefix(12))) | wait fg \(ms(t1, t2)) ms | taps [\(legs.joined(separator: "; "))] \(ms(t2, t3)) ms | back \(ms(t3, t4)) ms (\(b.prefix(12))) | on screen ≈ \(ms(t1, t4)) ms | total \(ms(t0, t4)) ms"
    }
    func fastRun(reduceMotion: Bool, earlyPoll: Bool) {
        background = true
        say("FR | \(PBHelper.setReduceMotion(reduceMotion))")
        fixture.launchArguments = []; fixture.launch(); sleep(2)
        guard let bf = frameOf({ $0.label == "Plain button" && $0.elementType == .button }) else { say("FR | no button"); return }
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(2)
        _ = PBHelper.requestBackgroundAssertion(forPID: pid)
        for i in 1...5 {
            let before = lastEvent()
            let r = fastTurn([("button", CGPoint(x: bf.midX, y: bf.midY))], earlyPoll: earlyPoll)
            usleep(600_000)
            say("FR | rm=\(reduceMotion) early=\(earlyPoll) run \(i) | \(r) | handler (BG snapshot): \(lastEvent() == before ? "none" : lastEvent()) | front: \(String(frontSummary().prefix(30)))")
            sleep(2)
        }
    }
    func testFR_plain() { fastRun(reduceMotion: false, earlyPoll: false) }
    func testFR_early() { fastRun(reduceMotion: false, earlyPoll: true) }
    func testFR_reduceMotionEarly() { fastRun(reduceMotion: true, earlyPoll: true); _ = PBHelper.setReduceMotion(false) }
}

extension SimFixtureTests {
    func settingsState() -> String {
        guard let s = try? settings.snapshot() else { return "unreadable" }
        let field = find(s) { $0.elementType == .searchField }
        let kb = find(s) { $0.elementType == .keyboard } != nil
        let firstCell = find(s) { $0.elementType == .cell }?.label ?? "-"
        return "search='\((field?.value as? String) ?? "")' keyboard=\(kb) firstCell='\(firstCell.prefix(20))' cellY=\(Int(find(s) { $0.elementType == .cell }?.frame.minY ?? -1))"
    }
    func testFB_batchAndState() {
        background = true
        _ = PBHelper.setReduceMotion(false)
        fixture.launchArguments = []; fixture.launch(); sleep(2)
        let s = snap()
        guard let b1 = find(s, { $0.label == "Plain button" && $0.elementType == .button })?.frame,
              let b2 = find(s, { $0.label == "Push level 2" && $0.elementType == .button })?.frame,
              let row = find(s, { $0.elementType == .cell })?.frame else { say("FB | frames missing"); return }
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        // Settings: scroll a bit, start a search with the keyboard up and text typed
        settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(1)
        settings.swipeUp(); sleep(1); settings.swipeDown(); sleep(1)
        let sf = settings.searchFields.firstMatch; if sf.waitForExistence(timeout: 3) { sf.tap(); sf.typeText("wi"); sleep(1) }
        _ = PBHelper.requestBackgroundAssertion(forPID: pid)
        say("FB | Settings before: \(settingsState())")
        let r = fastTurn([("plain button", CGPoint(x: b1.midX, y: b1.midY)), ("push button", CGPoint(x: b2.midX, y: b2.midY)), ("table row", CGPoint(x: row.midX, y: row.midY))], earlyPoll: true)
        sleep(1)
        say("FB | batch turn | \(r)")
        say("FB | Settings after: \(settingsState())")
    }
}

extension SimFixtureTests {
    // Tight turn: fire activation (daemon launch, no wait), poll element-at-point until it is the target's,
    // tap, then fire the return activation immediately (optionally without waiting for the handler).
    func testTT_tightTurn() {
        background = true
        _ = PBHelper.setReduceMotion(true)
        fixture.launchArguments = []; fixture.launch(); sleep(2)
        guard let bf = find(snap(), { $0.label == "Plain button" && $0.elementType == .button })?.frame else { say("TT | no button"); return }
        let p = CGPoint(x: bf.midX, y: bf.midY)
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(2)
        _ = PBHelper.requestBackgroundAssertion(forPID: pid)
        say("TT | pid at point while Settings in front: \(PBHelper.pid(at: p)) (fixture \(pid))")
        for i in 1...10 {
            let before = lastEvent()
            let t0 = Date()
            let fx = fixture
            DispatchQueue.global().async { fx.activate() }
            var polls = 0; var seen = -1
            while Date().timeIntervalSince(t0) < 8 { polls += 1; seen = Int(PBHelper.pid(at: p)); if seen == Int(pid) { break }; usleep(15_000) }
            let t1 = Date()
            let r = PBHelper.synthTap(at: p, timeout: 3)
            let t2 = Date()
            let st = settings
            DispatchQueue.global().async { st.activate() }
            let t3 = Date()
            sleep(2)
            say("TT | run \(i) | ready after \(ms(t0, t1)) ms (\(polls) polls, pid \(seen)) | tap \(r) \(ms(t1, t2)) ms | return fired \(ms(t2, t3)) ms | handler: \(lastEvent() == before ? "none" : lastEvent())")
            sleep(1)
        }
        _ = PBHelper.setReduceMotion(false)
    }
}

extension SimFixtureTests {
    func patient(_ name: String, check: () -> String) {
        var last = 0
        for t in [5, 30, 60, 120] { sleep(UInt32(t - last)); last = t; say("PT | \(name) | +\(t)s | \(check())") }
    }
    func testPT_back() {
        covLaunch(tab: "UIKit", presenter: "cov.push", bg: true)
        let before = lastEvent()
        tryAct("back: 2013 on nav bar", find(snap()) { $0.elementType == .navigationBar }, 2013)
        patient("back via escape") { "lastEvent=\(lastEvent()) changed=\(lastEvent() != before) nav=\(find(snap()) { $0.elementType == .navigationBar }?.identifier ?? "nil")" }
    }
    func testPT_swiftUIMenu() {
        covLaunch(tab: "SwiftUI", bg: true)
        tryAct("SwiftUI Menu open (2010)", find(snap()) { $0.label == "SUIMenu" }, 2010)
        var fired = false
        patient("SwiftUI menu item") {
            if !fired, let item = find(snap(), { $0.label == "SUIMenuItem" }) {
                var err: NSString?; let ok = PBHelper.pressSnapshot(item, action: 2010, value: nil, error: &err); usleep(800_000); fired = true
                return "item found, 2010 \(ok ? "ok" : "fail") lastEvent=\(lastEvent())"
            }
            return "item \(fired ? "pressed earlier" : "not found") lastEvent=\(lastEvent())"
        }
    }
    func testPT_return() {
        covLaunch(tab: "UIKit", bg: true)
        guard let f = find(snap(), { $0.identifier == "cov.field" }) else { say("PT | no field"); return }
        var err: NSString?
        _ = PBHelper.setAttribute("XC_kAXXCAttributeValue", value: "hello" as NSString, onSnapshot: f, error: &err)
        let before = lastEvent()
        tryAct("field: 2054", find(snap()) { $0.identifier == "cov.field" }, 2054)
        patient("Return via 2054") { "lastEvent=\(lastEvent()) changed=\(lastEvent() != before)" }
    }
}

extension SimFixtureTests {
    func sendUsage(_ page: UInt, _ usage: UInt, _ input: String = "") -> String {
        guard let app = snap() else { return "no app" }
        var rs: [String] = []
        for down in [true, false] { var e: NSString?; rs.append(PBHelper.pressSnapshot(app, action: 2034, value: PBHelper.keyEventUsagePage(page, usage: usage, input: input, down: down), error: &e) ? "ok" : "fail"); usleep(120_000) }
        return rs.joined(separator: "/")
    }
    // SP: Select presses. Focus (5305 + 5310 + 2044) on a control, then key events carrying consumer / generic-desktop usages.
    func selectPressRoute(_ bg: Bool) {
        background = bg
        fixture.launchArguments = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        fixture.launch(); sleep(2)
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        if bg { _ = PBHelper.requestBackgroundAssertion(forPID: pid); settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10); sleep(1) }
        let fb = bg ? String(frontSummary().prefix(40)) : "-"
        let usages: [(String, UInt, UInt, String)] = [
            ("consumer MenuPick 0x41", 0x0C, 0x41, ""), ("consumer Select? 0x80", 0x0C, 0x80, ""), ("consumer Menu 0x40", 0x0C, 0x40, ""),
            ("consumer PlayPause 0xCD", 0x0C, 0xCD, ""), ("generic-desktop Select 0x3E", 0x01, 0x3E, ""), ("generic-desktop SystemMenuSelect 0x89", 0x01, 0x89, ""),
            ("keyboard Enter 0x58", 0x07, 0x58, "\r"), ("keyboard Select 0x77", 0x07, 0x77, ""),
        ]
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("plain button", { $0.label == "Plain button" && $0.elementType == .button }),
            ("table cell", { $0.elementType == .cell }),
            ("tab Second", { $0.label == "Second" && $0.elementType == .button }),
        ]
        for (tn, tp) in targets {
            for (un, page, usage, input) in usages {
                guard let e = find(snap(), tp) else { say("SP | \(tn) | not found"); break }
                let f = fkaFocus(e); usleep(500_000)
                let before = lastEvent(); let r = sendUsage(page, usage, input); usleep(1_000_000)
                say("SP | \(tn) | focus \(f) | \(un) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
                if lastEvent().contains("button") || lastEvent().contains("row") || lastEvent().contains("tab") || lastEvent().contains("Second") { break }
            }
        }
        if bg { say("SP | front before: \(fb) | after: \(String(frontSummary().prefix(40)))") }
    }
    func testSP_foreground() { selectPressRoute(false) }
    func testSP_background() { selectPressRoute(true) }
}
