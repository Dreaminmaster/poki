import XCTest

// R8b (simulator only): keep a background app running through testmanagerd's background
// assertion, then read it and act on it by accessibility element (never by screen
// coordinate) while Settings stays frontmost. testA = with assertion, testB = control without.
// Private calls are reached by selector (names from Xcode 27.3 XCUIAutomation/XCTestCore):
//   +[XCTRunnerDaemonSession sharedSession] -daemonProxy
//   -[daemonProxy _XCT_requestBackgroundAssertionForPID:reply:]   (v28@0:8i16@?<v@?B>20)
//   -[XCUIApplication processID]
//   +[XCAccessibilityElement elementWithProcessIdentifier:]
//   -[XCUIDevice accessibilityInterface] -> XCAXClient_iOS
//   -[XCAXClient_iOS requestSnapshotForElement:attributes:parameters:error:]
//   -[XCAXClient_iOS performAction:onElement:value:error:]
//   -[XCElementSnapshot accessibilityElement]
final class BackgroundAXActionTests: XCTestCase {
    let fixture = XCUIApplication(bundleIdentifier: "local.pokimcp.axprobe.fixture")
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    static let axPress = 2010

    func say(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.timeZone = TimeZone(identifier: "America/New_York")
        print("PROBE \(f.string(from: Date())) \(s)")
    }

    var ax: NSObject { XCUIDevice.shared.perform(NSSelectorFromString("accessibilityInterface")).takeUnretainedValue() as! NSObject }

    func pid() -> Int32 {
        let v = fixture.value(forKey: "processID") as? NSNumber
        return v?.int32Value ?? -1
    }

