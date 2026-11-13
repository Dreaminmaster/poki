import UIKit
import XCTest

@MainActor
final class LaunchScreenTests: XCTestCase {
    func testLaunchUsesTheStoryboardInsteadOfTheSquareAppIcon() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "LaunchScreen")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        let view = try XCTUnwrap(controller.view)
        for size in [CGSize(width: 320, height: 568), CGSize(width: 430, height: 932), CGSize(width: 1024, height: 768)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let bear = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
            XCTAssertEqual(bear.frame.size, CGSize(width: 136, height: 136))
            XCTAssertEqual(bear.center.x, view.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(bear.center.y, view.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(bear.contentMode, .scaleAspectFit)
            XCTAssertNotNil(bear.image)
        }
    }

    func testLaunchBackgroundFollowsLightAndDarkChatColours() throws {
        let background = try XCTUnwrap(UIColor(named: "LaunchBackground"))
        let light = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(light, dark)
        XCTAssertEqual(light, UIColor(red: 245 / 255.0, green: 248 / 255.0, blue: 252 / 255.0, alpha: 1))
        XCTAssertEqual(dark, UIColor(red: 5 / 255.0, green: 7 / 255.0, blue: 13 / 255.0, alpha: 1))
    }
}
