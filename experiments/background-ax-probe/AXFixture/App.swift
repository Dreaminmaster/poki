import SwiftUI
import UIKit

// Fixture for the background accessibility probe. Every handler logs "FIXLOG <event>" (NSLog,
// read with `simctl spawn <sim> log show`) and writes the event into an on-screen label whose
// accessibility identifier is "lastEvent", so a background read can see it too.

enum Fix {
    static var count = 0
    static weak var label: UILabel?
    static weak var focusLabel: UILabel?
    static weak var sceneLabel: UILabel?
    static weak var plainButton: UIButton?
    static func short(_ i: UIFocusItem) -> String {
        if let b = i as? UIButton { return "UIButton " + (b.currentTitle ?? "?") }
        if let v = i as? UIView { return String(describing: type(of: v)) + " " + (v.accessibilityLabel ?? "") }
        return String(describing: type(of: i))
    }
    static var dumped = 0
    static func dumpActions(_ root: UIView) {
        var q: [UIView] = [root]
        while !q.isEmpty {
            let v = q.removeFirst(); q.append(contentsOf: v.subviews)
            let n = String(describing: type(of: v))
            guard v is UIControl || v is UITableViewCell || n.contains("TabButton") || n.contains("TabBar") else { continue }
            let sel = NSSelectorFromString("_accessibilityUserTestingActions")
            let ut = v.responds(to: sel) ? String(describing: v.perform(sel)?.takeUnretainedValue()) : "n/a"
            let ca = (v.accessibilityCustomActions ?? []).map { $0.name }
            NSLog("FIXLOG actions %@ label=%@ ut=%@ ca=%@", n, v.accessibilityLabel ?? "", ut, ca.description)
        }
    }
    static var hooked = false
    static var traced = false
    static var lastCtx: UInt32 = 0
    static func swz(_ cls: AnyClass, _ name: String, _ arity: Int, _ tag: String) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(cls, sel) else { NSLog("FIXLOG trace missing %@", name); return }
        let st = { UIApplication.shared.applicationState.rawValue }
        if arity == 0 {
            typealias F = @convention(c) (AnyObject, Selector) -> UInt32
            let o = unsafeBitCast(method_getImplementation(m), to: F.self)
            let fake = ProcessInfo.processInfo.arguments.contains("-traceFakeCtx")
            let b: @convention(block) (AnyObject) -> UInt32 = { me in
                var r = o(me, sel)
                if r != 0 { Fix.lastCtx = r } else if fake { r = Fix.lastCtx }
                if me is UIButton { NSLog("FIXLOG trace %@ -> %u state=%d fake=%d", tag, r, st(), fake ? 1 : 0) }
                return r }
            method_setImplementation(m, imp_implementationWithBlock(b))
        } else if arity == 1 {
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let o = unsafeBitCast(method_getImplementation(m), to: F.self)
            let b: @convention(block) (AnyObject, AnyObject?) -> Void = { me, a in NSLog("FIXLOG trace %@ %@ state=%d", tag, String(describing: type(of: me)), st()); o(me, sel, a) }
            method_setImplementation(m, imp_implementationWithBlock(b))
        } else {
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let o = unsafeBitCast(method_getImplementation(m), to: F.self)
            let b: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { me, a, c in if me is UIButton { NSLog("FIXLOG trace %@ state=%d", tag, st()) }; o(me, sel, a, c) }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
    }
    static func installTrace() {
        guard !traced else { return }; traced = true
        swz(NSObject.self, "_accessibilityGetContextID", 0, "getContextID")
        swz(UIWindow.self, "sendEvent:", 1, "window.sendEvent")
        swz(UIApplication.self, "sendEvent:", 1, "app.sendEvent")
        swz(UIControl.self, "touchesBegan:withEvent:", 2, "control.touchesBegan")
        swz(UIControl.self, "touchesEnded:withEvent:", 2, "control.touchesEnded")
        NSLog("FIXLOG trace installed")
    }
    static func hookSwitchKeyCommands() {
        guard !hooked else { return }
        let sel = NSSelectorFromString("_accessibilityKeyCommands")
        guard let m = class_getInstanceMethod(UISwitch.self, sel) else { return }
        hooked = true
        typealias F = @convention(c) (AnyObject, Selector) -> AnyObject?
        let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
        var n = 0
        let blk: @convention(block) (AnyObject) -> AnyObject? = { me in
            n += 1
            if n <= 3 { NSLog("FIXLOG switchKC call %d state=%d stack %@", n, UIApplication.shared.applicationState.rawValue, Thread.callStackSymbols.prefix(25).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ").prefix(90)) }.joined(separator: " | ")) }
            return orig(me, sel)
        }
        method_setImplementation(m, imp_implementationWithBlock(blk))
        for name in ["_fkaSwitchOn", "_fkaSwitchOff", "_keyboardActivate"] {
            let s2 = NSSelectorFromString(name)
            guard let m2 = class_getInstanceMethod(UISwitch.self, s2) else { NSLog("FIXLOG switchKC no %@", name); continue }
            typealias V = @convention(c) (AnyObject, Selector) -> Void
            let o2 = unsafeBitCast(method_getImplementation(m2), to: V.self)
            let b2: @convention(block) (AnyObject) -> Void = { me in NSLog("FIXLOG switchKC %@ called state=%d", name, UIApplication.shared.applicationState.rawValue); o2(me, s2) }
            method_setImplementation(m2, imp_implementationWithBlock(b2))
        }
        NSLog("FIXLOG switchKC hooked")
    }
    static func focus(_ t: String) { NSLog("FIXLOG focusNow %@", t); focusLabel?.text = t; focusLabel?.accessibilityValue = t }
    static let t0 = Date()
    static func log(_ event: String) {
        count += 1
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        NSLog("FIXLOG %d %d %@ state=%d", count, ms, event, UIApplication.shared.applicationState.rawValue)
        label?.text = "\(count) \(event)"
        label?.accessibilityValue = "\(count) \(event)"
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // Diagnostics only (our fixture): which UIKit switch keeps the window context in the background.
    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("-keepAll") {
            let sel = NSSelectorFromString("_setAllWindowsKeepContextInBackground:")
            if let m = class_getClassMethod(UIWindow.self, sel) {
                typealias F = @convention(c) (AnyClass, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(m), to: F.self)(UIWindow.self, sel, true); NSLog("FIXLOG trace keepAll set")
            }
        }
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role); c.delegateClass = SceneDelegate.self; return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate, UITabBarControllerDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-keepWin") { w.setValue(true, forKey: "keepContextInBackground"); NSLog("FIXLOG trace keepWin set") }
        if args.contains("-keepScene") {
            let sel = NSSelectorFromString("_setKeepContextAssociationInBackground:")
            if let m = class_getInstanceMethod(type(of: scene), sel) {
                typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(m), to: F.self)(scene, sel, true); NSLog("FIXLOG trace keepScene set")
            }
        }
        let tabs = UITabBarController()
        tabs.delegate = self
        let nav = UINavigationController(rootViewController: ControlsController())
        nav.delegate = NavLogger.shared
        nav.tabBarItem = UITabBarItem(title: "Controls", image: UIImage(systemName: "slider.horizontal.3"), tag: 0)
        let second = SecondController(); second.tabBarItem = UITabBarItem(title: "Second", image: UIImage(systemName: "2.circle"), tag: 1)
        let swiftUI = UIHostingController(rootView: SwiftUIScreens()); swiftUI.tabBarItem = UITabBarItem(title: "SwiftUI", image: UIImage(systemName: "swift"), tag: 2)
        tabs.viewControllers = [nav, second, swiftUI]
        w.rootViewController = ProcessInfo.processInfo.arguments.contains("-coverage") ? Coverage.makeRoot(window: w) : tabs
        w.makeKeyAndVisible()
        window = w
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) { Fix.log("tab.didSelect \(viewController.tabBarItem.title ?? "")") }
    func sceneDidEnterBackground(_ scene: UIScene) { Fix.log("scene.didEnterBackground"); logWindow("didEnterBackground") }
    func sceneDidBecomeActive(_ scene: UIScene) { logWindow("didBecomeActive") }
    func sceneWillResignActive(_ scene: UIScene) { logWindow("willResignActive") }
    var windowTimer: Timer?
    func logWindow(_ tag: String) {
        guard let w = window else { return }
        let ctx = (w.value(forKey: "_contextId") as? NSNumber)?.uint32Value ?? 0
        let layerContext = (w.layer.value(forKey: "context") as AnyObject?).map { "\($0)" } ?? "nil"
        if let sc = w.windowScene, sc.responds(to: NSSelectorFromString("_FBSScene")), let fbs = sc.value(forKey: "_FBSScene") as? NSObject, let ident = fbs.value(forKey: "identifier") as? String {
            Fix.sceneLabel?.accessibilityValue = ident; Fix.sceneLabel?.text = "ctx:\(ctx)"
            NSLog("FIXLOG scene id=%@ key=%d", ident, w.isKeyWindow ? 1 : 0)
        }
        NSLog("FIXLOG window %@ contextId=%u layer.context=%@ activation=%d hidden=%d", tag, ctx, layerContext, w.windowScene?.activationState.rawValue ?? -9, w.isHidden ? 1 : 0)
        do {
            let pub = UIFocusSystem.focusSystem(for: w)
            var priv: AnyObject? = nil
            if let sc = w.windowScene, sc.responds(to: NSSelectorFromString("_accessibilityFocusSystem")) { priv = sc.perform(NSSelectorFromString("_accessibilityFocusSystem"))?.takeUnretainedValue() }
            var en = "?"
            if let p = priv, p.responds(to: NSSelectorFromString("_isEnabled")) { en = String(describing: p.perform(NSSelectorFromString("_isEnabled")) != nil) }
            let item = (pub ?? (priv as? UIFocusSystem))?.focusedItem
            let fkaFn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXSFullKeyboardAccessEnabled").map { unsafeBitCast($0, to: (@convention(c) () -> Bool).self) }
            Fix.hookSwitchKeyCommands(); Fix.installTrace()
            if let c = w.value(forKey: "_contextId") as? UInt32, c != 0 { Fix.lastCtx = c }
            if Fix.dumped < 2, Date().timeIntervalSince(Fix.t0) > 8 { Fix.dumped += 1; Fix.dumpActions(w) }
            Fix.focus(item.map { Fix.short($0) } ?? "none")
            NSLog("FIXLOG focus fka=%@ pub=%@ priv=%@ enabled=%@ item=%@", fkaFn.map { $0() ? "1" : "0" } ?? "?", pub == nil ? "nil" : "yes", priv == nil ? "nil" : String(describing: type(of: priv!)), en, item.map { String(describing: $0).prefix(80).description } ?? "none")
        }
        if windowTimer == nil { windowTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.logWindow("tick") } }
    }
    func sceneWillEnterForeground(_ scene: UIScene) { Fix.log("scene.willEnterForeground") }
}

