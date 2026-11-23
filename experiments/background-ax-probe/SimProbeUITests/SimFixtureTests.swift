import XCTest

// Simulator only, against our own logging fixture. Maps AX action numbers to UIKit entry points and
// measures, per control type, whether an accessibility action reaches the handler with the fixture
// in the background (Settings in front) versus the foreground.
final class SimFixtureTests: XCTestCase {
    let fixture = XCUIApplication(bundleIdentifier: "local.pokimcp.axfixture")
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    var background = true

    func say(_ s: String) { print("SIMPROBE \(background ? "BG" : "FG") \(s)") }
    func snap() -> XCUIElementSnapshot? { try? fixture.snapshot() }
    func find(_ s: XCUIElementSnapshot?, _ match: (XCUIElementSnapshot) -> Bool) -> XCUIElementSnapshot? {
        guard let s else { return nil }
        if match(s) { return s }
        for c in s.children { if let h = find(c, match) { return h } }
        return nil
    }
    func lastEvent() -> String { (find(snap()) { $0.identifier == "lastEvent" }?.value as? String) ?? (find(snap()) { $0.identifier == "lastEvent" }?.label ?? "nil") }
    func navTitle() -> String { find(snap()) { $0.elementType == .navigationBar }?.identifier ?? "nil" }
    func act(_ e: XCUIElementSnapshot?, _ id: Int) -> String {
        guard let e else { return "element not found" }
        var err: NSString?
        let ok = PBHelper.pressSnapshot(e, action: id, error: &err)
        return ok ? "ok" : "fail(\((err ?? "") as String).prefix(60))"
    }

