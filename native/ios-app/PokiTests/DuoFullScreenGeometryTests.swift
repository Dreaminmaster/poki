import UIKit
import XCTest
@testable import Poki

final class DuoFullScreenGeometryTests: XCTestCase {
    private final class Node: NSObject {
        @objc let elementType: Int64
        @objc let frame: CGRect
        @objc let children: [Node]

        init(_ elementType: Int64, _ frame: CGRect, _ children: [Node] = []) {
            self.elementType = elementType
            self.frame = frame
            self.children = children
        }
    }

    let portrait = CGRect(x: 0, y: 0, width: 669, height: 951)
    let landscape = CGRect(x: 0, y: 0, width: 951, height: 669)
    let coverPortrait = CGRect(x: 0, y: 0, width: 466, height: 678)
    let coverLandscape = CGRect(x: 0, y: 0, width: 678, height: 466)

    func testUprightWindowDeterminesAxesWhenRootStaysInFixedCoordinates() {
        let sheet = Node(4, CGRect(x: 20, y: 40, width: 280, height: 380))
        let window = Node(4, landscape)
        XCTAssertEqual(PKDuoFullWindow(Node(2, portrait, [sheet, window, window])), landscape)
        XCTAssertTrue(PKDuoFullWindow(Node(2, portrait, [sheet])).isNull)
        XCTAssertTrue(PKDuoFullWindow(Node(2, portrait, [window, Node(4, portrait)])).isNull)
    }

    func testCoverCompatibilityWindowsNormalizeAcrossOrientationsKeyboardAndLeadingStatusArea() {
        let compatPortrait = CGRect(x: 0, y: 0, width: 386, height: 678)
        let compatLeading = CGRect(x: 80, y: 0, width: 386, height: 678)
        let compatLandscape = CGRect(x: 0, y: 0, width: 678, height: 386)
        // Standard 386x678 compatibility app, with and without a full-width 466x678 keyboard window.
        XCTAssertEqual(PKDuoFullWindow(Node(2, compatPortrait, [Node(4, compatPortrait)])), coverPortrait)
        XCTAssertEqual(
            PKDuoFullWindow(Node(2, compatPortrait, [Node(4, compatPortrait), Node(4, coverPortrait)])),
            coverPortrait
        )
        // Full-cover root holding a 386x678 compatibility window, or offset beside an 80pt leading status area.
        XCTAssertEqual(PKDuoFullWindow(Node(2, coverPortrait, [Node(4, compatPortrait)])), coverPortrait)
        XCTAssertEqual(PKDuoFullWindow(Node(2, coverPortrait, [Node(4, compatLeading)])), coverPortrait)
        XCTAssertEqual(PKDuoFullWindow(Node(2, compatLeading, [Node(4, compatLeading)])), coverPortrait)
        // Landscape compatibility window on the rotated cover display.
        XCTAssertEqual(PKDuoFullWindow(Node(2, compatPortrait, [Node(4, compatLandscape)])), coverLandscape)
        XCTAssertEqual(PKDuoFullWindow(Node(2, compatLandscape, [Node(4, compatLandscape)])), coverLandscape)
        // Inner Split View panes (height 669) must never be normalized to cover dimensions.
        let innerPane = CGRect(x: 0, y: 0, width: 469, height: 669)
        XCTAssertTrue(PKDuoFullWindow(Node(2, landscape, [Node(4, innerPane)])).isNull)
    }

    func testOppositeLandscapeDirectionsMapTheSamePointToDifferentFixedCoordinates() {
        let point = CGPoint(x: 130, y: 260)
        var basis = CGAffineTransform.identity
        XCTAssertTrue(PKDuoFixedBasis(landscape.size, UIInterfaceOrientation.landscapeLeft.rawValue, &basis))
        XCTAssertEqual(point.applying(basis), CGPoint(x: 260, y: 821))
        XCTAssertTrue(PKDuoFixedBasis(landscape.size, UIInterfaceOrientation.landscapeRight.rawValue, &basis))
        XCTAssertEqual(point.applying(basis), CGPoint(x: 409, y: 130))
        XCTAssertFalse(PKDuoFixedBasis(portrait.size, UIInterfaceOrientation.landscapeRight.rawValue, &basis))
        XCTAssertFalse(PKDuoFixedBasis(landscape.size, UIInterfaceOrientation.unknown.rawValue, &basis))
    }
}