final class NavLogger: NSObject, UINavigationControllerDelegate {
    static let shared = NavLogger()
    func navigationController(_ n: UINavigationController, willShow vc: UIViewController, animated: Bool) { Fix.log("nav.willShow \(vc.title ?? "") animated=\(animated)") }
    func navigationController(_ n: UINavigationController, didShow vc: UIViewController, animated: Bool) { Fix.log("nav.didShow \(vc.title ?? "")") }
}

/// An element that logs every UIKit accessibility entry point, used to map action numbers to names.
final class ProbeTarget: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        text = "Probe target"; isAccessibilityElement = true; accessibilityLabel = "Probe target"; accessibilityIdentifier = "probeTarget"
        accessibilityTraits = [.button, .adjustable]
        isUserInteractionEnabled = true
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Custom one") { _ in Fix.log("ax.customAction one"); return true }]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityActivate() -> Bool { Fix.log("ax.activate"); return true }
    override func accessibilityPerformEscape() -> Bool { Fix.log("ax.escape"); return true }
    override func accessibilityIncrement() { Fix.log("ax.increment") }
    override func accessibilityDecrement() { Fix.log("ax.decrement") }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool { Fix.log("ax.scroll \(direction.rawValue)"); return true }
    override func accessibilityPerformMagicTap() -> Bool { Fix.log("ax.magicTap"); return true }
    override func accessibilityZoomIn(at point: CGPoint) -> Bool { Fix.log("ax.zoomIn"); return true }
    override func accessibilityZoomOut(at point: CGPoint) -> Bool { Fix.log("ax.zoomOut"); return true }
    override func accessibilityElementDidBecomeFocused() { Fix.log("ax.didBecomeFocused") }
    // Private entry points found in the app-side dispatcher; logged so action ids can be mapped to them.
    @objc(_accessibilitySetNativeFocus) func pk_setNativeFocus() -> Bool { Fix.log("ax._accessibilitySetNativeFocus"); return true }
    @objc(_accessibilityDispatchKeyboardAction:) func pk_dispatchKeyboard(_ v: Any?) -> Bool { Fix.log("ax._accessibilityDispatchKeyboardAction: \(String(describing: v))"); return true }
    @objc(_accessibilityPerformUserTestingAction:) func pk_userTesting(_ v: Any?) -> Any? { Fix.log("ax._accessibilityPerformUserTestingAction: \(String(describing: v))"); return nil }
    @objc(_accessibilitySecondaryActivate) func pk_secondary() -> Bool { Fix.log("ax._accessibilitySecondaryActivate"); return true }
    @objc(_accessibilitySetFocusOnElement:) func pk_setFocusOn(_ v: Any?) { Fix.log("ax._accessibilitySetFocusOnElement: \(String(describing: v))") }
}

