import SwiftUI
import XCTest
@testable import Poki

@MainActor
final class SigningPageTests: XCTestCase {
    /// Settings › Signing & Updates and the page under it, read as a person reads them with an update
    /// waiting and the signing about to end: every word is in Poki's language, and none of them is a
    /// word only the maintainers use. A release channel's name appears only as a choice on Advanced.
    func testSigningPagesUseThePersonsLanguageAndNoInternalWords() async throws {
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "en", "Requires iOS app language English (-AppleLanguages (en))")
        let language = AppLocalization.shared.preference
        let hooks = ["pokiLatest": "newer", "pokiSigningDays": 1.0, "pokiSignedIn": true] as [String: Any]
        hooks.forEach { UserDefaults.standard.set($1, forKey: $0) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let covered = scene.windows.filter { !$0.accessibilityElementsHidden }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        covered.forEach { $0.accessibilityElementsHidden = true }
        defer {
            window.isHidden = true
            covered.forEach { $0.accessibilityElementsHidden = false }
            AppLocalization.shared.preference = language
            hooks.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        await app.signer.checkLatest()
        XCTAssertTrue(app.signer.updateAvailable, "the simulator's newer build is known")
        // The core's own answer (its channels and its sign-in server), as the signer asks at launch.
        SignerBridge.installVault()
        try await SignerBridge.call(["op": "configure", "home": SelfSigner.home.path, "device_name": UIDevice.current.name])
        await app.signer.reload()
        let channels = try XCTUnwrap(app.signer.status, "the signer answers on the simulator").channels.map(\.title)
        XCTAssertFalse(channels.isEmpty, "the core offers a release channel")
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigningPageEvidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let internalWords = ["Beta", "anisette", "GitHub", "R2", "https://", "headers", "Signing Options", "Set up Poki", "Renew in"]
        let titles = ["en": "Signing & Updates", "zh-Hans": "安装签名与更新", "zh-Hant": "安裝簽名與更新"]
        let choices = ["en": ["Release Channel", "Sign-In Server", "Default", "Custom"],
                       "zh-Hans": ["更新通道", "登录服务器", "默认", "自定义"],
                       "zh-Hant": ["更新通道", "登入伺服器", "預設", "自訂"]]
        for options in [false, true] {
            for preference in ["en", "zh-Hans", "zh-Hant"] {
                AppLocalization.shared.preference = preference
                let controller = UIHostingController(rootView:
                    SigningReviewView(options: options).environment(app))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                CATransaction.flush()
                var words = PageWords()
                var source = ""
                let deadline = CACurrentMediaTime() + 30
                repeat {
                    try await Task.sleep(for: .milliseconds(200))
                    source = await Task.detached {
                        var code: NSString?
                        return PKInProcess.shared().sourceXML(nil, code: &code) ?? ""
                    }.value
                    // No answer yet (the page is still coming up) is asked again until the deadline.
                    words = (try? PageWords(source)) ?? PageWords()
                } while words.all.count < 4 && CACurrentMediaTime() < deadline
                let name = "\(options ? "options" : "signing")-\(preference)"
                try source.write(to: output.appendingPathComponent("\(name).xml"), atomically: true, encoding: .utf8)
                let image = await Task.detached {
                    var code: NSString?
                    return PKInProcess.shared().screenshot(&code)
                }.value
                try XCTUnwrap(image).write(to: output.appendingPathComponent("\(name).png"))

                XCTAssertGreaterThanOrEqual(words.all.count, 4, "\(name): the page shows its rows")
                if options {
                    for word in choices[preference]! + channels {
                        XCTAssertTrue(words.all.contains { $0.contains(word) }, "\(name): “\(word)” is on Advanced")
                    }
                    words.leaveOut(channels)
                } else {
                    XCTAssertTrue(words.all.contains(titles[preference]!), "\(name): the page has the name of its row in Settings")
                }
                for word in internalWords {
                    let found = words.all.filter { $0.localizedCaseInsensitiveContains(word) }
                    XCTAssertEqual(found, [], "\(name): “\(word)” is not a word for the person")
                }
                if preference != "en" {
                    XCTAssertEqual(words.leftInEnglish, [], "\(name): every word is in Poki's language")
                }
            }
        }
    }

    /// An address typed on Advanced and then left with Back reaches the signer, as one sent with Done
    /// does. Going back used to drop it without a word.
    func testAnAddressTypedAndLeftWithBackReachesTheSigner() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true }
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let core = AnisetteCore()
        app.signer.transport = { request, _ in try await core.answer(request) }
        await app.signer.reload()
        window.rootViewController = UIHostingController(rootView: NavigationStack { SigningOptionsPage() }.environment(app))
        window.makeKeyAndVisible()
        let field = try await settle("the address field shows") { window.textFields.first }

