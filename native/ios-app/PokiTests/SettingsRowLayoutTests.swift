import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class SettingsRowLayoutTests: XCTestCase {
    private var storage: IsolatedTestStorage!
    private var previousLanguage: String?
    private var window: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IsolatedTestStorage(prefix: "settings-row-layout")
        previousLanguage = AppLocalization.shared.preference
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let previousLanguage {
            AppLocalization.shared.preference = previousLanguage
        }
        try storage?.tearDown()
        storage = nil
        try super.tearDownWithError()
    }

    func testSettingsRowKeepsTitleIntactAndValueSingleLineWhenValueIsLong() throws {
        let longValues = [
            "workbuddy/deepseek-v4.1-flash",
            "enterprise-very-long-custom-model-name-that-exceeds-row-width-2026",
        ]

        for (localeCode, expectedTitle) in [("zh-Hans", "模型"), ("en", "Models")] {
            AppLocalization.shared.preference = localeCode
            let locale = AppLocalization.locale

            for width in [CGFloat(295), CGFloat(321)] {
                let reference = UIHostingController(
                    rootView: SettingsRow(title: "Models", symbol: "sparkles", value: "On")
                        .environment(\.locale, locale)
                )
                let referenceHeight = reference.sizeThatFits(in: CGSize(width: width, height: 2_000)).height

                let referenceWindow = try show(
                    SettingsRow(title: "Models", symbol: "sparkles", value: "On")
                        .frame(width: width)
                        .environment(\.locale, locale)
                )
                settle { self.accessibilityFrame(label: expectedTitle, in: referenceWindow) != nil }
                let referenceTitleFrame = try XCTUnwrap(accessibilityFrame(label: expectedTitle, in: referenceWindow))
                let referenceValueFrame = try XCTUnwrap(accessibilityFrame(label: "On", in: referenceWindow))

                for longValue in longValues {
                    let row = UIHostingController(
                        rootView: SettingsRow(title: "Models", symbol: "sparkles", value: longValue)
                            .environment(\.locale, locale)
                    )
                    let rowHeight = row.sizeThatFits(in: CGSize(width: width, height: 2_000)).height
                    XCTAssertLessThanOrEqual(
                        rowHeight,
                        referenceHeight + 1,
                        "\(localeCode) width=\(width) value=\(longValue): row must stay single-line (got \(rowHeight), reference \(referenceHeight))"
                    )

                    let longWindow = try show(
                        SettingsRow(title: "Models", symbol: "sparkles", value: longValue)
                            .frame(width: width, alignment: .leading)
                            .environment(\.locale, locale)
                    )
                    settle { self.accessibilityFrame(label: expectedTitle, in: longWindow) != nil }
                    let titleFrame = try XCTUnwrap(accessibilityFrame(label: expectedTitle, in: longWindow))
                    let valueFrame = try XCTUnwrap(accessibilityFrame(label: longValue, in: longWindow))
                    let rowMaxX = (longWindow.bounds.width + width) / 2

                    XCTAssertGreaterThanOrEqual(
                        titleFrame.width,
                        referenceTitleFrame.width - 1,
                        "\(localeCode) width=\(width) value=\(longValue): title width collapsed (\(titleFrame.width) vs \(referenceTitleFrame.width))"
                    )
                    XCTAssertLessThanOrEqual(
                        titleFrame.height,
                        referenceTitleFrame.height + 1,
                        "\(localeCode) width=\(width) value=\(longValue): title wrapped vertically (\(titleFrame.height) vs \(referenceTitleFrame.height))"
                    )
                    XCTAssertLessThanOrEqual(
                        valueFrame.height,
                        referenceValueFrame.height + 1,
                        "\(localeCode) width=\(width) value=\(longValue): value wrapped vertically (\(valueFrame.height) vs \(referenceValueFrame.height))"
                    )
                    XCTAssertLessThanOrEqual(
                        abs(valueFrame.midY - titleFrame.midY),
                        4,
                        "\(localeCode) width=\(width) value=\(longValue): value dropped below title (title midY=\(titleFrame.midY), value midY=\(valueFrame.midY))"
                    )
                    XCTAssertLessThanOrEqual(
                        valueFrame.maxX,
                        rowMaxX + 1,
                        "\(localeCode) width=\(width) value=\(longValue): value overflowed row width (\(valueFrame.maxX) > \(rowMaxX))"
                    )
                }
            }
        }

        AppLocalization.shared.preference = "en"
        let locale = AppLocalization.locale

        let signingRow = UIHostingController(
            rootView: SettingsRow(title: "Signing & Updates", symbol: "signature", value: "Sign In Again", warns: true)
                .environment(\.locale, locale)
        )
        XCTAssertLessThan(signingRow.sizeThatFits(in: CGSize(width: 321, height: 2_000)).height, 60)

        let baselineAllowWindow = try show(
            SettingsRow(title: "Notifications", symbol: "bell.badge", value: "Allow", valueIsAction: true)
                .frame(width: 321)
                .environment(\.locale, locale)
        )
        settle { self.accessibilityFrame(label: "Allow", in: baselineAllowWindow) != nil }
        let baselineAllowFrame = try XCTUnwrap(accessibilityFrame(label: "Allow", in: baselineAllowWindow))

        let captionedWindow = try show(
            SettingsRow(
                title: "Notifications",
                caption: "Approvals and finished tasks",
                symbol: "bell.badge",
                value: "Allow",
                valueIsAction: true
            )
            .frame(width: 321)
            .environment(\.locale, locale)
        )
        settle { self.accessibilityFrame(label: "Allow", in: captionedWindow) != nil }
        let captionedAllowFrame = try XCTUnwrap(accessibilityFrame(label: "Allow", in: captionedWindow))
        XCTAssertGreaterThanOrEqual(captionedAllowFrame.width, baselineAllowFrame.width - 1)

        let baselineScreenHistoryWindow = try show(
            SettingsRow(
                title: "Screen History",
                caption: "Experimental Feature",
                symbol: "rectangle.stack",
                value: "Off"
            )
            .frame(width: 295)
            .environment(\.locale, locale)
        )
        settle { self.accessibilityFrame(label: "Screen History", in: baselineScreenHistoryWindow) != nil }
        let baselineScreenHistoryTitle = try XCTUnwrap(accessibilityFrame(label: "Screen History", in: baselineScreenHistoryWindow))

        let longCaptionedValue = "workbuddy/deepseek-v4.1-flash-extra-long-status"
        let longCaptionedWindow = try show(
            SettingsRow(
                title: "Screen History",
                caption: "Experimental Feature",
                symbol: "rectangle.stack",
                value: longCaptionedValue
            )
            .frame(width: 295)
            .environment(\.locale, locale)
        )
        settle { self.accessibilityFrame(label: "Screen History", in: longCaptionedWindow) != nil }
        let longCaptionedTitle = try XCTUnwrap(accessibilityFrame(label: "Screen History", in: longCaptionedWindow))
        let longCaptionedValueFrame = try XCTUnwrap(accessibilityFrame(label: longCaptionedValue, in: longCaptionedWindow))
        let captionedRowMaxX = (longCaptionedWindow.bounds.width + 295) / 2
        XCTAssertGreaterThanOrEqual(longCaptionedTitle.width, baselineScreenHistoryTitle.width - 1)
        XCTAssertLessThanOrEqual(longCaptionedTitle.height, baselineScreenHistoryTitle.height + 1)
        XCTAssertLessThanOrEqual(longCaptionedValueFrame.maxX, captionedRowMaxX + 1)

        let accessibilityValue = "enterprise-very-long-custom-model-name-that-exceeds-row-width-2026"
        let accessibilityWindow = try show(
            SettingsRow(title: "Models", symbol: "sparkles", value: accessibilityValue)
                .frame(width: 295)
                .environment(\.locale, locale)
                .environment(\.dynamicTypeSize, .accessibility2)
        )
        settle { self.accessibilityFrame(label: accessibilityValue, in: accessibilityWindow) != nil }
        let accessibilityValueFrame = try XCTUnwrap(accessibilityFrame(label: accessibilityValue, in: accessibilityWindow))
        let accessibilityRowMaxX = (accessibilityWindow.bounds.width + 295) / 2
        XCTAssertLessThanOrEqual(
            accessibilityValueFrame.maxX,
            accessibilityRowMaxX + 1,
            "Accessibility-size stacked value must stay inside row width (\(accessibilityValueFrame.maxX) > \(accessibilityRowMaxX))"
        )
    }

    func testSettingsModelsRowShowsRawLongModelNameOnSingleLine() throws {
        let store = storage.storage
        let rawModel = "workbuddy/deepseek-v4.1-flash"
        let overflowModel = "enterprise-very-long-custom-model-name-that-exceeds-row-width-2026"
        let workbuddy = CustomProviders.upsert(
            CustomProvider(
                name: "WorkBuddy",
                endpoints: [CustomEndpoint(url: "http://127.0.0.1:8767/v1")],
                model: rawModel,
                added: [overflowModel]
            ),
            storage: store
        )
        let choiceID = CustomProviders.choiceID(workbuddy.id, rawModel)
        ModelKeys.choose(.custom, model: choiceID, in: store)
        XCTAssertEqual(ModelKeys.selectedModelName(in: store), rawModel)

        AppLocalization.shared.preference = "zh-Hans"
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: store)
        let chat = ChatModel(app: app)
        defer { app.stopSession() }

        let window = try show(
            PokiDetailsView(openSetup: {}, path: .constant(NavigationPath()))
                .environment(app)
                .environment(chat)
                .environment(\.locale, AppLocalization.locale)
        )
        settle {
            self.accessibilityElement(identifier: "details.accountsAndModels", in: window) != nil
                && self.accessibilityElement(identifier: "details.hands", in: window) != nil
        }

        let setupRow = try XCTUnwrap(accessibilityElement(identifier: "details.hands", in: window))
        let modelRow = try XCTUnwrap(accessibilityElement(identifier: "details.accountsAndModels", in: window))
        let rowTexts = visibleTexts(in: modelRow)
        XCTAssertTrue(rowTexts.contains { $0.contains("模型") }, "Expected Settings Models title, got: \(rowTexts)")
        XCTAssertTrue(rowTexts.contains { $0.contains(rawModel) }, "Expected raw model name without stripping prefix, got: \(rowTexts)")
        XCTAssertLessThanOrEqual(
            modelRow.accessibilityFrame.height,
            setupRow.accessibilityFrame.height + 2,
            "Settings Models row height must match single-line sibling row (\(modelRow.accessibilityFrame.height) vs \(setupRow.accessibilityFrame.height))"
        )

        let overflowChoiceID = CustomProviders.choiceID(workbuddy.id, overflowModel)
        ModelKeys.choose(.custom, model: overflowChoiceID, in: store)
        settle {
            guard let row = self.accessibilityElement(identifier: "details.accountsAndModels", in: window) else { return false }
            return self.visibleTexts(in: row).contains { $0.contains(overflowModel) }
        }
        let overflowRow = try XCTUnwrap(accessibilityElement(identifier: "details.accountsAndModels", in: window))
        XCTAssertLessThanOrEqual(
            overflowRow.accessibilityFrame.height,
            setupRow.accessibilityFrame.height + 2,
            "Settings Models row with overflowing value must stay single-line (\(overflowRow.accessibilityFrame.height) vs \(setupRow.accessibilityFrame.height))"
        )
    }

    private func show(_ view: some View) throws -> UIWindow {
        window?.isHidden = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let next = UIWindow(windowScene: scene)
        next.frame = scene.screen.bounds
        next.rootViewController = UIHostingController(rootView: view.environment(\.accessibilityEnabled, true))
        next.makeKeyAndVisible()
        next.layoutIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: next.rootViewController?.view)
        self.window = next
        return next
    }

    private func settle(for seconds: TimeInterval = 2, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func accessibilityElement(identifier: String, in root: NSObject) -> NSObject? {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        let selector = NSSelectorFromString("accessibilityIdentifier")
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            let id = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
            if id == identifier { return item }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements {
                pending.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return nil
    }

    private func accessibilityFrame(label: String, in root: NSObject) -> CGRect? {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if item.accessibilityLabel == label, !item.accessibilityFrame.isEmpty {
                return item.accessibilityFrame
            }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements {
                pending.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return nil
    }

    private func visibleTexts(in root: NSObject) -> [String] {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        var result: [String] = []
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if let label = item.accessibilityLabel, !label.isEmpty { result.append(label) }
            if let uiLabel = item as? UILabel, let text = uiLabel.text, !text.isEmpty { result.append(text) }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements {
                pending.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return result
    }
}
