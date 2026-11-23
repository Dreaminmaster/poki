import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class HealthRelayLoopbackTests: XCTestCase {
    private var savedLanguage = AppLocalization.system
    private let defaultsKeys = [
        "chat.provider",
        "chat.customURL",
        "chat.customModel",
        "custom.providers",
        "chat.customProvider",
        "chat.model.custom",
        "chat.apiKey.anthropic",
        "chat.apiKey.openai",
        "chat.apiKey.gemini",
        "chat.apiKey.deepseek",
        "chat.apiKey.openrouter",
        "relayAddress",
        "relayEnabled",
        "wantsOn",
    ]
    private var savedDefaults: [String: Any] = [:]
    private var savedSetup = SetupState()
    private var savedKeychain: [String: Data?] = [:]
    private let keychainAccounts = [
        "api.anthropic",
        "api.openai",
        "api.gemini",
        "api.deepseek",
        "api.openrouter",
        "chatgpt.oauth.v1",
    ]

    override func setUp() async throws {
        savedLanguage = AppLocalization.shared.preference
        savedSetup = SetupState.load()
        for key in defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        for account in keychainAccounts { savedKeychain[account] = try? Keychain.read(account) }
    }

    override func tearDown() async throws {
        AppLocalization.shared.preference = savedLanguage
        for key in defaultsKeys { UserDefaults.standard.set(savedDefaults[key], forKey: key) }
        for (account, value) in savedKeychain {
            if let value { try? Keychain.write(value, account: account) }
            else { Keychain.delete(account) }
        }
        savedSetup.save()
    }

    private func clearModelKeysAndRelay() {
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        for account in keychainAccounts { Keychain.delete(account) }
    }

    private func makeModel(imageMounted: @escaping () -> Bool = { false }) -> AppModel {
        let model = AppModel(
            launcher: FakeLauncher(),
            pairer: FakePairing(),
            automation: FakeAutomation(),
            imageMounted: imageMounted
        )
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        return model
    }

    /// 1. Simplified and Traditional Chinese UI must localize `AppModel.noRelay` in both
    /// `Issue.current(model)` ("需要处理") and `SetupSettingsPage` without leaking raw English.
    func testChineseUILocalizesNoRelayProblemInIssuesAndSetup() async throws {
        clearModelKeysAndRelay()
        XCTAssertFalse(ModelKeys.hasUsableKey, "test precondition: no usable model key")

        let model = makeModel()
        defer { model.stopSession() }
        model.setup.loopback = .proxy
        model.loopback.simulate(.working(ms: 12))
        model.startSession()

        XCTAssertEqual(model.problem, AppModel.noRelay)

        AppLocalization.shared.preference = "zh-Hans"
        let issues = Issue.current(model)
        let problemIssue = try XCTUnwrap(issues.first { $0.id == "problem" })
        XCTAssertEqual(problemIssue.title, "需要处理")
        XCTAssertTrue(problemIssue.text.contains("外部连接"), "expected zh-Hans translation, got: \(problemIssue.text)")
        XCTAssertTrue(problemIssue.text.contains("远程连接服务"), "expected zh-Hans translation, got: \(problemIssue.text)")
        XCTAssertFalse(problemIssue.text.contains("Enter your relay"), "raw English leaked: \(problemIssue.text)")
        XCTAssertFalse(problemIssue.text.contains("External Connections"), "raw English leaked: \(problemIssue.text)")

        let setupLabels = try await renderedLabels(
            of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) },
            model: model
        )
        XCTAssertTrue(setupLabels.contains { $0.contains("外部连接") && $0.contains("远程连接服务") },
                      "Setup footer must localize noRelay in zh-Hans: \(setupLabels)")
        XCTAssertFalse(setupLabels.contains { $0.contains("Enter your relay") || $0.contains("External Connections") },
                       "Setup footer must not leak English noRelay: \(setupLabels)")

        AppLocalization.shared.preference = "zh-Hant"
        let traditionalIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "problem" })
        XCTAssertTrue(traditionalIssue.text.contains("外部連線"), "expected zh-Hant translation, got: \(traditionalIssue.text)")
        XCTAssertFalse(traditionalIssue.text.contains("Enter your relay"), "raw English leaked: \(traditionalIssue.text)")
    }

    /// 2. Simplified Chinese UI must localize `RelayStatus.offline(why)` in `RelayView` and
    /// `Issue.current(model)`, and turning off the relay switch must show `.off` rather than `.offline("stopped")`.
    func testChineseUILocalizesRelayOfflineStatusAndDisablingRelayClearsOfflineIssue() async throws {
        clearModelKeysAndRelay()
        AppLocalization.shared.preference = "zh-Hans"

        let model = makeModel()
        defer { model.stopSession() }
        model.setup.loopback = .proxy
        model.loopback.simulate(.working(ms: 12))
        XCTAssertTrue(model.setRelay("http://127.0.0.1:1"))
        model.startSession()

        let offline = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { model.relayStatus.isOffline }
        }, object: nil)
        await fulfillment(of: [offline], timeout: 10)

        let relayLabels = try await renderedLabels(
            of: NavigationStack { RelayView(back: {}) },
            model: model
        )
        let joined = relayLabels.joined(separator: " | ")
        XCTAssertTrue(relayLabels.contains { $0.contains("离线") }, "RelayView must show localized Offline status: \(joined)")
        for leaked in ["Error Domain=", "NSURLErrorDomain", "Could not connect", "Connection refused", "the relay", "stopped"] {
            XCTAssertFalse(joined.contains(leaked), "RelayView leaked raw English '\(leaked)': \(joined)")
        }

        let relayIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "relay" })
        XCTAssertEqual(relayIssue.title, "智能体无法连接此 iPhone")
        for leaked in ["Error Domain=", "NSURLErrorDomain", "Could not connect", "the relay"] {
            XCTAssertFalse(relayIssue.text.contains(leaked), "Issue.current relay text leaked English '\(leaked)': \(relayIssue.text)")
        }

        // Turning off the relay while Poki is on must move relayStatus to .off, not .offline("stopped").
        model.setRelayEnabled(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.relayStatus, .off, "disabling relay must not remain .offline(\"stopped\")")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "relay" },
                       "disabling relay intentionally must not show an offline issue")
    }

    /// 3. Stale loopback/tunnel `problem` and `tunnelAttention` must automatically clear once
    /// `loopback.isWorking` becomes true or the user switches to an external connection, while
    /// preserving unrelated problems like `noRelay`.
    func testWorkingLoopbackClearsStaleLoopbackProblemAndTunnelAttention() {
        let model = makeModel()
        defer { model.stopSession() }

        // Launch race: startSession runs while setup.loopback == .none and loopback is still .checking.
        model.setup.loopback = .none
        model.startSession()
        XCTAssertEqual(model.problem, "Choose and enable a local connection first (Setup).")
        XCTAssertTrue(Issue.current(model).contains { $0.id == "problem" })

        // External proxy answers 10.7.0.1.
        model.loopback.simulate(.working(ms: 1591))
        XCTAssertEqual(model.setup.loopback, .proxy)
        XCTAssertNil(model.problem, "working loopback must clear stale local-connection problem")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "problem" || $0.id == "loopback" },
                       "Settings issues must not retain stale loopback problem once 10.7.0.1 answers")

        // Another-VPN tunnelAttention set while loopback is down must clear once external loopback works.
        model.loopback.simulate(.off)
        let vpnMessage = "Another VPN appears to be on, so Poki did not turn its local connection back on. Turn that VPN off and tap Enable Local Connection, or choose an external connection in Setup."
        model.tunnel.onAttention?(vpnMessage)
        XCTAssertEqual(model.problem, vpnMessage)
        XCTAssertTrue(Issue.current(model).contains { $0.id == "problem" })

        model.loopback.simulate(.working(ms: 1591))
        XCTAssertNil(model.problem, "working loopback must clear stale tunnelAttention")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "problem" || $0.id == "loopback" })

        // A late tunnelAttention while external loopback is already working must not resurrect the error.
        model.tunnel.onAttention?(vpnMessage)
        XCTAssertNil(model.problem, "late tunnelAttention must not overwrite working external loopback")

        // Switching to external connection while down also clears built-in tunnelAttention.
        model.loopback.simulate(.off)
        model.tunnel.onAttention?(vpnMessage)
        XCTAssertEqual(model.problem, vpnMessage)
        model.chooseConnection(.proxy)
        XCTAssertNil(model.problem, "choosing external proxy must clear built-in VPN attention")

        // Non-loopback problem (noRelay) must NOT be cleared when loopback recovers.
        clearModelKeysAndRelay()
        let noRelayModel = makeModel()
        defer { noRelayModel.stopSession() }
        noRelayModel.setup.loopback = .proxy
        noRelayModel.loopback.simulate(.off)
        noRelayModel.startSession()
        XCTAssertEqual(noRelayModel.problem, AppModel.noRelay)
        noRelayModel.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(noRelayModel.problem, AppModel.noRelay, "loopback recovery must not clear unrelated noRelay problem")
    }

    /// 4. When an external proxy is already serving 10.7.0.1 (or `canStartTasks` becomes true via
    /// mounted image / `local_ddi`), starting or running Poki must not false-report a loopback error.
    func testWorkingExternalLoopbackOrCanStartTasksDoesNotFalseReportLoopbackError() {
        AppLocalization.shared.preference = "zh-Hans"
        ModelKeys.customURL = "http://127.0.0.1:9/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom

        // External proxy working even if saved setup.loopback still says .builtIn while local VPN is not connected.
        let model = makeModel()
        defer { model.stopSession() }
        model.setup.loopback = .builtIn
        model.loopback.simulate(.working(ms: 1591))
        model.startSession(reconnectLocal: false)

        XCTAssertTrue(model.sessionOn, "working external loopback must allow session start without local VPN error")
        XCTAssertNil(model.problem, "working external loopback must not set a local connection problem")
        XCTAssertEqual(Health.loopback(model).word, "开启")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "problem" || $0.id == "loopback" || $0.id == "proxy" },
                       "Issues must not show loopback error when external proxy answers: \(Issue.current(model).map(\.id))")

        // Stale loopback problem set while loopback was down clears once local_ddi makes canStartTasks true.
        let ddiModel = makeModel(imageMounted: { true })
        defer { ddiModel.stopSession() }
        ddiModel.setup.loopback = .none
        ddiModel.loopback.simulate(.noAnswer)
        ddiModel.startSession()
        XCTAssertNotNil(ddiModel.problem)

        ddiModel.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        XCTAssertTrue(ddiModel.canStartTasks)
        XCTAssertNil(ddiModel.problem, "canStartTasks via local_ddi must clear stale loopback problem")
        XCTAssertFalse(Issue.current(ddiModel).contains { $0.id == "problem" || $0.id == "loopback" })
    }

    // MARK: - Helpers

    private func renderedLabels<Content: View>(of view: Content, model: AppModel) async throws -> [String] {
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 1600)
        window.rootViewController = UIHostingController(
            rootView: view.environment(model).environment(chat).environment(\.accessibilityEnabled, true)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        return Self.collectLabels(in: window)
    }

    private static func collectLabels(in root: NSObject) -> [String] {
        var labels: [String] = []
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if let label = item.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let value = item.accessibilityValue, !value.isEmpty { labels.append(value) }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return labels
    }
}
