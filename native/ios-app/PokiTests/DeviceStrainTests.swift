import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// What the home page stops doing for a phone short of battery or running hot: the suggestion rows
/// stop going by and the bear is its flat picture, and both come back once the phone is back to normal.
@MainActor
final class DeviceStrainTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        DeviceStrain.shared.lowPower = false
        DeviceStrain.shared.hot = false
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

    func testAHotPhoneStillsTheRowsAndDrawsTheFlatBearUntilItCools() throws {
        let window = try show(VStack {
            PokiPortrait(mood: .ready, side: 80)
            HomePage(home: true, pick: { _ in }) { EmptyView() }
        })
        settle(for: 10) { !Self.rows(in: window).isEmpty && Self.bears(in: window) == 1 }
        let rows = Self.rows(in: window)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Self.bears(in: window), 1, "The three-dimensional bear draws on a phone at ease")
        XCTAssertTrue(rows.allSatisfy(\.running))

        DeviceStrain.shared.hot = true
        settle { Self.bears(in: window) == 0 && rows.allSatisfy { !$0.running } }
        XCTAssertEqual(Self.bears(in: window), 0, "Running hot, the bear must be its flat picture, with no renderer")
        XCTAssertTrue(rows.allSatisfy { !$0.running }, "Running hot, the suggestion rows must stand still")

        DeviceStrain.shared.hot = false
        settle(for: 10) { Self.bears(in: window) == 1 && rows.allSatisfy(\.running) }
        XCTAssertEqual(Self.bears(in: window), 1, "Cooled down, the three-dimensional bear comes back")
        XCTAssertTrue(rows.allSatisfy(\.running), "Cooled down, the rows go by again")
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

    /// The three-dimensional bear's renderers on the page (`BearCanvas`, private to its file).
    private static func bears(in view: UIView) -> Int {
        (String(describing: type(of: view)) == "BearCanvas" ? 1 : 0) + view.subviews.reduce(0) { $0 + bears(in: $1) }
    }

    private static func rows(in view: UIView) -> [MarqueeScrollView] {
        (view as? MarqueeScrollView).map { [$0] } ?? view.subviews.flatMap { rows(in: $0) }
    }
}
