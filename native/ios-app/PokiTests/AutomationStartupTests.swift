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

    func testConnectionCanContinueOrCancelWhenPasscodeAlertIsAbsent() async throws {
        try XCTSkipUnless(UserDefaults.standard.bool(forKey: "passcodeFallbackGate"), "Run scripts/passcode-fallback-tests.sh for the simulator first-boot fixture")
        let language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        let defaults = UserDefaults.standard
        let boot = defaults.object(forKey: "automationStartedBoot")
        defaults.removeObject(forKey: "automationStartedBoot")
        defer {
            defaults.set(boot, forKey: "automationStartedBoot")
            AppLocalization.shared.preference = language
        }
        for choice in ["Continue", "Cancel"] {
            let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
            let setup = model.setup
            model.setup.loopback = .none
            let chat = ChatModel(app: model)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let covered = scene.windows.filter { !$0.accessibilityElementsHidden }
            covered.forEach { $0.accessibilityElementsHidden = true }
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            let host = UIHostingController(rootView: NavigationStack { ConnectionView() }.environment(model).environment(chat))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                model.stopSession()
                model.setup = setup
                window.isHidden = true
                covered.forEach { $0.accessibilityElementsHidden = false }
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    window.layoutIfNeeded()
                    CATransaction.flush()
                    continuation.resume()
                }
            }
            let bundle = try XCTUnwrap(Bundle.main.bundleIdentifier)
            let activationError = await Task.detached { PKInProcess.shared().app(bundle, action: "activate") }.value
            XCTAssertNil(activationError)
            let active = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                UIApplication.shared.applicationState == .active
            }, object: nil)
            await fulfillment(of: [active], timeout: 5)
            try capture(window, named: "fallback-before-\(choice)")
            try await tapScreenElement("hands.on")
            let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.passcodeHeadsUp }, object: nil)
            await fulfillment(of: [requested], timeout: 3)
            XCTAssertTrue(model.passcodeHeadsUp, "The Automation switch must reach the first-boot explanation gate")
            model.passcodeHeadsUp = false
            XCTAssertNil(Self.alert(in: host), "The recovery path must work without a presented alert")
            XCTAssertFalse(model.sessionOn)
            let notices = model.log.lines.filter { $0.contains("iOS will ask for the passcode") }.count
            for _ in 0..<2 {
                let answer = await model.runTool("look", arguments: "{}")
                XCTAssertTrue(answer.isError)
                XCTAssertEqual(answer.text, "not_sent: To turn on automation, open Settings › Connection and tap Continue. Nothing was sent.")
                XCTAssertFalse(model.sessionOn)
                XCTAssertFalse(model.passcodeHeadsUp, "A repeated tool request must not request another alert")
            }
            XCTAssertEqual(model.log.lines.filter { $0.contains("iOS will ask for the passcode") }.count, notices,
                           "Repeated requests must retain the same pending confirmation without another notice log")
            _ = try await screenElements()
            try capture(window, named: "fallback-waiting-\(choice)")
            model.setup.loopback = .none
            try await tapScreenElement(choice)
            let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                choice == "Continue" ? model.problem == "Choose and enable a local connection first (Setup)." : model.problem == nil
            }, object: nil)
            await fulfillment(of: [outcome], timeout: 3)
            XCTAssertFalse(model.sessionOn, "Neither choice may bypass the remaining setup or authenticate for the owner")
            let after = try await screenElements()
            XCTAssertFalse(after.contains { $0.label == "Continue" || $0.label == "Cancel" }, "An explicit choice must remove the waiting controls")
            if choice == "Continue" {
                XCTAssertTrue(after.contains { $0.label == "Choose and enable a local connection in Setup first." }, "Continue must reach the next startup check and show its result on Connection")
            }
            try capture(window, named: "fallback-after-\(choice)")
            print("Passcode fallback \(choice): alert absent, sessionOn=\(model.sessionOn), problem=\(model.problem ?? "none")")
        }
    }

    private struct ScreenElement {
        let label: String
        let name: String
        let frame: CGRect
    }

    private final class ScreenParser: NSObject, XMLParserDelegate {
        var elements: [ScreenElement] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard attributes["visible"] != "false",
                  let x = attributes["x"].flatMap(Double.init), let y = attributes["y"].flatMap(Double.init),
                  let width = attributes["width"].flatMap(Double.init), let height = attributes["height"].flatMap(Double.init) else { return }
            elements.append(ScreenElement(label: attributes["label"] ?? "", name: attributes["name"] ?? "",
                                          frame: CGRect(x: x, y: y, width: width, height: height)))
        }
    }

    private func screenElements() async throws -> [ScreenElement] {
        let xml = await Task.detached {
            var code: NSString?
            return PKInProcess.shared().sourceXML(nil, code: &code)
        }.value
        let source = try XCTUnwrap(xml)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutomationStartupEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try source.write(to: folder.appendingPathComponent("screen-\(UUID().uuidString).xml"), atomically: true, encoding: .utf8)
        let parser = XMLParser(data: Data(source.utf8))
        let delegate = ScreenParser()
        parser.delegate = delegate
        XCTAssertTrue(parser.parse())
        return delegate.elements
    }

    private func tapScreenElement(_ name: String) async throws {
        let elements = try await screenElements()
        let element = try XCTUnwrap(elements.first { $0.name == name || $0.label == name }, "Connection must expose \(name) even when the passcode alert is absent")
        let point = CGPoint(x: name == "hands.on" ? element.frame.maxX - 32 : element.frame.midX, y: element.frame.midY)
        let delivered = await Task.detached {
            PKInProcess.shared().touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.08)]], timeout: 5).delivery
        }.value
        XCTAssertEqual(delivered, .sent)
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
