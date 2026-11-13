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
            for style: UIUserInterfaceStyle in [.light, .dark] {
                controller.overrideUserInterfaceStyle = style
                view.layoutIfNeeded()
                let picture = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                    view.layer.render(in: context.cgContext)
                }
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LaunchScreenEvidence")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try picture.pngData()?.write(to: folder.appendingPathComponent("launch-\(Int(size.width))-\(style.rawValue).png"))
            }
        }
    }

    func testLaunchBackgroundIsBrandBlueInBothAppearances() throws {
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        let background = try XCTUnwrap(controller.view.backgroundColor)
        let light = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        // UIColor 的色彩空间不同也可能表示相同颜色，比较解析后的 RGB 通道。
        for (colour, expected) in [(light, [32.0, 132.0, 253.0]), (dark, [32.0, 132.0, 253.0])] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            for (actual, channel) in zip([red, green, blue], expected) {
                XCTAssertEqual(actual, channel / 255, accuracy: 0.001)
            }
            XCTAssertEqual(alpha, 1)
        }
    }
}