class LoggingController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); Fix.log("vc.didAppear \(title ?? "")")
        transitionCoordinator?.animate(alongsideTransition: nil) { _ in Fix.log("vc.transitionComplete \(self.title ?? "")") }
    }
    override func accessibilityPerformEscape() -> Bool { Fix.log("vc.escape \(title ?? "")"); return super.accessibilityPerformEscape() }
}

final class ControlsController: LoggingController, UITableViewDataSource, UITableViewDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Controls"; view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Bar", style: .plain, target: self, action: #selector(bar))
        let label = UILabel(); label.accessibilityIdentifier = "lastEvent"; label.text = "0 start"; Fix.label = label
        let focusLabel = UILabel(); focusLabel.accessibilityIdentifier = "focusNow"; focusLabel.text = "none"; Fix.focusLabel = focusLabel; focusLabel.font = .systemFont(ofSize: 9)
        let sceneLabel = UILabel(); sceneLabel.accessibilityIdentifier = "sceneId"; sceneLabel.text = "scene"; Fix.sceneLabel = sceneLabel; sceneLabel.font = .systemFont(ofSize: 9)
        let button = UIButton(type: .system); button.setTitle("Plain button", for: .normal); button.addTarget(self, action: #selector(plain), for: .primaryActionTriggered); Fix.plainButton = button
        let push = UIButton(type: .system); push.setTitle("Push level 2", for: .normal); push.addTarget(self, action: #selector(pushNext), for: .primaryActionTriggered)
        let sw = UISwitch(); sw.accessibilityLabel = "Switch"; sw.addTarget(self, action: #selector(switched(_:)), for: .valueChanged)
        let seg = UISegmentedControl(items: ["One", "Two", "Three"]); seg.selectedSegmentIndex = 0; seg.addTarget(self, action: #selector(segmented(_:)), for: .valueChanged)
        let slider = UISlider(); slider.accessibilityLabel = "Slider"; slider.addTarget(self, action: #selector(slid(_:)), for: .valueChanged)
        let field = UITextField(); field.borderStyle = .roundedRect; field.placeholder = "Field"; field.accessibilityIdentifier = "field"; field.addTarget(self, action: #selector(edited(_:)), for: .editingChanged)
        let alert = UIButton(type: .system); alert.setTitle("Show alert", for: .normal); alert.addTarget(self, action: #selector(showAlert), for: .primaryActionTriggered)
        let sheet = UIButton(type: .system); sheet.setTitle("Show sheet", for: .normal); sheet.addTarget(self, action: #selector(showSheet), for: .primaryActionTriggered)
        let probe = ProbeTarget()
        let table = UITableView(); table.dataSource = self; table.delegate = self; table.accessibilityIdentifier = "bigTable"; table.delegate = self
        let stack = UIStackView(arrangedSubviews: [label, focusLabel, sceneLabel, probe, button, push, sw, seg, slider, field, alert, sheet])
        stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false; table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); view.addSubview(table)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            table.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6), table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor), table.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)])
    }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: "k", modifierFlags: [], action: #selector(keyK)), UIKeyCommand(input: "k", modifierFlags: [.command], action: #selector(keyCmdK)), UIKeyCommand(input: "j", modifierFlags: [], action: #selector(keyJ)), UIKeyCommand(input: "s", modifierFlags: [], action: #selector(keyS))] }
    @objc func keyK() { Fix.log("keyCommand k") }
    @objc func keyCmdK() { Fix.log("keyCommand cmd-k") }
    @objc func keyS() {
        let app = UIApplication.shared
        let sel = NSSelectorFromString("_updateSnapshotForBackgroundApplication:")
        guard let m = class_getInstanceMethod(type(of: app), sel) else { NSLog("FIXLOG trace no snapshot method"); return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        let f = unsafeBitCast(method_getImplementation(m), to: F.self)
        let w = Fix.plainButton?.window
        NSLog("FIXLOG trace snap before ctx=%@ id=%u", w?.layer.value(forKey: "context") == nil ? "nil" : "yes", (w?.value(forKey: "_contextId") as? UInt32) ?? 0)
        f(app, sel, true)
        NSLog("FIXLOG trace snap after ctx=%@ id=%u", w?.layer.value(forKey: "context") == nil ? "nil" : "yes", (w?.value(forKey: "_contextId") as? UInt32) ?? 0)
        for d in [0.05, 0.2, 0.5, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { NSLog("FIXLOG trace snap +%.2f ctx=%@ id=%u", d, w?.layer.value(forKey: "context") == nil ? "nil" : "yes", (w?.value(forKey: "_contextId") as? UInt32) ?? 0) } }
    }
    @objc func keyJ() {
        guard let b = Fix.plainButton else { return }
        let w = b.window
        NSLog("FIXLOG trace keyJ state=%d hidden=%d key=%d activation=%d layerCtx=%@ ctxId=%u point=%@", UIApplication.shared.applicationState.rawValue, w?.isHidden == true ? 1 : 0, w?.isKeyWindow == true ? 1 : 0, w?.windowScene?.activationState.rawValue ?? -9, w?.layer.value(forKey: "context") == nil ? "nil" : "yes", (w?.value(forKey: "_contextId") as? UInt32) ?? 0, NSCoder.string(for: b.accessibilityActivationPoint))
        b.perform(NSSelectorFromString("_keyboardActivate"))
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { Fix.log("pressesBegan type=\(presses.first?.type.rawValue ?? -1) key=\(presses.first?.key?.characters ?? "-")"); super.pressesBegan(presses, with: event) }
    @objc func bar() { Fix.log("barButton -> push level 2"); navigationController?.pushViewController(LevelTwoController(), animated: true) }
    @objc func plain() { Fix.log("button"); NSLog("FIXLOG stack %@", Thread.callStackSymbols.prefix(40).joined(separator: " | ")) }
    @objc func pushNext() { Fix.log("push.requested"); navigationController?.pushViewController(LevelTwoController(), animated: true) }
    @objc func switched(_ s: UISwitch) { Fix.log("switch \(s.isOn)") }
    @objc func segmented(_ s: UISegmentedControl) { Fix.log("segment \(s.selectedSegmentIndex)") }
    @objc func slid(_ s: UISlider) { Fix.log(String(format: "slider %.2f", s.value)) }
    @objc func edited(_ f: UITextField) { Fix.log("field \(f.text ?? "")") }
    @objc func showAlert() {
        let a = UIAlertController(title: "Alert", message: "Pick", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in Fix.log("alert.cancel") })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in Fix.log("alert.ok") })
        present(a, animated: true) { Fix.log("alert.presented") }
    }
    @objc func showSheet() {
        let s = SheetController(); s.title = "Sheet"
        present(UINavigationController(rootViewController: s), animated: true) { Fix.log("sheet.presented") }
    }
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { 500 }
    func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "c") ?? UITableViewCell(style: .default, reuseIdentifier: "c")
        c.textLabel?.text = "Row \(i.row)"; return c
    }
    func tableView(_ t: UITableView, didSelectRowAt i: IndexPath) { Fix.log("row.select \(i.row)") }
    func scrollViewDidScroll(_ s: UIScrollView) { if Int(s.contentOffset.y) % 200 < 20 { Fix.log("table.scroll \(Int(s.contentOffset.y))") } }
}

