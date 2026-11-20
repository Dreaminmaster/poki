import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// Settings › Security, the page the Security row and the chat's "Approvals are off" line open.
@MainActor
final class ApprovalsPageTests: XCTestCase {
    /// The page lets the owner choose the way of asking again: its Approval Method is a control to pick
    /// from, not a line that says which one is in use.
    func testTheApprovalsPageLetsTheOwnerPickTheApprovalMethod() async throws {
        let saved = UserDefaults.standard.object(forKey: ApprovalClassifier.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: ApprovalClassifier.modeKey) }
        UserDefaults.standard.set(ApprovalClassifier.Mode.off.rawValue, forKey: ApprovalClassifier.modeKey)
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let accessibility = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        defer { dlclose(accessibility) }
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSAutomationEnabled")), to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: (@convention(c) (Int32) -> Void).self)
        let previous = isEnabled()
        setEnabled(1)
        defer { setEnabled(previous) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack { SecuritySettingsView() }
            .environment(model).environment(\.accessibilityEnabled, true))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        UIAccessibility.post(notification: .screenChanged, argument: window.rootViewController?.view)

        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Self.method(in: window) != nil }, object: nil)
        await fulfillment(of: [found], timeout: 5)
        XCTAssertNotNil(Self.method(in: window), "no Approval Method button on the page; the page has \(Self.described(window))")
    }

    /// The Approval Method as a screen reader finds it: a button, as a menu to pick from is, and not a line of text.
    private static func method(in root: NSObject) -> NSObject? {
        all(in: root).first { $0.accessibilityLabel?.hasPrefix("Approval Method") == true && $0.accessibilityTraits.contains(.button) }
    }

    private static func described(_ root: NSObject) -> [String] {
        all(in: root).map { "\($0.accessibilityLabel ?? "-")|\($0.accessibilityValue ?? "-")|\($0.accessibilityTraits.rawValue)" }
    }

    private static func all(in root: NSObject) -> [NSObject] {
        var pending = [root], found: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            found.append(item)
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count { if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) } }
            }
        }
        return found
    }
}