    func requestAssertion(_ pid: Int32) -> Bool? {
        guard let cls = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = cls.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject,
              let proxy = session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject else { return nil }
        let sel = NSSelectorFromString("_XCT_requestBackgroundAssertionForPID:reply:")
        typealias Fn = @convention(c) (AnyObject, Selector, Int32, @escaping @convention(block) (Bool) -> Void) -> Void
        let sem = DispatchSemaphore(value: 0); var granted: Bool?
        unsafeBitCast(proxy.method(for: sel), to: Fn.self)(proxy, sel, pid) { ok in granted = ok; sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        return granted
    }

    // Snapshot of the background app's application element by pid (not via the screen).
    func snapshot(_ pid: Int32, timeout: TimeInterval = 6) -> (NSObject?, String) {
        guard let elCls = NSClassFromString("XCAccessibilityElement") as? NSObject.Type else { return (nil, "no XCAccessibilityElement") }
        let element = elCls.perform(NSSelectorFromString("elementWithProcessIdentifier:"), with: NSNumber(value: pid))
        // elementWithProcessIdentifier: takes an int; call through the C signature instead.
        let selE = NSSelectorFromString("elementWithProcessIdentifier:")
        typealias EFn = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
        guard let appEl = unsafeBitCast(elCls.method(for: selE), to: EFn.self)(elCls, selE, pid) else { _ = element; return (nil, "no element") }
        let sel = NSSelectorFromString("requestSnapshotForElement:attributes:parameters:error:")
        typealias SFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var err: NSError?
        var result: AnyObject?
        let done = DispatchSemaphore(value: 0)
        let ax = self.ax
        DispatchQueue.global().async {
            result = unsafeBitCast(ax.method(for: sel), to: SFn.self)(ax, sel, appEl, nil, ["maxDepth": 30, "maxChildren": 400, "maxArrayCount": 400, "traverseFromParentsToChildren": true] as NSDictionary, &err)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { return (nil, "timeout after \(Int(timeout)) s") }
        if result == nil { return (nil, "error: \(String(describing: err))") }
        return (result as? NSObject, "ok")
    }

    func walk(_ s: NSObject, _ visit: (NSObject) -> Void) {
        visit(s)
        for c in (s.value(forKey: "children") as? [NSObject]) ?? [] { walk(c, visit) }
    }

    func find(_ root: NSObject, identifier: String? = nil, label: String? = nil) -> NSObject? {
        var hit: NSObject?
        walk(root) { e in
            if hit != nil { return }
            if let identifier, (e.value(forKey: "identifier") as? String) == identifier { hit = e }
            if let label, (e.value(forKey: "label") as? String) == label { hit = e }
        }
        return hit
    }

    func count(_ root: NSObject) -> Int { var n = 0; walk(root) { _ in n += 1 }; return n }

    func perform(_ action: Int, on snap: NSObject, value: AnyObject?) -> (Bool, String) {
        guard let element = snap.value(forKey: "accessibilityElement") as AnyObject? else { return (false, "no accessibilityElement") }
        let sel = NSSelectorFromString("performAction:onElement:value:error:")
        typealias Fn = @convention(c) (AnyObject, Selector, Int, AnyObject, AnyObject?, UnsafeMutablePointer<NSError?>?) -> Bool
        var err: NSError?
        let ok = unsafeBitCast(ax.method(for: sel), to: Fn.self)(ax, sel, action, element, value, &err)
        return (ok, String(describing: err))
    }

    // -[XCAXClient_iOS setAttribute:value:element:outError:] with the XCTest value attribute
    // (the attribute object is taken from XCElementSnapshot's attribute mapping when present,
    // else the AX value attribute number 2006, logged as a hypothesis).
    func setValue(on snap: NSObject, _ text: String) -> (Bool, String) {
        guard let element = snap.value(forKey: "accessibilityElement") as AnyObject? else { return (false, "no accessibilityElement") }
        let sel = NSSelectorFromString("setAttribute:value:element:outError:")
        guard ax.responds(to: sel) else { return (false, "no setAttribute selector") }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, UnsafeMutablePointer<NSError?>?) -> Bool
        var err: NSError?
        let ok = unsafeBitCast(ax.method(for: sel), to: Fn.self)(ax, sel, NSNumber(value: 2006), text as NSString, element, &err)
        return (ok, String(describing: err))
    }

    func settingsFront() -> String { "settings=\(settings.state.rawValue) fixture=\(fixture.state.rawValue)" }

    func runScenario(assert: Bool) {
        fixture.launch()
        let p = pid()
        settings.activate()
        _ = settings.wait(for: .runningForeground, timeout: 10)
        say("[\(assert ? "A" : "B")] fixture pid=\(p); \(settingsFront())")
        if assert { say("[A] background assertion granted=\(String(describing: requestAssertion(p)))") }
        let marks = assert ? [2, 15, 40, 120, 300] : [2, 15, 40]
        var elapsed = 0
        for m in marks {
            sleep(UInt32(m - elapsed)); elapsed = m
            let (root, status) = snapshot(p)
            guard let root else { say("[\(assert ? "A" : "B")] t+\(m)s snapshot \(status); \(settingsFront())"); continue }
            let counter = find(root, identifier: "counter")?.value(forKey: "label") as? String ?? "nil"
            var line = "t+\(m)s snapshot ok elements=\(count(root)) counter=\(counter)"
            if let button = find(root, label: "Increment") {
                let (ok, e) = perform(Self.axPress, on: button, value: nil)
                usleep(600_000)
                let after = snapshot(p).0.flatMap { find($0, identifier: "counter")?.value(forKey: "label") as? String } ?? "nil"
                line += " | AXPress ok=\(ok) err=\(e) counter_after=\(after)"
            } else { line += " | Increment not found" }
            if m == marks.first, let field = find(root, identifier: "test-field") {
                let (ok, e) = setValue(on: field, "bg-\(m)")
                line += " | setAttribute(value) ok=\(ok) err=\(e)"
            }
            line += " | \(settingsFront())"
            say("[\(assert ? "A" : "B")] \(line)")
        }
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot); att.lifetime = .keepAlways; add(att)
        say("[\(assert ? "A" : "B")] final screen front: \(settingsFront())")
        fixture.activate()
        say("[\(assert ? "A" : "B")] verification (foreground) counter=\(fixture.staticTexts["counter"].label) field=\(String(describing: fixture.textFields["test-field"].value))")
        fixture.terminate()
    }

    func testA_withAssertion() { runScenario(assert: true) }
    func testB_controlWithoutAssertion() { runScenario(assert: false) }
}
