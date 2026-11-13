import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// What the home page stops doing for a phone short of battery: the suggestion rows stop going by in
/// Low Power Mode, and go by again once it ends.
@MainActor
final class DeviceStrainTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        DeviceStrain.shared.lowPower = false
        window?.isHidden = true
        window = nil
    }

    func testTheSuggestionRowsRestInLowPowerMode() throws {
        let window = try show(HomePage(home: true, pick: { _ in }) { EmptyView() })
        settle { !Self.rows(in: window).isEmpty }
        let rows = Self.rows(in: window)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy(\.running), "Without Low Power Mode the rows go by themselves")

        DeviceStrain.shared.lowPower = true
        settle { rows.allSatisfy { !$0.running } }
        XCTAssertTrue(rows.allSatisfy { !$0.running }, "In Low Power Mode the suggestion rows must stand still")

        DeviceStrain.shared.lowPower = false
        settle { rows.allSatisfy(\.running) }
        XCTAssertTrue(rows.allSatisfy(\.running), "When Low Power Mode ends the rows go by again")
    }

    private func show(_ page: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: page)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func settle(for seconds: TimeInterval = 3, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func rows(in view: UIView) -> [MarqueeScrollView] {
        (view as? MarqueeScrollView).map { [$0] } ?? view.subviews.flatMap { rows(in: $0) }
    }
}
