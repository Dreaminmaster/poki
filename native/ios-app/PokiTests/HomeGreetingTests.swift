import SwiftUI
import XCTest
@testable import Poki

/// The home page greets in two lines under Poki's picture: a hello for the time of day in ink, and
/// "What should Poki do?" in a grey under it.
@MainActor
final class HomeGreetingTests: XCTestCase {
    private func at(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    func testTheHelloFollowsTheTimeOfDay() {
        XCTAssertEqual(HomeGreeting.hello(at: at(8)), "Good morning.")
        XCTAssertEqual(HomeGreeting.hello(at: at(15)), "Good afternoon.")
        XCTAssertEqual(HomeGreeting.hello(at: at(20)), "Good evening.")
        XCTAssertEqual(HomeGreeting.hello(at: at(2)), "Up late.")
    }

    /// Drawn as the home page draws it, in light and in dark: two lines of type with a gap between,
    /// the first in ink and the second in the grey.
    func testTheGreetingIsTwoLinesTheSecondInGrey() throws {
        let schemes: [(ColorScheme, ink: UInt32, grey: UInt32)] = [(.light, 0x111110, 0x6F6F69), (.dark, 0xF4F4F1, 0x8D8D87)]
        for (scheme, ink, grey) in schemes {
            let renderer = ImageRenderer(content: HomeGreetingView(date: at(15))
                .frame(width: 354)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let pixels = try Pixels(XCTUnwrap(renderer.cgImage))
            let lines = pixels.linesOfType()
            XCTAssertEqual(lines.count, 2, "\(scheme): \(lines)")
            guard lines.count == 2 else { continue }
            XCTAssertEqual(pixels.solidColor(in: lines[0]), ink, "\(scheme), first line")
            XCTAssertEqual(pixels.solidColor(in: lines[1]), grey, "\(scheme), second line")
        }
    }
}

/// A rendered image's pixels, unpremultiplied RGBA in sRGB.
private struct Pixels {
    let width: Int, height: Int
    private var bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    /// Runs of rows that hold any type, top to bottom.
    func linesOfType() -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start: Int?
        for y in 0...height {
            let inked = y < height && (0..<width).contains { alpha($0, y) > 0 }
            if inked, start == nil { start = y }
            if !inked, let top = start { lines.append(top..<y); start = nil }
        }
        return lines
    }

    /// The most common colour among the fully covered pixels of these rows, as 0xRRGGBB.
    func solidColor(in rows: Range<Int>) -> UInt32? {
        var counts: [UInt32: Int] = [:]
        for y in rows {
            for x in 0..<width where alpha(x, y) == 255 {
                let i = (y * width + x) * 4
                counts[UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]), default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }
}
