import UIKit
import XCTest
@testable import Poki

/// When this iPhone gives no usable icon for an installed app, the app's carried icon shows, never the
/// placeholder; an app's other edition counts as installed. The owner's phone has Taobao, yet 0.3.1 (863)
/// showed its pill with the placeholder.
@MainActor
final class AppIconFallbackTests: XCTestCase {
    private func picture(_ color: UIColor?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: format).image { context in
            if let color { color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 60)) }
        }
    }

    private func carried(_ file: String) -> Data? {
        Bundle.main.path(forResource: file, ofType: "png").flatMap { UIImage(contentsOfFile: $0)?.cgImage?.dataProvider?.data as Data? }
    }

    func testAnEmptyInstalledIconFallsBackToTheCarriedOne() {
        let empty = picture(nil)
        let store = AppIconStore(installed: { _, _ in empty })
        for app in KnownApps.all {
            guard let file = app.icon else { continue }
            let shown = store.icon(app.id)?.cgImage?.dataProvider?.data as Data?
            XCTAssertNotNil(shown, app.english)
            XCTAssertEqual(shown, carried(file), "\(app.english) shows the carried \(file).png")
        }
    }

    func testAnInstalledIconStillComesFirst() {
        let red = picture(.red)
        XCTAssertTrue(AppIconStore(installed: { id, _ in id == "com.taobao.taobao4iphone" ? red : nil }).icon("淘宝") === red)
    }

    func testAnotherEditionOfAnAppCountsAsInstalled() {
        let red = picture(.red)
        let store = AppIconStore(installed: { id, _ in id == "com.bilibili.inter" ? red : nil })
        XCTAssertTrue(store.icon("哔哩哔哩") === red)
        XCTAssertTrue(store.icon("bilibili") === red)
    }
}
