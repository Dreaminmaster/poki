import XCTest
@testable import Poki

@MainActor
final class AppLaunchPromptTests: XCTestCase {
    func testNamedAppsReachTheModelWithTheirBundleIDs() async {
        for (request, bundleID) in [
            ("打开淘宝", "com.taobao.taobao4iphone"),
            ("打开美团", "com.meituan.imeituan"),
            ("打开铁路12306", "cn.12306.rails12306"),
            ("打开12306", "cn.12306.rails12306"),
            ("打开12306查询", "cn.12306.rails12306"),
            ("打开 12306 查询", "cn.12306.rails12306"),
        ] {
            let prompt = Harness.instructions(for: request)
            XCTAssertTrue(prompt.contains(bundleID), "\(request): missing \(bundleID)")
        }
        XCTAssertFalse(Harness.instructions(for: "打开美团").contains("com.meituan.itakeaway"))
    }

    func testNumericAliasDoesNotMatchInsideLongerIdentifiers() async {
        for request in ["order a123067 now", "call 9123067", "open notesbook"] {
            XCTAssertTrue(AppIconStore.bundleIDs(namedIn: request).isEmpty, request)
        }
    }

    func testLaunchFailureRequiresHomeScreenSearchBeforeCallingAnAppMissing() async {
        let prompt = Harness.instructions(for: "打开美团")
        XCTAssertTrue(prompt.contains("swipe down on the Home Screen to search"))
        XCTAssertTrue(prompt.contains("say the app is not installed only when that search finds nothing"))
    }
}