final class LevelTwoController: LoggingController {
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Level 2"; view.backgroundColor = .systemBackground
        let b = UIButton(type: .system); b.setTitle("Push level 3", for: .normal)
        b.addTarget(self, action: #selector(pushThree), for: .primaryActionTriggered)
        b.frame = CGRect(x: 40, y: 200, width: 200, height: 44); view.addSubview(b)
        let a = ActivatePush(frame: CGRect(x: 40, y: 260, width: 240, height: 44)); a.onActivate = { [weak self] in self?.pushThree() }; view.addSubview(a)
    }
    @objc func pushThree() { Fix.log("push3.requested"); navigationController?.pushViewController({ let v = LoggingController(); v.title = "Level 3"; v.view.backgroundColor = .systemBackground; return v }(), animated: true) }
}

final class ActivatePush: UILabel {
    var onActivate: (() -> Void)?
    override init(frame: CGRect) { super.init(frame: frame); text = "Activate push"; isAccessibilityElement = true; accessibilityLabel = "Activate push"; accessibilityTraits = .button }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityActivate() -> Bool { Fix.log("activatePush"); onActivate?(); return true }
}

final class SheetController: LoggingController {
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(close))
    }
    @objc func close() { Fix.log("sheet.close"); dismiss(animated: true) { Fix.log("sheet.dismissed") } }
}

final class SecondController: LoggingController {
    override func viewDidLoad() { super.viewDidLoad(); title = "Second"; view.backgroundColor = .systemBackground }
}

struct SwiftUIScreens: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                List {
                    NavigationLink("SwiftUI detail") { Text("Detail").onAppear { Fix.log("swiftui.detail.appear") } }
                    Button("SwiftUI button") { Fix.log("swiftui.button") }
                }.navigationTitle("SwiftUI")
            }.tabItem { Label("Inner A", systemImage: "a.circle") }.tag(0)
            Text("Inner B").onAppear { Fix.log("swiftui.innerB.appear") }.tabItem { Label("Inner B", systemImage: "b.circle") }.tag(1)
        }.onChange(of: tab) { _, v in Fix.log("swiftui.tab \(v)") }
    }
}
