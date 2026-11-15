import CryptoKit
import SwiftUI
import XCTest
@testable import Poki

@MainActor
final class AutomationStartupTests: XCTestCase {
    func testPasscodeExplanationAppearsOverConnectionSettings() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "pokiScreen")
        let language = AppLocalization.shared.preference
        defaults.set("connection", forKey: "pokiScreen")
        AppLocalization.shared.preference = "en"
        defer {
            defaults.set(saved, forKey: "pokiScreen")
            AppLocalization.shared.preference = language
        }
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RootView().environment(model).environment(chat))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.stopSession() }
        let settings = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.presentedViewController?.viewIfLoaded?.window != nil
                && host.presentedViewController?.isBeingPresented == false
        }, object: nil)
        await fulfillment(of: [settings], timeout: 5)
        let settingsController = try XCTUnwrap(host.presentedViewController)
        try capture(window, named: "connection-before-prompt")

        model.passcodeHeadsUp = true
        let prompt = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.alert(in: host)?.title == "Enter Your Passcode Next"
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [prompt], timeout: 3)
        try capture(window, named: "passcode-settings")
        XCTAssertEqual(result, .completed, "Connection settings must show the passcode explanation, not leave Automation silently off")
        XCTAssertEqual(Set(Self.alert(in: host)?.actions.compactMap(\.title) ?? []), ["Cancel", "Continue"])
        XCTAssertTrue(host.presentedViewController === settingsController, "The passcode explanation must keep Connection settings open underneath it")
        model.passcodeHeadsUp = false
    }

    func testDownloadedImageIsNotReadyWithoutLoadableDeveloperFrameworks() async throws {
        try XCTSkipUnless(AppModel.onSimulator, "Uses a simulated developer-framework load failure")
        try XCTSkipUnless(dlopen("/System/Developer/Library/PrivateFrameworks/XCTestSupport.framework/XCTestSupport", RTLD_NOW | RTLD_GLOBAL) == nil,
                          "Run scripts/automation-startup-tests.sh to simulate unavailable developer frameworks")
        let directory = AppFiles.ddiDirectory
        let manager = FileManager.default
        let backup = directory.appendingPathExtension("startup-test-backup")
        let existed = manager.fileExists(atPath: directory.path)
        if existed { try manager.moveItem(at: directory, to: backup) }
        defer {
            try? manager.removeItem(at: directory)
            if existed { try? manager.moveItem(at: backup, to: directory) }
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data("A downloaded image does not mount developer tools".utf8)
        try bytes.write(to: directory.appendingPathComponent("fixture.dmg"))
        let entry: [String: Any] = ["Info": ["Path": "fixture.dmg"], "Digest": Data(SHA384.hash(data: bytes))]
        let entries = Dictionary(uniqueKeysWithValues: ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"].map { ($0, entry) })
        let manifest: [String: Any] = ["ProductBuildVersion": "fixture", "BuildIdentities": [["Manifest": entries]]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("BuildManifest.plist"))
        let store = DiskImageStore()
        XCTAssertTrue(store.recheck(), "The downloaded fixture must pass file verification")
        XCTAssertFalse(store.isReady, "Downloaded disk image files must not report Ready when developer frameworks cannot load")

        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; model.stopSession() }
        let language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        defer { AppLocalization.shared.preference = language }
        for (name, routes) in [("frameworks-unavailable", NavigationPath([DetailsRoute.connection])),
                               ("disk-image-downloaded", NavigationPath([SetupStep.pairing]))] {
            window.rootViewController = UIHostingController(rootView:
                PokiDetailsView(openSetup: {}, path: .constant(routes)).environment(model).environment(chat))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try capture(window, named: name)
        }
    }

    private func capture(_ window: UIWindow, named name: String) throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutomationStartupEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(picture.pngData()).write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static func alert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
        return controller.children.compactMap { alert(in: $0) }.first
    }
}
