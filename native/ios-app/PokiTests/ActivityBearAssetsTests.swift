import UIKit
import XCTest
@testable import Poki

@MainActor
final class ActivityBearAssetsTests: XCTestCase {
    func testEveryPoseHasPresentationSizedAssets() throws {
        let poses: [ActivityBear] = [.phone, .needs, .turn, .done, .tripped, .ready, .paused, .thinking, .checking]
        for pose in poses {
            for (name, side) in [(pose.image, CGFloat(136)),
                                 (pose.compactImage, ActivityMetrics.compactBear),
                                 (pose.smallImage, ActivityMetrics.circleBear)] {
                let image = try XCTUnwrap(UIImage(named: name), "Missing asset: \(name)")
                XCTAssertEqual(image.size.width, side, accuracy: 0.01, name)
                XCTAssertEqual(image.size.height, side, accuracy: 0.01, name)
            }
        }
    }
}
