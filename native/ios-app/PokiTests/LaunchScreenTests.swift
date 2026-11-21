import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class LaunchScreenTests: XCTestCase {
    func testLaunchPicturesLoadWithoutTheAssetCatalog() throws {
        for name in ["LaunchBackdrop", "LaunchWordmark@3x", "LaunchWordmarkDark@3x", "LaunchBear@2x"] {
            let file = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "png"))
            XCTAssertNotNil(UIImage(contentsOfFile: file.path), "\(name) must decode without Assets.car")
        }
    }

    private func launchView() throws -> (UIViewController, UIView) {
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        return (controller, try XCTUnwrap(controller.view))
    }

    /// The design's iPhone 16 Pro board: the bear 418 points wide from 4 points left of the edge to 2 below it,
    /// its picture 45 points wider on each side and taller above for the shadow; the word's line centred
    /// 302.5 points down. On other screens the bear stays in the bottom-left corner under the word.
    func testLaunchScreenPutsTheWordOverTheBearAlongTheBottomEdge() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "LaunchScreen")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
        let (controller, view) = try launchView()
        let layouts: [(screen: CGSize, wordHeight: CGFloat)] = [
            (CGSize(width: 402, height: 874), 64),
            (CGSize(width: 320, height: 568), 41.6),
            (CGSize(width: 440, height: 956), 70.0),
            (CGSize(width: 466, height: 678), 49.6),
            (CGSize(width: 669, height: 951), 69.6),
            (CGSize(width: 951, height: 669), 49.0),
            (CGSize(width: 1024, height: 768), 56.2)
        ]
        for (size, wordHeight) in layouts {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let backdrop = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.backdrop.rawValue) as? UIImageView)
            let word = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.word.rawValue) as? UIImageView)
            let bear = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.bear.rawValue) as? UIImageView)
            for picture in [backdrop, word, bear] { XCTAssertNotNil(picture.image) }
            XCTAssertEqual(backdrop.frame, view.bounds)
            XCTAssertEqual(word.frame.height, wordHeight, accuracy: 0.5, "wordmark height at \(size)")
            XCTAssertEqual(word.frame.width, wordHeight * 132 / 64, accuracy: 0.5, "wordmark width at \(size)")
            XCTAssertEqual(bear.frame.maxY, size.height + 2, accuracy: 0.5)
            let bearLeft = bear.frame.minX + bear.frame.width * 45 / 508
            XCTAssertEqual(bearLeft, -4, accuracy: 4, "the bear hugs the left edge at \(size)")
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
        let launch = try XCTUnwrap(try backdrop(.light))
        let renderer = ImageRenderer(content: HomeBackdrop(home: true, working: false, frozen: true)
            .environment(\.colorScheme, .light).frame(width: 402, height: 874))
        renderer.scale = 1
        let home = try XCTUnwrap(renderer.cgImage)
        let (a, b) = (try samples(launch), try samples(home))
        var worst = 0
        for i in a.indices { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        XCTAssertLessThanOrEqual(worst, 6, "launch picture and home light differ by \(worst) of 255 somewhere")
        // The dark picture is the home page's dark light at rest.
        let dark = try XCTUnwrap(try backdrop(.dark))
        let darkHome = ImageRenderer(content: HomeBackdrop(home: true, working: false, frozen: true)
            .environment(\.colorScheme, .dark).frame(width: 402, height: 874))
        darkHome.scale = 1
        let (c, d) = (try samples(dark), try samples(try XCTUnwrap(darkHome.cgImage)))
        worst = 0
        for i in c.indices { worst = max(worst, abs(Int(c[i]) - Int(d[i]))) }
        XCTAssertLessThanOrEqual(worst, 6, "dark launch picture and dark home light differ by \(worst) of 255 somewhere")
        // The paper is the home page's in each appearance, and under it a system colour that iOS draws
        // in the right appearance even with no catalogue.
        let (_, view) = try launchView()
        let paper = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.ground.rawValue))
        for (style, expected) in [(UIUserInterfaceStyle.light, [0xF5, 0xF7, 0xFA]), (.dark, [0x05, 0x07, 0x0D])] as [(UIUserInterfaceStyle, [CGFloat])] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let ground = try XCTUnwrap(paper.backgroundColor).resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(ground.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            for (actual, wanted) in zip([red, green, blue, alpha], expected + [0xFF]) {
                XCTAssertEqual(actual, wanted / 255, accuracy: 0.002, "paper in \(style.rawValue)")
            }
            XCTAssertEqual(view.backgroundColor?.resolvedColor(with: traits), UIColor.systemGroupedBackground.resolvedColor(with: traits))
        }
    }

    private func backdrop(_ style: UIUserInterfaceStyle) throws -> CGImage? {
        let (_, view) = try launchView()
        let picture = try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.backdrop.rawValue) as? UIImageView).image
        return picture?.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: style)).cgImage
    }

    /// The backdrop and the word have a Dark Mode picture of their own, under names that carry the
    /// pictures' version, so a launch screen drawn from an older catalogue finds nothing rather than
    /// an older picture; every launch picture is small enough for iOS to draw it before Poki runs.
    func testLaunchPicturesHaveDarkVersionsUnderVersionedNamesAndStaySmall() throws {
        let (_, view) = try launchView()
        for part in [LaunchCurtain.Part.backdrop, .word] {
            let image = try XCTUnwrap((view.viewWithTag(part.rawValue) as? UIImageView)?.image)
            let light = try XCTUnwrap(image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .light)).cgImage)
            let dark = try XCTUnwrap(image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)).cgImage)
            XCTAssertFalse(light === dark, "\(part) has no Dark Mode picture")
        }
        for part in [LaunchCurtain.Part.backdrop, .word, .bear] {
            let image = try XCTUnwrap((view.viewWithTag(part.rawValue) as? UIImageView)?.image)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let cg = try XCTUnwrap((image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: style)) ?? image).cgImage)
                XCTAssertLessThanOrEqual(cg.width * cg.height * 4, 4 << 20, "\(part) is \(cg.width) by \(cg.height)")
            }
        }
    }

    /// The welcome's hello starts as the launch screen: its word and bear are where the storyboard puts
    /// them, with the storyboard's pictures, on every screen.
    func testTheWelcomeStartsWhereTheLaunchScreenIs() throws {
        let (_, view) = try launchView()
        for size in [CGSize(width: 402, height: 874), CGSize(width: 320, height: 568), CGSize(width: 1024, height: 768)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let art = LaunchArt.on(size, dark: false)
            XCTAssertNotNil(art.wordPicture)
            XCTAssertNotNil(art.bearPicture)
            XCTAssertEqual(art.word, try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.word.rawValue)).frame)
            XCTAssertEqual(art.bear, try XCTUnwrap(view.viewWithTag(LaunchCurtain.Part.bear.rawValue)).frame)
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
