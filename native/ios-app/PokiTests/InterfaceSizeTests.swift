import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class InterfaceSizeTests: XCTestCase {
    func testNativeOverrideReachesExistingControllersAndClearsBackToSystem() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let original = window.traitCollection.preferredContentSizeCategory

        for category in [UIContentSizeCategory.extraSmall, .small, .large, .extraLarge, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
            AppInterfaceSize.apply(category.rawValue, to: window)
            window.layoutIfNeeded()
            XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, category)
            XCTAssertTrue(window.rootViewController === controller)
        }
        AppInterfaceSize.apply(AppInterfaceSize.system, to: window)
        window.layoutIfNeeded()
        XCTAssertFalse(window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, original)
        AppInterfaceSize.apply(UIContentSizeCategory.extraLarge.rawValue, to: window)
        AppInterfaceSize.apply("unknown-old-preference", to: window)
        XCTAssertFalse(window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
    }

    func testWindowOverrideUpdatesExistingSwiftUIAndUIKitTogether() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let probe = SizeProbe()
        let host = UIHostingController(rootView: ProbeView(probe: probe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for category in [UIContentSizeCategory.extraSmall, .small, .large, .extraLarge, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
            AppInterfaceSize.apply(category.rawValue, to: window)
            window.layoutIfNeeded()
            let end = Date().addingTimeInterval(2)
            while probe.size != DynamicTypeSize(category), Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(probe.size, DynamicTypeSize(category))
            XCTAssertEqual(host.traitCollection.preferredContentSizeCategory, category)
            XCTAssertTrue(window.rootViewController === host)
        }
    }

    private final class SizeProbe {
        var size: DynamicTypeSize?
    }

    private struct ProbeView: View {
        var probe: SizeProbe
        @Environment(\.dynamicTypeSize) private var size
        var body: some View {
            Text("Preview").font(.body)
                .onChange(of: size, initial: true) { _, size in probe.size = size }
        }
    }

    func testNonTrackingSliderChangesPersistCommonSizes() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppInterfaceSize.defaultsKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: app, kind: .handoff, requester: "Interface size test")
        defaults.set(UIContentSizeCategory.large.rawValue, forKey: AppInterfaceSize.defaultsKey)
        let host = UIHostingController(rootView: InterfaceSizeSettingsView().environment(app).environment(chat))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            defaults.set(original, forKey: AppInterfaceSize.defaultsKey)
        }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        func slider(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        let control = try XCTUnwrap(slider(in: host.view))
        // Programmatic/accessibility changes have no active touch tracking and must save
        // immediately. Actual drag tracking is checked with a finger and device recording.
        XCTAssertFalse(control.isTracking)
        for index in [0, 3, 5, 8, 11, 2] {
            control.value = control.minimumValue + (control.maximumValue - control.minimumValue) * Float(index) / 11
            control.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            XCTAssertEqual(defaults.string(forKey: AppInterfaceSize.defaultsKey), AppInterfaceSize.categories[index].rawValue)
        }
    }

    func testNavigationFontsUseTheEffectiveWindowCategory() throws {
        let language = AppLocalization.shared.preference
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            AppLocalization.shared.preference = language
            AppInterfaceSize.apply(AppInterfaceSize.system, to: window)
            AppInterfaceSize.updateNavigationFonts(in: window)
            window.isHidden = true
        }
        let geist = try XCTUnwrap(UIFont(name: "Geist-SemiBold", size: 17))
        for language in ["en", "zh-Hans"] {
            AppLocalization.shared.preference = language
            var sizes: [CGFloat] = []
            for category in [UIContentSizeCategory.extraSmall, .small, .large, .extraLarge, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
                AppInterfaceSize.apply(category.rawValue, to: window)
                AppInterfaceSize.updateNavigationFonts(in: window)
                let font = try XCTUnwrap(navigation.navigationBar.titleTextAttributes?[.font] as? UIFont)
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                // Custom-font metrics need not equal the system font's sizes; Geist's two smallest
                // headline sizes can also be equal. The expected traits come from the test case.
                let expected = language == "en"
                    ? UIFontMetrics(forTextStyle: .headline).scaledFont(for: geist, compatibleWith: traits)
                    : UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
                XCTAssertEqual(font.fontName, expected.fontName, "\(language), \(category.rawValue)")
                XCTAssertEqual(font.pointSize, expected.pointSize, accuracy: 0.1, "\(language), \(category.rawValue)")
                if let previous = sizes.last { XCTAssertGreaterThanOrEqual(font.pointSize, previous) }
                sizes.append(font.pointSize)
            }
            XCTAssertGreaterThan(try XCTUnwrap(sizes.last), try XCTUnwrap(sizes.first))
        }
    }

    func testPreferenceSurvivesSettingsVaultRestoration() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppInterfaceSize.defaultsKey)
        let appearance = defaults.object(forKey: Appearance.key) as? String
        let backup = try Keychain.read("settings.v1")
        defer {
            defaults.set(original, forKey: AppInterfaceSize.defaultsKey)
            if let backup { try? Keychain.write(backup, account: "settings.v1") }
            else { Keychain.delete("settings.v1") }
        }
        let value = UIContentSizeCategory.extraExtraLarge.rawValue
        defaults.set(value, forKey: AppInterfaceSize.defaultsKey)
        SettingsVault.save()
        defaults.removeObject(forKey: AppInterfaceSize.defaultsKey)
        SettingsVault.restore()
        XCTAssertEqual(defaults.string(forKey: AppInterfaceSize.defaultsKey), value)
        XCTAssertEqual(defaults.string(forKey: Appearance.key), appearance)
    }

    func testMarkedTextDefersResizingAndKeepsDraftAndSelection() {
        let field = CapsuleTextView()
        field.updateFont(for: .large)
        field.setPlain("Draft")
        field.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        let before = field.plainText
        let size = field.font?.pointSize
        field.updateFont(for: .accessibilityExtraExtraExtraLarge)
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertEqual(field.font?.pointSize, size)
        XCTAssertEqual(field.plainText, before)
        field.unmarkText()
        let selection = field.selectedRange
        field.reconcile()
        XCTAssertEqual(field.plainText, before)
        XCTAssertEqual(field.selectedRange, selection)
        XCTAssertGreaterThan(field.font?.pointSize ?? 0, size ?? 0)
    }

    func testResizingRedrawsCapsulesWithoutChangingTextOrSelection() {
        let field = CapsuleTextView()
        field.updateFont(for: .large)
        field.setPlain("Open Messages now")
        field.selectedRange = NSRange(location: 0, length: 4)
        let before = field.plainText
        let selection = field.selectedRange
        field.updateFont(for: .extraSmall)
        let small = field.font?.pointSize ?? 0
        field.updateFont(for: .accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(field.font?.pointSize ?? 0, small)
        XCTAssertEqual(field.plainText, before)
        XCTAssertEqual(field.selectedRange, selection)
        XCTAssertEqual(field.typingAttributes[.font] as? UIFont, field.font)
    }
}
