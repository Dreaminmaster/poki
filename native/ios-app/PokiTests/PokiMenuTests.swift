import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class PokiMenuTests: XCTestCase {
    private var window: UIWindow?
    private var hostLocalization: HostLocalizationSnapshot!
    private var storage: IsolatedTestStorage!

    override func setUp() async throws {
        hostLocalization = HostLocalizationSnapshot.capture()
        storage = try IsolatedTestStorage(prefix: "poki-menu")
        AppLocalization.shared.preference = "en"
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        hostLocalization.restore()
        hostLocalization.assertUnchanged()
        if let storage {
            self.storage = nil
            try storage.tearDown()
        }
    }

    func testHomeBearMenuAnchorsBelowAvatarWithoutCoveringFace() throws {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        let bearPlace = CGRect(x: 161, y: 260, width: 80, height: 80)
        let window = try show(
            PokiFlight(
                status: PokiStatus(.ready),
                home: true,
                places: [.home: bearPlace],
                pokes: 0,
                tap: {},
                openModel: {},
                openCustomization: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(app)
        )

        settle { self.menuButton(in: window, identifier: "home.poki") != nil }
        let button = try XCTUnwrap(
            menuButton(in: window, identifier: "home.poki"),
            "Home bear avatar must host a native UIButton menu trigger so its attachment point can anchor below the bear."
        )
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertEqual(button.preferredMenuElementOrder, .fixed)
        XCTAssertNotNil(button.menu)

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
        let container = try XCTUnwrap(button.superview)
        let bearFrameInWindow = container.convert(container.bounds, to: window)
        let buttonFrameInWindow = button.convert(button.bounds, to: window)
        let attachmentInButton = button.menuAttachmentPoint(for: configuration)
        let attachmentInWindow = button.convert(attachmentInButton, to: window)

        XCTAssertEqual(buttonFrameInWindow.midX, bearFrameInWindow.midX, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(
            buttonFrameInWindow.minY,
            bearFrameInWindow.maxY,
            "Native menu trigger frame must sit at or below the bottom of the bear avatar so Liquid Glass menus never cover the bear's face."
        )
        XCTAssertEqual(attachmentInWindow.x, bearFrameInWindow.midX, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(
            attachmentInButton.y,
            button.bounds.maxY,
            "Menu attachment point must stay at the button's bottom edge so iOS 27 opens the menu downward instead of flipping upward over the bear."
        )
        XCTAssertGreaterThanOrEqual(
            attachmentInWindow.y,
            bearFrameInWindow.maxY,
            "Native menu attachment point must sit at or below the bottom of the bear avatar so the menu never covers the bear's face."
        )
        XCTAssertTrue(
            container.hitTest(CGPoint(x: container.bounds.midX, y: container.bounds.midY), with: nil) === button,
            "Tapping the bear avatar must route directly to the native menu button."
        )
        XCTAssertNil(
            container.hitTest(CGPoint(x: container.bounds.midX, y: container.bounds.maxY + 12), with: nil),
            "Taps below the bear avatar must pass through to the greeting and buttons underneath."
        )
    }

    func testHomeBearMenuPreservesItemsActionsAndAccessibilityIdentifiers() throws {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        app.approvalMode = .confirm
        var openedModel = 0
        var openedCustomization = 0

        let bearPlace = CGRect(x: 161, y: 260, width: 80, height: 80)
        let window = try show(
            PokiFlight(
                status: PokiStatus(.ready),
                home: true,
                places: [.home: bearPlace],
                pokes: 0,
                tap: {},
                openModel: { openedModel += 1 },
                openCustomization: { openedCustomization += 1 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(app)
        )

        settle { self.menuButton(in: window, identifier: "home.poki")?.menu != nil }
        let button = try XCTUnwrap(menuButton(in: window, identifier: "home.poki"))
        let menu = try XCTUnwrap(button.menu)
        let elements = flattenMenuElements(menu)

        let modelElement = elements.first {
            $0.accessibilityIdentifier == "status.model" || $0.accessibilityIdentifier == "status.addModel"
        }
        XCTAssertNotNil(modelElement, "Expected status.model or status.addModel element")
        if let addModel = elements.first(where: { $0.accessibilityIdentifier == "status.addModel" }) as? UIAction {
            addModel.performWithSender(nil, target: nil)
            XCTAssertEqual(openedModel, 1)
        }

        let approvalsMenu = try XCTUnwrap(
            elements.first(where: { $0.accessibilityIdentifier == "status.approvals" }) as? UIMenu,
            "Expected status.approvals submenu"
        )
        XCTAssertEqual(approvalsMenu.subtitle, ApprovalClassifier.Mode.confirm.title)
        let approvalSection = try XCTUnwrap(approvalsMenu.children.first as? UIMenu)
        XCTAssertEqual(approvalSection.title, AppLocalization.text(ApprovalCopy.alwaysConfirm))
        XCTAssertTrue(approvalSection.title.contains("full screen details are unavailable"), approvalSection.title)
        XCTAssertTrue(approvalSection.title.contains("matching deletions"), approvalSection.title)
        let approvalActions = flattenMenuElements(approvalsMenu).compactMap { $0 as? UIAction }
        XCTAssertEqual(approvalActions.count, ApprovalClassifier.Mode.allCases.count)
        let offAction = try XCTUnwrap(approvalActions.first { $0.title == ApprovalClassifier.Mode.off.title })
        offAction.performWithSender(nil, target: nil)
        XCTAssertEqual(app.approvalMode, .off)

        let outfitsAction = try XCTUnwrap(
            elements.first(where: { $0.accessibilityIdentifier == "status.customizePoki" }) as? UIAction,
            "Expected status.customizePoki action"
        )
        outfitsAction.performWithSender(nil, target: nil)
        XCTAssertEqual(openedCustomization, 1)

        let hasAutoUnlock = elements.contains { $0.accessibilityIdentifier == "status.autoUnlock" }
        XCTAssertEqual(hasAutoUnlock, app.supportsAutoUnlock)
    }

    func testHomeBearMenuWithConfiguredModelExposesStatusModelSubmenu() throws {
        try ModelKeys.saveCustom(address: "http://127.0.0.1:8765/v1", model: "poki-test-model", typedKey: "", storage: storage.storage)
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        let bearPlace = CGRect(x: 161, y: 260, width: 80, height: 80)
        let window = try show(
            PokiFlight(
                status: PokiStatus(.ready),
                home: true,
                places: [.home: bearPlace],
                pokes: 0,
                tap: {},
                openModel: {},
                openCustomization: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(app)
        )

        settle { self.menuButton(in: window, identifier: "home.poki")?.menu != nil }
        let button = try XCTUnwrap(menuButton(in: window, identifier: "home.poki"))
        let menu = try XCTUnwrap(button.menu)
        let elements = flattenMenuElements(menu)

        let modelMenu = try XCTUnwrap(
            elements.first(where: { $0.accessibilityIdentifier == "status.model" }) as? UIMenu,
            "Expected status.model submenu when a model is configured"
        )
        XCTAssertEqual(modelMenu.subtitle, ModelKeys.selectedModelName(in: storage.storage))
        let modelActions = flattenMenuElements(modelMenu).compactMap { $0 as? UIAction }
        XCTAssertTrue(modelActions.contains { $0.title == "poki-test-model" && $0.state == .on })
    }

    func testModelChoiceKeepsIdenticallyNamedCustomModelsOnTheirOwnAccounts() throws {
        let storage = storage.storage
        let first = CustomProviders.upsert(CustomProvider(
            endpoints: [CustomEndpoint(url: "http://127.0.0.1:8765/v1")], model: "shared-model"
        ), storage: storage)
        let second = CustomProviders.upsert(CustomProvider(
            endpoints: [CustomEndpoint(url: "http://127.0.0.1:8766/v1")], model: "shared-model"
        ), storage: storage)

        let firstChoice = CustomProviders.choiceID(first.id, first.model)
        let secondChoice = CustomProviders.choiceID(second.id, second.model)
        ModelKeys.choose(.custom, model: secondChoice, in: storage)
        XCTAssertEqual(ModelKeys.selectedProvider(in: storage), .custom)
        XCTAssertEqual(ModelKeys.selectedModel(in: storage), secondChoice)
        XCTAssertEqual(CustomProviders.current(in: storage)?.id, second.id)

        ModelKeys.choose(.custom, model: firstChoice, in: storage)
        XCTAssertEqual(ModelKeys.selectedModel(in: storage), firstChoice)
        XCTAssertEqual(CustomProviders.current(in: storage)?.id, first.id)
    }

    func testVoiceHeaderMenuAnchorsBelowAvatar() throws {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        let window = try show(
            VStack(spacing: 0) {
                MessageListHeader(dark: true, openModel: {})
                Spacer()
            }
            .environment(app)
        )

        settle { self.menuButton(in: window, identifier: "chat.header.details") != nil }
        let button = try XCTUnwrap(
            menuButton(in: window, identifier: "chat.header.details"),
            "Voice header must host a native UIButton menu trigger anchored below the avatar header."
        )
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
        let container = try XCTUnwrap(button.superview)
        let headerFrameInWindow = container.convert(container.bounds, to: window)
        let buttonFrameInWindow = button.convert(button.bounds, to: window)
        let attachmentInWindow = button.convert(button.menuAttachmentPoint(for: configuration), to: window)

        XCTAssertEqual(buttonFrameInWindow.midX, headerFrameInWindow.midX, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(buttonFrameInWindow.minY, headerFrameInWindow.maxY)
        XCTAssertEqual(attachmentInWindow.x, headerFrameInWindow.midX, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(attachmentInWindow.y, headerFrameInWindow.maxY)
    }

    func testChatTopBarCapsulePreservesDetailsAccessibilityIdentifier() throws {
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), storage: storage.storage)
        let window = try show(
            PokiHead(
                status: PokiStatus(.ready),
                home: false,
                openModel: {},
                openDetails: {},
                openCustomization: {}
            )
            .environment(app)
            .environment(\.accessibilityEnabled, true)
        )

        settle { self.hasAccessibilityIdentifier("chat.header.details", in: window) }
        XCTAssertTrue(hasAccessibilityIdentifier("chat.header.details", in: window))
    }

    private func show(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func settle(for seconds: TimeInterval = 2, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func menuButton(in root: UIView, identifier: String) -> UIButton? {
        if let button = root as? UIButton,
           button.showsMenuAsPrimaryAction,
           button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in root.subviews {
            if let found = menuButton(in: subview, identifier: identifier) { return found }
        }
        return nil
    }

    private func flattenMenuElements(_ menu: UIMenu) -> [UIMenuElement] {
        var result: [UIMenuElement] = []
        for child in menu.children {
            result.append(child)
            if let submenu = child as? UIMenu {
                result.append(contentsOf: flattenMenuElements(submenu))
            }
        }
        return result
    }

    private func hasAccessibilityIdentifier(_ identifier: String, in root: NSObject) -> Bool {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        let selector = NSSelectorFromString("accessibilityIdentifier")
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            let id = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
            if id == identifier { return true }
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
        return false
    }
}