    var launchArgs: [String] = []
    func start(background bg: Bool) {
        background = bg
        fixture.launchArguments = launchArgs
        fixture.launch()
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        if bg {
            say("assertion granted=\(String(describing: PBHelper.requestBackgroundAssertion(forPID: pid)))")
            settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10)
        }
        say("start fixture=\(fixture.state.rawValue) settings=\(settings.state.rawValue)")
    }

    func control(_ name: String, _ element: XCUIElementSnapshot?, _ id: Int, wait: UInt32 = 1) {
        let before = lastEvent()
        let r = act(element, id)
        sleep(wait)
        let after = lastEvent()
        say("CONTROL | \(name) | action \(id) | \(r) | handler: \(after == before ? "none" : after) | fixture=\(fixture.state.rawValue)")
    }

    func mapActions() {
        for id in (2001...2069) where id != 2025 {  // 2025 crashes the app (UIAccessibility _accessibilityAnnouncementComplete: nil dictionary)
            guard fixture.state == .runningBackground || fixture.state == .runningForeground else { say("MAP | fixture not running before \(id) (state \(fixture.state.rawValue))"); start(background: background); continue }
            let before = lastEvent()
            let r = act(find(snap()) { $0.identifier == "probeTarget" }, id)
            usleep(400_000)
            let after = fixture.state == .runningBackground || fixture.state == .runningForeground ? lastEvent() : "fixture died (state \(fixture.state.rawValue))"
            say("MAP | \(id) | \(r) | \(after == before ? "no entry point" : after)")
        }
    }

    func controls() {
        func byLabel(_ l: String, _ types: [XCUIElement.ElementType] = []) -> XCUIElementSnapshot? { find(snap()) { $0.label == l && (types.isEmpty || types.contains($0.elementType)) } }
        control("UIButton", byLabel("Plain button", [.button]), 2010)
        control("UISwitch", byLabel("Switch", [.switch]), 2010)
        control("UISegmentedControl segment", byLabel("Two", [.button]), 2010)
        control("UISlider increment", byLabel("Slider", [.slider]), 2004)
        let field = find(snap()) { $0.identifier == "field" }
        if let field { var err: NSString?; let ok = PBHelper.setAttribute("XC_kAXXCAttributeValue", value: "abc" as NSString, onSnapshot: field, error: &err); sleep(1); say("CONTROL | UITextField set value | XC_kAXXCAttributeValue | \(ok ? "ok" : "fail") | handler: \(lastEvent()) | value=\((find(snap()) { $0.identifier == "field" }?.value as? String) ?? "nil")") }
        control("UITableView cell", byLabel("Row 3", [.cell, .staticText]), 2010)
        let table = find(snap()) { $0.identifier == "bigTable" }
        control("UITableView page down (2006)", table, 2006)
        control("Custom action via ProbeTarget (2010)", find(snap()) { $0.identifier == "probeTarget" }, 2010)
        // alert
        control("Show alert button", byLabel("Show alert", [.button]), 2010, wait: 2)
        control("Alert OK button", byLabel("OK", [.button]), 2010, wait: 2)
        // sheet
        control("Show sheet button", byLabel("Show sheet", [.button]), 2010, wait: 2)
        control("Sheet Close (UIBarButtonItem in nav bar)", byLabel("Close", [.button]), 2010, wait: 2)
        // tab bar (bar button press moved to the push timing below: it pushes level 2)
        control("UITabBarController tab 'Second'", byLabel("Second", [.button]), 2010, wait: 2)
        control("UITabBarController tab 'Controls'", byLabel("Controls", [.button]), 2010, wait: 2)
        // navigation push timing (push triggered by the bar button item, which works in the background)
        let t0 = Date()
        _ = act(byLabel("Bar", [.button]), 2010)
        var seen = -1.0
        while Date().timeIntervalSince(t0) < 90 { if navTitle() == "Level 2" { seen = Date().timeIntervalSince(t0); break }; usleep(500_000) }
        say("TIMING | push level 2 | nav bar shows Level 2 after \(seen < 0 ? "never (90 s)" : String(format: "%.1f s", seen)) | last=\(lastEvent())")
        let t1 = Date()
        _ = act(byLabel("Activate push", [.button, .staticText, .other]), 2010)
        var seen3 = -1.0
        while Date().timeIntervalSince(t1) < 90 { if navTitle() == "Level 3" { seen3 = Date().timeIntervalSince(t1); break }; usleep(500_000) }
        say("TIMING | push level 3 | after \(seen3 < 0 ? "never (90 s)" : String(format: "%.1f s", seen3)) | last=\(lastEvent())")
        control("Back button (UINavigationBar)", find(snap()) { $0.elementType == .button && $0.label == "Level 2" }, 2010, wait: 3)
        say("after back nav=\(navTitle())")
        for (n, e) in [("app", snap()), ("navbar", find(snap()) { $0.elementType == .navigationBar }), ("content element", find(snap()) { $0.label == "Activate push" || $0.label == "Push level 3" })] {
            let before = navTitle()
            let r = act(e, 2013)
            sleep(3)
            say("ESCAPE | 2013 on \(n) | \(r) | nav \(before) -> \(navTitle()) | last=\(lastEvent())")
        }
        // SwiftUI
        control("UITabBarController tab 'SwiftUI'", byLabel("SwiftUI", [.button]), 2010, wait: 2)
        control("SwiftUI Button", byLabel("SwiftUI button", [.button]), 2010)
        control("SwiftUI NavigationLink", byLabel("SwiftUI detail", [.button, .cell]), 2010, wait: 3)
        control("SwiftUI TabView tab 'Inner B'", byLabel("Inner B", [.button]), 2010, wait: 2)
    }

    // K: novel routes for controls whose plain activate fails in the background.
    func tryAll(_ name: String, _ locate: () -> XCUIElementSnapshot?) {
        for id in (2001...2040) where id != 2025 && id != 2011 {
            guard fixture.state == .runningBackground || fixture.state == .runningForeground else { say("K | \(name) | fixture died before \(id)"); return }
            let before = lastEvent()
            let r = act(locate(), id)
            usleep(500_000)
            let after = lastEvent()
            if after != before { say("K | \(name) | action \(id) | \(r) | HANDLER: \(after)") }
        }
        say("K | \(name) | sweep done")
    }
    func setAttr(_ name: String, _ e: XCUIElementSnapshot?, _ attr: String, _ value: AnyObject) {
        guard let e else { say("K | \(name) | not found"); return }
        let before = lastEvent()
        var err: NSString?
        let ok = PBHelper.setAttribute(attr, value: value, onSnapshot: e, error: &err)
        usleep(800_000)
        let after = lastEvent()
        say("K | \(name) | setAttribute \(attr)=\(value) | \(ok ? "ok" : "fail \((err ?? "") as String)".prefix(90)) | handler: \(after == before ? "none" : after)")
    }
    func testNovelRoutes() {
        start(background: true)
        func byLabel(_ l: String, _ types: [XCUIElement.ElementType] = []) -> XCUIElementSnapshot? { find(snap()) { $0.label == l && (types.isEmpty || types.contains($0.elementType)) } }
        // value / selection setters
        setAttr("UISwitch", byLabel("Switch", [.switch]), "XC_kAXXCAttributeValue", "1" as NSString)
        setAttr("UISwitch", byLabel("Switch", [.switch]), "XC_kAXXCAttributeValue", NSNumber(value: 1))
        setAttr("UISwitch", byLabel("Switch", [.switch]), "XC_kAXXCAttributeSelected", NSNumber(value: true))
        setAttr("Table cell", byLabel("Row 3", [.cell]), "XC_kAXXCAttributeSelected", NSNumber(value: true))
        setAttr("Tab 'Second'", byLabel("Second", [.button]), "XC_kAXXCAttributeSelected", NSNumber(value: true))
        setAttr("UIButton", byLabel("Plain button", [.button]), "XC_kAXXCAttributeSelected", NSNumber(value: true))
        // focus then activate
        for (n, l, t) in [("UIButton", "Plain button", XCUIElement.ElementType.button), ("UISwitch", "Switch", .switch), ("Table cell", "Row 3", .cell), ("Tab 'Second'", "Second", .button)] {
            setAttr("\(n) focus", byLabel(l, [t]), "XC_kAXXCAttributeIsElementFocused", NSNumber(value: true))
            let before = lastEvent(); let r = act(byLabel(l, [t]), 2010); usleep(700_000)
            say("K | \(n) | focus then 2010 | \(r.prefix(60)) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        // containers
        let tabBar = find(snap()) { $0.elementType == .tabBar }
        for id in [2004, 2005] { let before = lastEvent(); let r = act(tabBar, id); sleep(1); say("K | tab bar container | \(id) | \(r.prefix(60)) | handler: \(lastEvent() == before ? "none" : lastEvent())") }
        // sweep remaining ids on each failing control
        tryAll("UIButton", { byLabel("Plain button", [.button]) })
        tryAll("UISwitch", { byLabel("Switch", [.switch]) })
        tryAll("Table cell", { byLabel("Row 3", [.cell]) })
        tryAll("Tab 'Second'", { byLabel("Second", [.button]) })
    }

    // P: explicit-context touch. Context id is captured while the fixture is in front.
    func testP_contextAddressedTap() {
        background = false
        say("P hand types: \(PBHelper.handTypeNames())")
        fixture.launch()
        let pid = (fixture.value(forKey: "processID") as? NSNumber)?.int32Value ?? -1
        guard let button = find(snap(), { $0.label == "Plain button" && $0.elementType == .button }) else { say("P no button"); return }
        let ctx = PBHelper.contextId(ofSnapshot: button)
        let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
        say("P fixture pid=\(pid) button center=\(center) contextId(fg)=\(ctx)")
        say("P assertion granted=\(String(describing: PBHelper.requestBackgroundAssertion(forPID: pid)))")
        background = true
        settings.activate(); _ = settings.wait(for: .runningForeground, timeout: 10)
        let bgCtx = find(snap(), { $0.label == "Plain button" && $0.elementType == .button }).map { PBHelper.contextId(ofSnapshot: $0) } ?? 0
        say("P contextId(bg, via AXElement)=\(bgCtx)")
        // hand type pairs to try are printed above; the defaults below are replaced after reading them.
        for (down, up) in [(1, 6), (1, 2)] {
            for (label, c) in [("explicit context", ctx), ("no context", UInt32(0))] {
                let before = lastEvent(); let fb = frontSummary()
                let r = PBHelper.postTap(at: center, contextId: c, pid: pid, displayId: 1, down: Int32(down), up: Int32(up))
                sleep(2)
                say("P | types \(down)/\(up) | \(label) ctx=\(c) | \(r) | handler: \(lastEvent() == before ? "none" : lastEvent()) | front before: \(fb) | after: \(frontSummary())")
            }
        }
    }

    // L: the assistive-client route (AXElement press / simulateTap), fixture foreground then background.
    func frontSummary() -> String {
        guard let s = try? settings.snapshot() else { return "settings read failed" }
        var n = 0, labels: [String] = []
        func w(_ e: XCUIElementSnapshot) { n += 1; if labels.count < 4, !e.label.isEmpty { labels.append(e.label) }; e.children.forEach(w) }
        w(s); return "settings elements=\(n) nav=\(find(s) { $0.elementType == .navigationBar }?.identifier ?? "nil") first=\(labels)"
    }
    func routeTest(_ bg: Bool) {
        start(background: bg)
        func byLabel(_ l: String, _ types: [XCUIElement.ElementType]) -> XCUIElementSnapshot? { find(snap()) { $0.label == l && types.contains($0.elementType) } }
        let targets: [(String, () -> XCUIElementSnapshot?)] = [
            ("UIButton", { byLabel("Plain button", [.button]) }), ("UISwitch", { byLabel("Switch", [.switch]) }),
            ("Table cell", { self.find(self.snap()) { $0.elementType == .cell && $0.label.hasPrefix("Row ") } }), ("Tab 'Second'", { byLabel("Second", [.button]) })]
        for (name, locate) in targets {
            for route in ["press", "tap"] {
                let before = lastEvent(); let fb = bg ? frontSummary() : "-"
                let shot1 = XCUIScreen.main.screenshot().pngRepresentation.count
                let r = locate().map { PBHelper.axElementRoute(route, onSnapshot: $0) } ?? "not found"
                sleep(2)
                let after = lastEvent(); let fa = bg ? frontSummary() : "-"
                let shot2 = XCUIScreen.main.screenshot().pngRepresentation.count
                say("L | \(name) | \(route) | \(r) | handler: \(after == before ? "none" : after) | front before: \(fb) | after: \(fa) | screen bytes \(shot1)->\(shot2) | fixture=\(fixture.state.rawValue)")
                if name == "Tab 'Second'" && after != before, let back = byLabel("Controls", [.button]) { _ = PBHelper.axElementRoute("tap", onSnapshot: back); sleep(2) }
            }
        }
    }
    func testL_foreground() { routeTest(false) }
    func testL_background() { routeTest(true) }

    // For the lldb trace: attach to an already running fixture (no launch), press three elements.
    func testPressForTrace() {
        background = false
        fixture.activate()
        sleep(60)  // time for lldb to attach
        func byLabel(_ l: String, _ types: [XCUIElement.ElementType]) -> XCUIElementSnapshot? { find(snap()) { $0.label == l && types.contains($0.elementType) } }
        say("TRACE press UIButton: \(act(byLabel("Plain button", [.button]), 2010).prefix(80))")
        sleep(2)
        say("TRACE press ProbeTarget: \(act(find(snap()) { $0.identifier == "probeTarget" }, 2010).prefix(80))")
        sleep(2)
        say("TRACE press UISwitch: \(act(byLabel("Switch", [.switch]), 2010).prefix(80))")
        sleep(3)
        say("TRACE AXElement press UIButton: \(byLabel("Plain button", [.button]).map { PBHelper.axElementRoute("press", onSnapshot: $0) } ?? "nf")")
        sleep(8)
    }

    func testBackground() { start(background: true); controls() }
    func testBackgroundMap() { start(background: true); mapActions() }
    // Q: focus route on bare controls. 2044 = set native focus (mapped), 2036 = secondary activate.
    func focusRoute(_ bg: Bool) {
        start(background: bg)
        func byLabel(_ l: String, _ types: [XCUIElement.ElementType]) -> XCUIElementSnapshot? { find(snap()) { $0.label == l && types.contains($0.elementType) } }
        let targets: [(String, () -> XCUIElementSnapshot?)] = [("UIButton", { byLabel("Plain button", [.button]) }), ("UISwitch", { byLabel("Switch", [.switch]) }), ("Tab 'Second'", { byLabel("Second", [.button]) })]
        for (name, locate) in targets {
            for (id, value) in [(2044, nil), (2010, nil), (2036, nil)] as [(Int, AnyObject?)] {
                let before = lastEvent(); var err: NSString?
                let ok = locate().map { PBHelper.pressSnapshot($0, action: id, value: value, error: &err) } ?? false
                usleep(700_000)
                say("Q | \(name) | \(id) | ok=\(ok) \((err ?? "") as String) | handler: \(lastEvent() == before ? "none" : lastEvent())".prefix(220).description)
            }
            for id in [Int]() {
                for v in [NSNumber(value: 0), NSNumber(value: 1), "activate" as NSString, "select" as NSString] as [AnyObject] {
                    guard fixture.state == .runningForeground || fixture.state == .runningBackground else { say("Q | fixture died"); start(background: bg); break }
                    let before = lastEvent(); var err: NSString?
                    let ok = locate().map { PBHelper.pressSnapshot($0, action: id, value: v, error: &err) } ?? false
                    usleep(500_000)
                    let after = lastEvent()
                    if ok || after != before { say("Q | \(name) | \(id) value=\(v) | ok=\(ok) \((err ?? "") as String) | handler: \(after == before ? "none" : after)".prefix(220).description) }
                }
            }
        }
        say("Q | done")
    }
    func testQ_focusForeground() { focusRoute(false) }
    func testQ_focusBackground() { focusRoute(true) }

    // R: in-app key delivery. Send "k" down/up to the application element; the fixture logs its UIKeyCommand.
    func keyRoute(_ bg: Bool) {
        start(background: bg)
        guard let app = snap() else { say("R no app snapshot"); return }
        for id in [2034] {  // from the dispatcher's jump table: 2034 -> NSData -> representationWithData: -> _accessibilityDispatchKeyboardAction:
            for (route, asData) in [("XCTest daemon, data", true), ("direct AXElement, data", true)] {
                guard fixture.state == .runningForeground || fixture.state == .runningBackground else { say("R | fixture died"); start(background: bg); continue }
                let before = lastEvent()
                var rs: [String] = []
                for down in [true, false] {
                    let v = PBHelper.keyEvent("k", down: down, asData: asData)
                    if route.hasPrefix("direct") { rs.append(PBHelper.directAction(id, value: v, onSnapshot: snap() ?? app)) }
                    else { var e: NSString?; rs.append(PBHelper.pressSnapshot(snap() ?? app, action: id, value: v, error: &e) ? "ok" : "fail \((e ?? "") as String)".prefix(60).description) }
                    usleep(150_000)
                }
                usleep(600_000)
                let alive = fixture.state == .runningForeground || fixture.state == .runningBackground
                say("R | \(id) | \(route) | \(rs.joined(separator: ", ")) | handler: \(!alive ? "fixture died" : (lastEvent() == before ? "none" : lastEvent()))")
            }
        }
    }
    func sendKey(_ k: String) -> String {
        guard let app = snap() else { return "no app" }
        var rs: [String] = []
        for down in [true, false] { var e: NSString?; rs.append(PBHelper.pressSnapshot(app, action: 2034, value: PBHelper.keyEvent(k, down: down, asData: true), error: &e) ? "ok" : "fail"); usleep(120_000) }
        return rs.joined(separator: "/")
    }
    // S: focus by keyboard (Tab) or by 2044, then Space / Return, on bare controls.
    func keyFocusRoute(_ bg: Bool) {
        start(background: bg)
        let fb = bg ? frontSummary() : "-"
        for step in ["\t", "\t", "\t", " ", "\r", "\t", " ", "\t", " ", "\t", " ", "\t", " "] {
            let before = lastEvent()
            let r = sendKey(step)
            usleep(800_000)
            say("S | key \(step == "\t" ? "Tab" : step == " " ? "Space" : "Return") | \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        for (name, label, type) in [("UIButton", "Plain button", XCUIElement.ElementType.button), ("UISwitch", "Switch", .switch), ("Tab 'Second'", "Second", .button)] {
            guard let e = find(snap(), { $0.label == label && $0.elementType == type }) else { continue }
            var err: NSString?; let f = PBHelper.pressSnapshot(e, action: 2044, value: nil, error: &err)
            let before = lastEvent(); let r = sendKey(" "); usleep(800_000)
            say("S | \(name) | 2044 focus ok=\(f) then Space \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        if bg { say("S | front before: \(fb) | after: \(frontSummary())") }
    }
    // U: the FKA daemon's own ops. 5305 setFocusEnabledInApplication:(bool) on the app,
    // 5307 didFocusOnApplication, 5308 setFocusOnElement:(bool) on a control, then Space/Return via 2034.
    func act(_ e: Any, _ id: Int, _ v: Any?) -> String { var err: NSString?; return PBHelper.pressSnapshot(e, action: id, value: v, error: &err) ? "ok" : "fail(\(err ?? ""))" }
    func fkaRoute(_ bg: Bool) {
        start(background: bg)
        let fb = bg ? frontSummary() : "-"
        guard let app = snap() else { say("U | no app"); return }
        say("U | 5305 YES \(act(app, 5305, NSNumber(value: true))) | 5307 \(act(app, 5307, nil))")
        usleep(1_000_000)
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("UIButton plain", { $0.label == "Plain button" && $0.elementType == .button }),
            ("UISwitch", { $0.elementType == .switch }),
            ("table cell", { $0.elementType == .cell }),
            ("tab Second", { $0.label == "Second" && $0.elementType == .button }),
        ]
        for (name, pred) in targets {
            for key in [" ", "\r"] {
                guard let e = find(snap(), pred) else { say("U | \(name) | not found"); break }
                let f = act(e, 5308, NSNumber(value: true)); usleep(600_000)
                let before = lastEvent(); let r = sendKey(key); usleep(900_000)
                say("U | \(name) | 5308 \(f), \(key == " " ? "Space" : "Return") \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
                if lastEvent() != before { break }
            }
        }
        if bg { say("U | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))") }
    }
    // V: launch argument FullKeyboardAccessUsesSimulatedKeyboardForAutomation YES gives the app a focus
    // system with no hardware keyboard. Then focus (5308 or Tab) and Space/Return via 2034.
    func focusPressRoute(_ bg: Bool) {
        launchArgs = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        start(background: bg)
        let fb = bg ? frontSummary() : "-"
        guard let app = snap() else { say("V | no app"); return }
        say("V | 5305 YES \(act(app, 5305, NSNumber(value: true)))")
        usleep(800_000)
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("UIButton plain", { $0.label == "Plain button" && $0.elementType == .button }),
            ("UISwitch", { $0.elementType == .switch }),
            ("table cell", { $0.elementType == .cell }),
            ("tab Second", { $0.label == "Second" && $0.elementType == .button }),
        ]
        for (name, pred) in targets {
            for key in [" ", "\r"] {
                guard let e = find(snap(), pred) else { say("V | \(name) | not found"); break }
                let f = act(e, 5308, NSNumber(value: true)); usleep(700_000)
                let before = lastEvent(); let r = sendKey(key); usleep(1_000_000)
                let after = lastEvent()
                say("V | \(name) | 5308 \(f), \(key == " " ? "Space" : "Return") \(r) | handler: \(after == before ? "none" : after)")
                if after != before { break }
            }
        }
        for i in 1...6 {
            let r1 = sendKey("\t"); usleep(600_000)
            let before = lastEvent(); let r2 = sendKey(" "); usleep(900_000)
            say("V | Tab x\(i) \(r1) then Space \(r2) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        if bg { say("V | front before: \(fb.prefix(70)) | after: \(frontSummary().prefix(70))") }
    }
    func focusNow() -> String { (find(snap()) { $0.identifier == "focusNow" }?.value as? String) ?? "?" }
    // W: with the launch argument, native focus (2044) or FKA focus (5308) on each control, read focus, then
    // Space via 2034, then 2010 activate while natively focused.
    func nativeFocusRoute(_ bg: Bool) {
        launchArgs = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        start(background: bg)
        let fb = bg ? frontSummary() : "-"
        sleep(3)
        say("W | initial focus: \(focusNow())")
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("UIButton plain", { $0.label == "Plain button" && $0.elementType == .button }),
            ("UISwitch", { $0.elementType == .switch }),
            ("table cell", { $0.elementType == .cell }),
            ("tab Second", { $0.label == "Second" && $0.elementType == .button }),
        ]
        for (name, pred) in targets {
            guard let e = find(snap(), pred) else { say("W | \(name) | not found"); continue }
            let f = act(e, 2044, nil); sleep(3)
            let fnow = focusNow()
            var before = lastEvent(); let r = sendKey(" "); usleep(1_000_000)
            var h = lastEvent() == before ? "none" : lastEvent()
            say("W | \(name) | 2044 \(f) -> focus '\(fnow)' | Space \(r) | handler: \(h)")
            if h == "none", let e2 = find(snap(), pred) {
                before = lastEvent(); let a = act(e2, 2010, nil); usleep(1_000_000)
                h = lastEvent() == before ? "none" : lastEvent()
                say("W | \(name) | then 2010 \(a) | handler: \(h)")
            }
        }
        if bg { say("W | front before: \(fb.prefix(70)) | after: \(frontSummary().prefix(70))") }
    }
    // X: reference. Real HID Space from XCTest (foreground only), to read the activation stack.
    // Y: with native focus on a control, app-level actions: 2010, 2036, 2011 on the application element.
    func appLevelRoute(_ bg: Bool, args: Bool) {
        launchArgs = args ? ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"] : []
        start(background: bg); sleep(2)
        let fb = bg ? frontSummary() : "-"
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("UISwitch", { $0.elementType == .switch }),
            ("table cell", { $0.elementType == .cell }),
            ("tab Second", { $0.label == "Second" && $0.elementType == .button }),
        ]
        for (name, pred) in targets {
            guard let e = find(snap(), pred) else { continue }
            let f = act(e, 2044, nil); sleep(2)
            for id in [2010, 2036, 2011] {
                guard let app = snap() else { break }
                let before = lastEvent(); let r = act(app, id, nil); usleep(900_000)
                say("Y | args=\(args) | \(name) focus \(f) '\(focusNow())' | app \(id) \(r.prefix(30)) | handler: \(lastEvent() == before ? "none" : lastEvent())")
            }
        }
        if bg { say("Y | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))") }
    }
    func testY_appLevelForeground() { appLevelRoute(false, args: true) }
    func testY_appLevelBackground() { appLevelRoute(true, args: true) }
    // AA: switch key commands (_fkaSwitchOn/Off -> _keyboardActivate). Arrow keys via 2034 with no focus,
    // after 5308 (AX focus) and after 2044 (native focus).
    func switchKeyRoute(_ bg: Bool, args: Bool) {
        launchArgs = args ? ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"] : []
        start(background: bg); sleep(2)
        let fb = bg ? frontSummary() : "-"
        for prep in ["none", "5308", "2044"] {
            guard let sw = find(snap(), { $0.elementType == .switch }) else { say("AA | no switch"); return }
            let p = prep == "none" ? "-" : act(sw, Int(prep)!, prep == "5308" ? NSNumber(value: true) : nil)
            usleep(600_000)
            for k in ["UIKeyInputRightArrow", "UIKeyInputLeftArrow", " "] {
                let before = lastEvent(); let r = sendKey(k); usleep(900_000)
                say("AA | args=\(args) | prep \(prep) \(p.prefix(12)) | key \(k == " " ? "Space" : k) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
            }
        }
        if bg { say("AA | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))") }
    }
    func sendModKey(_ k: String, _ mk: String, _ mv: UInt) -> String {
        guard let app = snap() else { return "no app" }
        var rs: [String] = []
        for down in [true, false] { var e: NSString?; rs.append(PBHelper.pressSnapshot(app, action: 2034, value: PBHelper.keyEvent(k, down: down, modifierKey: mk, modifierValue: mv), error: &e) ? "ok" : "fail"); usleep(120_000) }
        return rs.joined(separator: "/")
    }
    // AB: key commands UIKit installs without focus: Cmd-2 for the tab bar (several modifier encodings),
    // arrows / Return / Space for the table. No launch argument.
    func noFocusKeys(_ bg: Bool) {
        launchArgs = []
        start(background: bg); sleep(2)
        let fb = bg ? frontSummary() : "-"
        for (mk, mv) in [("modifierState", UInt(1 << 20)), ("modifierState", UInt(1 << 16)), ("gsModifierState", UInt(1 << 16)), ("gsModifierState", UInt(1 << 20))] {
            let before = lastEvent(); let r = sendModKey("2", mk, mv); usleep(1_200_000)
            say("AB | Cmd-2 \(mk)=0x\(String(mv, radix: 16)) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
            if lastEvent() != before { break }
        }
        for k in ["UIKeyInputDownArrow", "UIKeyInputDownArrow", "\r", " "] {
            let before = lastEvent(); let r = sendKey(k); usleep(900_000)
            say("AB | table key \(k == "\r" ? "Return" : k == " " ? "Space" : k) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        if bg { say("AB | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))") }
    }
    // AD: native focus then arrows (selection follows focus?) on cell and tab, plus Tab key between groups.
    func focusArrowRoute(_ bg: Bool) {
        launchArgs = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        start(background: bg); sleep(2)
        let fb = bg ? frontSummary() : "-"
        let targets: [(String, (XCUIElementSnapshot) -> Bool)] = [
            ("table cell", { $0.elementType == .cell }),
            ("tab Controls", { $0.label == "Controls" && $0.elementType == .button }),
            ("UIButton plain", { $0.label == "Push level 2" && $0.elementType == .button }),
        ]
        for (name, pred) in targets {
            guard let e = find(snap(), pred) else { say("AD | \(name) | not found"); continue }
            let f = act(e, 2044, nil); usleep(1_500_000)
            say("AD | \(name) | 2044 \(f.prefix(10)) focus '\(focusNow())'")
            for k in ["UIKeyInputDownArrow", "UIKeyInputRightArrow", "UIKeyInputUpArrow", "UIKeyInputLeftArrow", "\r", " "] {
                let before = lastEvent(); let r = sendKey(k); usleep(1_000_000)
                say("AD | \(name) | key \(k == "\r" ? "Return" : k == " " ? "Space" : k) \(r) | focus '\(focusNow())' | handler: \(lastEvent() == before ? "none" : lastEvent())")
            }
        }
        if bg { say("AD | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))") }
    }
    // AE: background, force-enable focus with 5305 (FKA daemon op), then 2044 + Right arrow on the switch.
    // AF: trace the in-process touch from _keyboardActivate (fixture key command "j"), FG vs BG.
    var launchArgsOverride: [String] = []
    func traceRoute(_ bg: Bool) {
        launchArgs = launchArgsOverride
        start(background: bg); sleep(launchArgsOverride.contains("-waitLLDB") ? 30 : 4)
        let before = lastEvent(); let r = sendKey("j"); sleep(3)
        say("AF | key j \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
    }
    func testAF_traceBackgroundFakeCtx() { launchArgsOverride = ["-traceFakeCtx"]; traceRoute(true) }
    func testAF_traceBackgroundLLDB() { launchArgsOverride = ["-waitLLDB"]; traceRoute(true) }
    func testAF_traceForegroundLLDB() { launchArgsOverride = ["-waitLLDB"]; traceRoute(false) }
    func testAG_snapshotBackground() {
        launchArgs = []; start(background: true); sleep(4)
        _ = sendKey("s"); usleep(30_000)
        let before = lastEvent(); _ = sendKey("j"); sleep(2)
        say("AG | s then j | handler: \(lastEvent() == before ? "none" : lastEvent())")
    }
    func testAH_keepAll() { launchArgsOverride = ["-keepAll"]; traceRoute(true) }
    func testAH_keepScene() { launchArgsOverride = ["-keepScene"]; traceRoute(true) }
    func testAH_keepWin() { launchArgsOverride = ["-keepWin"]; traceRoute(true) }
    func testAF_traceForeground() { traceRoute(false) }
    func testAF_traceBackground() { traceRoute(true) }
    func testAE_forceFocusBackground() {
        launchArgs = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        start(background: true); sleep(2)
        let fb = frontSummary()
        say("AE | focus at start '\(focusNow())'")
        for round in 1...2 {
            guard let app = snap() else { return }
            let sid = (find(snap()) { $0.identifier == "sceneId" }?.value as? String) ?? ""
            say("AE | r\(round) scene '\(sid)' 5305 YES \(act(app, 5305, NSNumber(value: true)).prefix(20)) | 5307 \(act(app, 5307, nil).prefix(20)) | 5310 \(act(app, 5310, sid as NSString).prefix(20))")
            usleep(1_500_000)
            say("AE | r\(round) focus after enable '\(focusNow())'")
            guard let sw = find(snap(), { $0.elementType == .switch }) else { return }
            let f = act(sw, 2044, nil); usleep(1_500_000)
            say("AE | r\(round) 2044 \(f.prefix(30)) focus '\(focusNow())'")
            let before = lastEvent(); let r = sendKey(round == 1 ? "UIKeyInputRightArrow" : "UIKeyInputLeftArrow"); usleep(1_000_000)
            say("AE | r\(round) arrow \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        say("AE | front before: \(fb.prefix(60)) | after: \(frontSummary().prefix(60))")
    }
    func testAD_focusArrowsForeground() { focusArrowRoute(false) }
    func testAC_modifierProbe() {
        launchArgs = []; start(background: false); sleep(2)
        for (mk, mv) in [("modifierState", UInt(1 << 20)), ("modifierState", UInt(1 << 16)), ("gsModifierState", UInt(1 << 16)), ("gsModifierState", UInt(1 << 20)), ("modifierState", UInt(0x10)), ("gsModifierState", UInt(0x10))] {
            let before = lastEvent(); let r = sendModKey("k", mk, mv); usleep(900_000)
            say("AC | k + \(mk)=0x\(String(mv, radix: 16)) \(r) | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
        var before = lastEvent(); fixture.typeKey("k", modifierFlags: .command); sleep(1)
        say("AC | hardware Cmd-K | handler: \(lastEvent() == before ? "none" : lastEvent())")
        before = lastEvent(); fixture.typeKey("2", modifierFlags: .command); sleep(1)
        say("AC | hardware Cmd-2 | handler: \(lastEvent() == before ? "none" : lastEvent())")
    }
    func testAB_noFocusKeysForeground() { noFocusKeys(false) }
    func testAB_noFocusKeysBackground() { noFocusKeys(true) }
    func testAA_switchKeysForeground() { switchKeyRoute(false, args: true) }
    func testAA_switchKeysBackground() { switchKeyRoute(true, args: true) }
    func testAA_switchKeysBackgroundNoArg() { switchKeyRoute(true, args: false) }
    func testZ_dumpActions() { start(background: false); _ = snap(); sleep(14) }
    func testX_hardwareSpaceForeground() {
        launchArgs = ["-FullKeyboardAccessUsesSimulatedKeyboardForAutomation", "YES"]
        start(background: false); sleep(3)
        say("X | focus: \(focusNow())")
        for k in [" ", "\r"] {
            let before = lastEvent(); fixture.typeKey(k, modifierFlags: []); sleep(1)
            say("X | typeKey \(k == " " ? "Space" : "Return") | handler: \(lastEvent() == before ? "none" : lastEvent())")
        }
    }
    func testW_nativeFocusForeground() { nativeFocusRoute(false) }
    func testW_nativeFocusBackground() { nativeFocusRoute(true) }

    func testV_focusPressForeground() { focusPressRoute(false) }
    func testV_focusPressBackground() { focusPressRoute(true) }

    func testU_fkaForeground() { fkaRoute(false) }
    func testU_fkaBackground() { fkaRoute(true) }

    func testT_fkaOn() { say("T | " + PBHelper.setFullKeyboardAccess(true)) }
    func testT_fkaOff() { say("T | " + PBHelper.setFullKeyboardAccess(false)) }
    func testS_keyFocusForeground() { keyFocusRoute(false) }
    func testS_keyFocusBackground() { keyFocusRoute(true) }

    func testR_keyForeground() { keyRoute(false) }
    func testR_keyBackground() { keyRoute(true) }

    func testForegroundMap() { start(background: false); mapActions() }
    func testForegroundMapHigh() { start(background: false); mapRange(Array(4000...4060) + Array(5000...5040) + Array(2070...2120)) }
    func mapRange(_ ids: [Int]) {
        for id in ids {
            if !(fixture.state == .runningForeground || fixture.state == .runningBackground) { say("MAP | fixture died before \(id)"); start(background: background) }
            let before = lastEvent()
            let r = act(find(snap()) { $0.identifier == "probeTarget" }, id)
            usleep(300_000)
            let alive = fixture.state == .runningForeground || fixture.state == .runningBackground
            let after = alive ? lastEvent() : "fixture died (state \(fixture.state.rawValue))"
            if after != before || !r.contains("kAXErrorFailure") { say("MAP | \(id) | \(r.prefix(140)) | \(after == before ? "no entry point" : after)") }
        }
        say("MAP | range done")
    }
    func testForeground() { start(background: false); controls() }
}
