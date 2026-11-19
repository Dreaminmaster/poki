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

    func testUprightWindowDeterminesAxesWhenRootStaysInFixedCoordinates() {
        let sheet = Node(4, CGRect(x: 20, y: 40, width: 280, height: 380))
        let window = Node(4, landscape)
        XCTAssertEqual(PKDuoFullWindow(Node(2, portrait, [sheet, window, window])), landscape)
        XCTAssertTrue(PKDuoFullWindow(Node(2, portrait, [sheet])).isNull)
        XCTAssertTrue(PKDuoFullWindow(Node(2, portrait, [window, Node(4, portrait)])).isNull)
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
