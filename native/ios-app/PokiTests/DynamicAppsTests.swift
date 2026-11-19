import UIKit
import XCTest
@testable import Poki

/// Apps Poki does not list by name still show with their name and icon once the phone's app list has
/// them: the list's names give the bundle id, the id gives the iPhone's icon or the App Store's.
@MainActor
final class DynamicAppsTests: XCTestCase {
    private let strava = DynamicApps.Entry(id: "com.strava.stravaride", name: "Strava", user: true)
    private let chagee = DynamicApps.Entry(id: "com.chagee.application.cn", name: "霸王茶姬", user: true)

    private func reset() {
        DynamicApps.set([])
        try? FileManager.default.removeItem(at: InstalledApps.cacheFile)
    }
    override func setUp() async throws { reset() }
    override func tearDown() async throws { reset() }

    private func capsules(_ plain: String) -> [String] {
        CapsuleText.segments(plain).compactMap { if case .app(let app, _) = $0 { app.id } else { nil } }
    }

    func testAnInstalledAppsNameGivesItsBundleIDAndBack() {
        XCTAssertNil(AppIconStore.bundleID("Strava"))
        DynamicApps.set([strava, chagee])
        XCTAssertEqual(AppIconStore.bundleID("Strava"), "com.strava.stravaride")
        XCTAssertEqual(AppIconStore.bundleID("strava"), "com.strava.stravaride")
        XCTAssertEqual(AppIconStore.bundleID("霸王茶姬"), "com.chagee.application.cn")
        XCTAssertEqual(AppIconStore.name("com.strava.stravaride"), "Strava")
        XCTAssertEqual(AppName.display("com.strava.stravaride"), "Strava", "an installed app's id reads as its name")
        XCTAssertEqual(AppIconStore.bundleID("淘宝"), "com.taobao.taobao4iphone", "KnownApps still first")
    }

    func testANameTwoAppsShareFindsNeither() {
        DynamicApps.set([strava, .init(id: "com.example.strava", name: "Strava", user: true)])
        XCTAssertNil(DynamicApps.id(forName: "Strava"))
        XCTAssertEqual(DynamicApps.name(forID: "com.example.strava"), "Strava")
    }

    private func square(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
    }

    /// The store follows the installed apps by itself: nothing here tells it they changed.
    func testTheIconComesOnceTheListArrivesAndGoesWithTheName() {
        let red = square(.red)
        let store = AppIconStore(installed: { id, _ in id == "com.strava.stravaride" ? red : nil })
        XCTAssertNil(store.icon("Strava"), "no id for the name yet")
        DynamicApps.set([strava])
        XCTAssertTrue(store.icon("Strava") === red)
        // The app is renamed: its old name finds no app, so it shows no icon either.
        DynamicApps.set([.init(id: "com.strava.stravaride", name: "Strava Run", user: true)])
        XCTAssertNil(store.icon("Strava"), "the kept icon went with the name")
        XCTAssertTrue(store.icon("Strava Run") === red)
    }

    /// The id an agent's {launch: "name"} opens: the edition of a known app this iPhone has, else the
    /// known app's own id, else an installed app by its name.
    func testALaunchByNameOpensTheEditionThisPhoneHas() {
        XCTAssertEqual(KnownApps.launchID("Bilibili"), "tv.danmaku.bilianime", "no app list yet: the known app's own id")
        DynamicApps.set([.init(id: "com.bilibili.inter", name: "bilibili", user: true), strava])
        XCTAssertEqual(KnownApps.launchID("哔哩哔哩"), "com.bilibili.inter", "the international edition is the one installed")
        XCTAssertEqual(KnownApps.launchID("Strava"), "com.strava.stravaride")
        XCTAssertEqual(KnownApps.launchID("com.strava.stravaride"), "com.strava.stravaride")
        XCTAssertNil(KnownApps.launchID("Nonesuch"))
    }

    func testANameWithDotsIsAnAppBeforeItIsAnID() {
        XCTAssertNil(AppIconStore.bundleID("A.B.C"), "initials with dots are not a bundle id")
        XCTAssertNil(AppIconStore.bundleID("U.S.A"))
        XCTAssertEqual(AppIconStore.bundleID("com.tencent.xin"), "com.tencent.xin")
        XCTAssertEqual(AppIconStore.bundleID("com.example.new-app"), "com.example.new-app")
        DynamicApps.set([.init(id: "com.example.abc", name: "A.B.C", user: true)])
        XCTAssertEqual(AppIconStore.bundleID("A.B.C"), "com.example.abc", "an installed app's name comes first")
    }

    func testAnAccentedNameIsAWordOfItsOwn() {
        DynamicApps.set([.init(id: "com.example.cafe", name: "Café", user: true), strava])
        XCTAssertEqual(capsules("Open Café and order"), ["com.example.cafe"])
        XCTAssertEqual(capsules("Café"), ["com.example.cafe"])
        XCTAssertEqual(capsules("two Cafés nearby"), [], "not inside a longer word")
        XCTAssertEqual(capsules("open café"), [], "an unlisted name counts only as written")
        XCTAssertEqual(capsules("Stravaé"), [], "an accented letter ends no word")
    }

