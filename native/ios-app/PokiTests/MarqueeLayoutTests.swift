import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class MarqueeLayoutTests: XCTestCase {
    func testSuggestionRowSetsScrollGeometryAfterInitialLayout() async {
        let row = MarqueeScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 48))
        row.running = false
        row.configure(spacing: 8, loops: true) { copies in
            AnyView(HStack(spacing: 8) {
                ForEach(0..<copies, id: \.self) { _ in
                    Text("Open Settings").frame(width: 154.5, height: 48)
                }
            }.fixedSize())
        }

        row.layoutIfNeeded()
        XCTAssertEqual(row.contentSize, .zero, "UIKit must finish first layout before resizing the scrollable strip")
        XCTAssertEqual(row.contentOffset, .zero, "UIKit must finish first layout before placing the repeated strip")

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertGreaterThan(row.contentSize.width, row.bounds.width, "The row still scrolls sideways")
        XCTAssertGreaterThan(row.contentOffset.x, 0, "The row starts on a repeated copy so either direction can scroll")
        XCTAssertLessThan(row.contentOffset.x + row.bounds.width, row.contentSize.width)
    }
}
