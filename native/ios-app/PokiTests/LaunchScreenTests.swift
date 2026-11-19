import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class LaunchScreenTests: XCTestCase {
    private func launchView() throws -> (UIViewController, UIView) {
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        return (controller, try XCTUnwrap(controller.view))
    }

    /// The design's iPhone 16 Pro board: the bear 418 points wide from 4 points left of the edge to 2 below it,
    /// its picture 45 points wider on each side and taller above for the shadow; the word's line centred
    /// 302.5 points down. On other screens the bear keeps to the bottom under the word.
    func testLaunchScreenPutsTheWordOverTheBearAlongTheBottomEdge() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "LaunchScreen")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
        let (controller, view) = try launchView()
        for size in [CGSize(width: 402, height: 874), CGSize(width: 320, height: 568), CGSize(width: 440, height: 956), CGSize(width: 1024, height: 768)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let backdrop = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.backdrop.rawValue) as? UIImageView)
            let word = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.word.rawValue) as? UIImageView)
            let bear = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.bear.rawValue) as? UIImageView)
            for picture in [backdrop, word, bear] { XCTAssertNotNil(picture.image) }
            XCTAssertEqual(backdrop.frame, view.bounds)
            XCTAssertEqual(bear.frame.maxY, size.height + 2, accuracy: 0.5)
            let bearTop = bear.frame.minY + bear.frame.height * 45 / (418 * 714 / 1024 + 45)
            XCTAssertLessThan(word.frame.maxY, bearTop, "the word clears the bear at \(size)")
            XCTAssertLessThanOrEqual(bear.frame.height, size.height * 0.485 + 0.5)
            if size.width == 402 {
                XCTAssertEqual(bear.frame.minX, -4 - 45, accuracy: 0.5)
                XCTAssertEqual(bear.frame.width, 418 + 2 * 45, accuracy: 0.5)
                XCTAssertEqual(word.frame.midY, 302.5, accuracy: 0.5)
                XCTAssertEqual(word.frame.midX, 201, accuracy: 0.5)
            }
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

    /// The launch screen's picture of the light is the home page's own light at rest, so the home page
    /// takes over from it without a jump. A change to the light's table without a new picture
    /// (scripts/make-launch-backdrop.sh) fails here.
    func testLaunchBackdropIsTheHomePagesLightAtRest() throws {
        let launch = try XCTUnwrap(UIImage(named: "LaunchBackdrop")?.cgImage)
        let renderer = ImageRenderer(content: HomeBackdrop(home: true, working: false, frozen: true)
            .environment(\.colorScheme, .light).frame(width: 402, height: 874))
        renderer.scale = 1
        let home = try XCTUnwrap(renderer.cgImage)
        let (a, b) = (try samples(launch), try samples(home))
        var worst = 0
        for i in a.indices { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        XCTAssertLessThanOrEqual(worst, 6, "launch picture and home light differ by \(worst) of 255 somewhere")
        // In both appearances the launch screen's ground is the home page's paper, never white or black.
        let (controller, view) = try launchView()
        for style: UIUserInterfaceStyle in [.light, .dark] {
            controller.overrideUserInterfaceStyle = style
            let ground = try XCTUnwrap(view.backgroundColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(ground.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            for (actual, expected) in zip([red, green, blue, alpha], [0xF5, 0xF7, 0xFA, 0xFF] as [CGFloat]) {
                XCTAssertEqual(actual, expected / 255, accuracy: 0.002)
            }
        }
    }

    /// The picture shrunk to 20 by 44 RGB samples, which evens out the grain.
    private func samples(_ image: CGImage) throws -> [UInt8] {
        let (width, height) = (20, 44)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }
}