    func testInstalledUserAppsBecomeCapsulesCarefully() {
        DynamicApps.set([strava, chagee, .init(id: "com.apple.PrintCenter", name: "Print Center", user: false)])
        XCTAssertEqual(capsules("Open Strava and log my run"), ["com.strava.stravaride"])
        XCTAssertEqual(capsules("open strava"), [], "an unlisted Latin name counts only as written")
        XCTAssertEqual(capsules("打开霸王茶姬点一杯"), ["com.chagee.application.cn"])
        XCTAssertEqual(capsules("我想喝霸王茶姬"), [], "an unlisted Chinese name only where an app goes")
        XCTAssertEqual(capsules("Print Center is slow"), [], "system apps are not capsules")
        XCTAssertEqual(capsules("打开淘宝"), ["com.taobao.taobao4iphone"], "KnownApps capsules stay")
        DynamicApps.set([])
        XCTAssertEqual(capsules("Open Strava and log my run"), [], "the table follows the list")
    }

    /// A name two installed apps share makes no capsule, whichever the phone lists first; the app
    /// beside them with a name of its own still does.
    func testANameTwoAppsShareMakesNoCapsuleInEitherOrder() {
        let other = DynamicApps.Entry(id: "com.example.strava", name: "Strava", user: true)
        for list in [[strava, other, chagee], [other, strava, chagee], [chagee, other, strava]] {
            DynamicApps.set(list)
            XCTAssertEqual(capsules("Open Strava and log my run"), [], "\(list.map(\.id))")
            XCTAssertEqual(capsules("打开霸王茶姬点一杯"), ["com.chagee.application.cn"], "\(list.map(\.id))")
        }
        // A system app with the same name takes the name away too.
        DynamicApps.set([strava, .init(id: "com.apple.strava", name: "Strava", user: false)])
        XCTAssertEqual(capsules("Open Strava and log my run"), [])
        DynamicApps.set([strava])
        XCTAssertEqual(capsules("Open Strava and log my run"), ["com.strava.stravaride"])
    }

    /// The signer's answer, as it comes over the bridge, is decoded, reaches the names and capsules,
    /// tells the icons, and is kept in the file a later launch reads. A wrong key for the name or the
    /// type, a list that is never published, or icons that are never told, fails here.
    func testTheSignersAnswerReachesTheNamesTheCapsulesTheIconsAndTheFile() async throws {
        let answer = Data(#"{"v":{"apps":[{"id":"com.strava.stravaride","name":"Strava","bundle_name":"StravaRide","type":"User"},{"id":"com.apple.PrintCenter","bundle_name":"Print Center","type":"System"}]}}"#.utf8)
        var asked: [String: Any] = [:]
        let apps = InstalledApps()
        apps.phone = { ["device_address": "10.7.0.1"] }
        apps.call = { request in asked = request; return answer }
        let told = expectation(forNotification: AppIconStore.changed, object: AppIconStore.shared)
        let drawnBefore = AppIconStore.shared.arrivals
        let inventory = await apps.list()
        await fulfillment(of: [told], timeout: 1)
        XCTAssertGreaterThan(AppIconStore.shared.arrivals, drawnBefore, "the views that drew a placeholder draw again")
        XCTAssertEqual(asked["op"] as? String, "apps")
        XCTAssertEqual(asked["device_address"] as? String, "10.7.0.1")
        XCTAssertEqual(inventory?.apps, [.init(id: "com.strava.stravaride", name: "Strava", bundleName: "StravaRide", type: "User"),
                                         .init(id: "com.apple.PrintCenter", name: nil, bundleName: "Print Center", type: "System")])
        XCTAssertEqual(AppIconStore.bundleID("Strava"), "com.strava.stravaride")
        XCTAssertEqual(AppName.display("com.apple.PrintCenter"), "Print Center", "the bundle's name where there is no display name")
        XCTAssertEqual(capsules("Open Strava and log my run"), ["com.strava.stravaride"], "a User app is a capsule")
        XCTAssertEqual(capsules("Print Center is slow"), [], "a System app is not")

        // The file holds the same list, stays out of backups, and a later launch publishes from it.
        let file = InstalledApps.cacheFile
        let saved = try JSONDecoder().decode([InstalledApps.App].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, inventory?.apps)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        DynamicApps.set([])
        XCTAssertNil(AppIconStore.bundleID("Strava"))
        _ = InstalledApps()
        XCTAssertEqual(capsules("Open Strava and log my run"), ["com.strava.stravaride"])

        // A second read fills the same file in place and it is still out of backups.
        apps.now = { Date().addingTimeInterval(600) }
        _ = await apps.list()
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // Kept for 30 days: a file 29 days old is read, one 31 days old is removed unread.
        let day: TimeInterval = 86_400
        DynamicApps.set([])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-29 * day)], ofItemAtPath: file.path)
        _ = InstalledApps()
        XCTAssertEqual(AppIconStore.bundleID("Strava"), "com.strava.stravaride")
        DynamicApps.set([])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * day)], ofItemAtPath: file.path)
        _ = InstalledApps()
        XCTAssertNil(AppIconStore.bundleID("Strava"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