        _ = try await settle("the field takes the typing") { field.becomeFirstResponder() ? true : nil }
        field.selectAll(nil)
        field.insertText("https://ani.second.example")
        field.sendActions(for: .editingChanged)
        window.rootViewController = UIViewController()
        _ = try await settle("going back hands the address over") { core.received.last }
        XCTAssertEqual(core.received, ["https://ani.second.example"])
    }

    /// The first non-nil answer, asked again as the page settles, for at most five seconds.
    private func settle<T>(_ what: String, _ answer: () -> T?) async throws -> T {
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline {
            if let value = answer() { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(answer(), what)
    }
}

/// The core's sign-in server, as the launcher keeps it: set_anisette changes what status says.
@MainActor
private final class AnisetteCore {
    private var anisette = "https://ani.first.example"
    private(set) var received: [String] = []

    func answer(_ request: [String: Any]) throws -> Data {
        switch request["op"] as? String {
        case "set_anisette":
            let url = request["url"] as? String ?? ""
            received.append(url)
            anisette = url
            return try JSONSerialization.data(withJSONObject: ["v": ["anisette": url]])
        case "status":
            return try JSONSerialization.data(withJSONObject: ["v": [
                "signed_in": false, "needs_code": false, "keeps_password": false, "anisette": anisette,
                "channel": "beta", "channels": [["id": "beta", "title": "Beta"]],
            ] as [String: Any]])
        default:
            return try JSONSerialization.data(withJSONObject: ["v": [String: Any]()])
        }
    }
}

private extension UIView {
    var textFields: [UITextField] { (self as? UITextField).map { [$0] } ?? subviews.flatMap(\.textFields) }
}

private struct SigningReviewView: View {
    let options: Bool

    var body: some View {
        NavigationStack {
            if options {
                SigningOptionsPage()
            } else {
                SigningUpdatesPage()
            }
        }
        .environment(\.locale, AppLocalization.locale)
    }
}

/// What the page says: every label, value and placeholder under the window.
private final class PageWords: NSObject, XMLParserDelegate {
    private(set) var all: [String] = []

    override init() {}

    convenience init(_ source: String) throws {
        self.init()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "SigningPageTests", code: 1)
        }
    }

    /// Names that stay as they are in every language, and the Apple ID as it was typed.
    private static let names = ["Poki", "Apple", "ID", "iPhone", "Mac", "MB"]

    /// The core's own names (a release channel's title), which no language translates.
    func leaveOut(_ names: [String]) {
        all.removeAll { names.contains($0) }
    }

    var leftInEnglish: [String] {
        all.filter { text in
            let rest = Self.names.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
            return rest.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        // iOS names its own parts (the toolbar, the scroll bar) in the iPhone's language, not Poki's.
        // A symbol's label is iOS's name for it, and the settings icons are hidden from VoiceOver (this
        // tree still lists them, as it lists Advanced's hidden ticks).
        let systemParts = ["XCUIElementTypeApplication", "XCUIElementTypeWindow", "XCUIElementTypeToolbar", "XCUIElementTypeImage"]
        guard !systemParts.contains(elementName), attributes["label"]?.contains("scroll bar") != true else { return }
        for key in ["label", "value", "placeholderValue"] {
            if let text = attributes[key], !text.isEmpty, !all.contains(text) { all.append(text) }
        }
    }
}
