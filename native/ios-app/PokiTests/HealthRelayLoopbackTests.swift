import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class HealthRelayLoopbackTests: XCTestCase {
    private var savedLanguage = AppLocalization.system
    private var storage: IsolatedTestStorage!

    override func setUp() async throws {
        savedLanguage = AppLocalization.shared.preference
        storage = try IsolatedTestStorage(prefix: "health-relay-loopback")
        storage.activate()
    }

    override func tearDown() async throws {
        AppLocalization.shared.preference = savedLanguage
        if let storage {
            self.storage = nil
            try storage.tearDown()
        }
    }

    private func resetIsolatedState() throws {
        try storage.reset()
    }

    private func makeModel(
        imageMounted: @escaping () -> Bool = { false },
        localVPNAvailable: Bool? = nil
    ) -> AppModel {
        let model = AppModel(
            launcher: FakeLauncher(),
            pairer: FakePairing(),
            automation: FakeAutomation(),
            imageMounted: imageMounted,
            localVPNAvailable: localVPNAvailable
        )
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        return model
    }

    /// 1. Simplified and Traditional Chinese UI must localize `AppModel.noRelay` in
    /// `Issue.current(model)`, `PokiDetailsView` ("需要处理"), and `SetupSettingsPage` without raw English.
    func testChineseUILocalizesNoRelayProblemInIssuesDetailsAndSetup() async throws {
        try resetIsolatedState()
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

        let detailsLabels = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: model,
            waitFor: { $0.contains { $0.contains("需要处理") } }
        )
        XCTAssertTrue(detailsLabels.contains { $0.contains("外部连接") && $0.contains("远程连接服务") },
                      "PokiDetailsView must render localized zh-Hans noRelay: \(detailsLabels)")
        XCTAssertFalse(detailsLabels.contains { $0.contains("Enter your relay") || $0.contains("External Connections") },
                       "PokiDetailsView must not leak English noRelay: \(detailsLabels)")

        let setupLabels = try await renderedLabels(
            of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) },
            model: model,
            waitFor: { $0.contains { $0.contains("外部连接") } }
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

    /// 2. Simplified Chinese UI must localize `RelayStatus.offline(why)` across `RelayView`,
    /// `AgentsAndRelayView`, `AgentsView`, and `Issue.current(model)`, and disabling the relay switch
    /// must settle to `.off` (not `.offline("stopped")`) and remove the offline issue.
    func testChineseUILocalizesRelayOfflineStatusAcrossViewsAndDisablingClearsIssue() async throws {
        try resetIsolatedState()
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

        let leakedTokens = ["Error Domain=", "NSURLErrorDomain", "Could not connect", "Connection refused", "the relay", "stopped"]

        let relayLabels = try await renderedLabels(
            of: NavigationStack { RelayView(back: {}) },
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let relayJoined = relayLabels.joined(separator: " | ")
        XCTAssertTrue(relayLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "RelayView must show localized Offline reason: \(relayJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(relayJoined.contains(leaked), "RelayView leaked raw English '\(leaked)': \(relayJoined)")
        }

        let detailsAgentsLabels = try await renderedLabels(
            of: NavigationStack { AgentsAndRelayView(path: .constant(NavigationPath())) },
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let detailsAgentsJoined = detailsAgentsLabels.joined(separator: " | ")
        XCTAssertTrue(detailsAgentsLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "AgentsAndRelayView must show localized Offline reason: \(detailsAgentsJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(detailsAgentsJoined.contains(leaked), "AgentsAndRelayView leaked raw English '\(leaked)': \(detailsAgentsJoined)")
        }

        let tabAgentsLabels = try await renderedLabels(
            of: AgentsView(path: .constant(NavigationPath()), openSession: { _ in }),
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let tabAgentsJoined = tabAgentsLabels.joined(separator: " | ")
        XCTAssertTrue(tabAgentsLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "AgentsView must show localized Offline reason: \(tabAgentsJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(tabAgentsJoined.contains(leaked), "AgentsView leaked raw English '\(leaked)': \(tabAgentsJoined)")
        }

        let relayIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "relay" })
        XCTAssertEqual(relayIssue.title, "智能体无法连接此 iPhone")
        XCTAssertTrue(relayIssue.text.contains("无法连接到远程连接服务"), relayIssue.text)
        for leaked in leakedTokens {
            XCTAssertFalse(relayIssue.text.contains(leaked), "Issue.current relay text leaked English '\(leaked)': \(relayIssue.text)")
        }

        // Disabling relay while session is on must settle to .off and never re-enter .offline("stopped").
        model.setRelayEnabled(false)
        let turnedOff = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                model.relayStatus == .off && model.log.lines.contains { $0.contains("[relay] turned off") }
            }
        }, object: nil)
        await fulfillment(of: [turnedOff], timeout: 5)

        let disabledRelayLabels = try await renderedLabels(
            of: NavigationStack { RelayView(back: {}) },
            model: model,
            waitFor: { $0.contains { $0.contains("关闭") } }
        )
        XCTAssertEqual(model.relayStatus, .off, "disabling relay must stay .off after core.stop() settles")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "relay" },
                       "disabling relay intentionally must not show an offline issue")
        XCTAssertFalse(disabledRelayLabels.joined(separator: " | ").contains("离线"),
                       "RelayView must show Off instead of Offline when disabled: \(disabledRelayLabels)")
    }

    /// 3. Stale loopback/tunnel `problem` and `tunnelAttention` must automatically clear once
    /// `loopback.isWorking` becomes true or the user switches to an external connection, while
    /// preserving unrelated problems like `noRelay`. Both `PokiDetailsView` and `SetupSettingsPage`
    /// must stop showing the stale loopback banner after recovery.
    func testWorkingLoopbackClearsStaleLoopbackProblemAndTunnelAttention() async throws {
        AppLocalization.shared.preference = "zh-Hans"
        ModelKeys.customURL = "http://127.0.0.1:9/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom

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

        let recoveredDetails = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: model,
            waitFor: { $0.contains { $0.contains("外部连接") } }
        )
        XCTAssertFalse(recoveredDetails.contains { $0.contains("需要处理") || $0.contains("选择并开启本地连接") },
                       "PokiDetailsView must not show stale loopback issue after recovery: \(recoveredDetails)")

        let recoveredSetup = try await renderedLabels(
            of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) },
            model: model,
            waitFor: { $0.contains { $0.contains("自动化") } }
        )
        XCTAssertFalse(recoveredSetup.contains { $0.contains("选择并开启本地连接") || $0.contains("内置本地连接已关闭") },
                       "SetupSettingsPage must not show stale loopback footer after recovery: \(recoveredSetup)")

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
        try resetIsolatedState()
        let noRelayModel = makeModel()
        defer { noRelayModel.stopSession() }
        noRelayModel.setup.loopback = .proxy
        noRelayModel.loopback.simulate(.off)
        noRelayModel.startSession()
        XCTAssertEqual(noRelayModel.problem, AppModel.noRelay)
        noRelayModel.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(noRelayModel.problem, AppModel.noRelay, "loopback recovery must not clear unrelated noRelay problem")
    }

    /// 4. External proxy working (including test-signed external builds with `local VPN: unavailable`
    /// and builds where built-in tunnel previously failed) or `canStartTasks` via `local_ddi` must not
    /// false-report loopback or stale built-in tunnel errors in `Issue.current`, `PokiDetailsView`,
    /// `SetupSettingsPage`, or `SetupStepPage(step: .loopback)`.
    func testWorkingExternalLoopbackHidesStaleBuiltInTunnelErrorAndExternalBuildIssues() async throws {
        AppLocalization.shared.preference = "zh-Hans"
        ModelKeys.customURL = "http://127.0.0.1:9/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom

        // External build (`local VPN: unavailable`): stale `.builtIn` with working external proxy
        // must auto-migrate to `.proxy` and show clean Settings and Setup UI.
        let externalBuildModel = makeModel(localVPNAvailable: false)
        defer { externalBuildModel.stopSession() }
        externalBuildModel.setup.loopback = .builtIn
        externalBuildModel.loopback.simulate(.working(ms: 1591))
        externalBuildModel.startSession(reconnectLocal: false)

        XCTAssertEqual(externalBuildModel.setup.loopback, .proxy)
        XCTAssertTrue(externalBuildModel.sessionOn, "working external loopback must allow session start")
        XCTAssertNil(externalBuildModel.problem, "working external loopback must not set a local connection problem")
        XCTAssertEqual(Health.loopback(externalBuildModel).word, "开启")
        XCTAssertFalse(Issue.current(externalBuildModel).contains { $0.id == "problem" || $0.id == "loopback" || $0.id == "proxy" })

        let externalDetailsLabels = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: externalBuildModel,
            waitFor: { $0.contains { $0.contains("外部连接") } }
        )
        XCTAssertFalse(externalDetailsLabels.contains { $0.contains("需要处理") || $0.contains("本地连接已关闭") },
                       "PokiDetailsView must not show loopback error on working external build: \(externalDetailsLabels)")

        let externalSetupLabels = try await renderedLabels(
            of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) },
            model: externalBuildModel,
            waitFor: { $0.contains { $0.contains("自动化") } }
        )
        XCTAssertFalse(externalSetupLabels.contains { $0.contains("内置本地连接已关闭") || $0.contains("选择并开启本地连接") },
                       "SetupSettingsPage must not show loopback error on working external build: \(externalSetupLabels)")

        // Built-in build (`tunnel.available == true`) with persisted `.builtIn` whose tunnel failed:
        // once external proxy loopback answers 10.7.0.1, `loopbackChanged` must migrate `setup.loopback`
        // to `.proxy` without manual override, and `SetupStepPage(step: .loopback)` must show working
        // status while hiding the stale `.failed` built-in tunnel alert.
        let tunnelModel = makeModel()
        defer { tunnelModel.loopback.pause(); tunnelModel.stopSession() }
        XCTAssertTrue(tunnelModel.tunnel.available, "full test app embeds PokiTunnel")
        tunnelModel.setup.loopback = .builtIn
        do { try await tunnelModel.tunnel.connect() } catch { }
        guard case .failed = tunnelModel.tunnel.state else {
            return XCTFail("expected simulator tunnel.connect() to enter .failed, got \(tunnelModel.tunnel.state)")
        }
        tunnelModel.loopback.simulate(.working(ms: 1591))
        XCTAssertEqual(tunnelModel.setup.loopback, .proxy,
                       "working external loopback must migrate stale .builtIn choice to .proxy when built-in tunnel is not connected")
        XCTAssertNil(tunnelModel.problem)

        let loopbackStepLabels = try await renderedLabels(
            of: NavigationStack { SetupStepPage(step: .loopback) },
            model: tunnelModel,
            waitFor: { $0.contains { $0.contains("本地连接已开启") } }
        )
        let loopbackStepJoined = loopbackStepLabels.joined(separator: " | ")
        XCTAssertTrue(loopbackStepLabels.contains { $0.contains("本地连接已开启") },
                      "Loopback step must show working status: \(loopbackStepJoined)")
        XCTAssertFalse(loopbackStepJoined.contains("模拟器不支持") || loopbackStepJoined.contains("The local VPN needs"),
                       "Loopback step must hide stale built-in tunnel error while external loopback works: \(loopbackStepJoined)")

        // Even if `.builtIn` is still present while external loopback is already working, opening
        // `SetupStepPage(step: .loopback)` or `SetupView` must NOT auto-dial the built-in tunnel,
        // and `startSession` must migrate `.builtIn` to `.proxy` when `!tunnel.connected && !tunnel.busy`.
        let guardStepModel = makeModel()
        defer { guardStepModel.loopback.pause(); guardStepModel.stopSession() }
        XCTAssertTrue(guardStepModel.tunnel.available)
        XCTAssertEqual(guardStepModel.tunnel.state, .off)
        guardStepModel.loopback.simulate(.working(ms: 1591))
        guardStepModel.setup.loopback = .builtIn

        _ = try await renderedLabels(
            of: NavigationStack { SetupStepPage(step: .loopback) },
            model: guardStepModel,
            waitFor: { $0.contains { $0.contains("本地连接已开启") } }
        )
        await Task.yield()
        XCTAssertEqual(guardStepModel.tunnel.state, .off,
                       "SetupStepPage(.loopback) must not auto-connect built-in tunnel while external loopback is working")

        let guardSetupViewModel = makeModel()
        defer { guardSetupViewModel.loopback.pause(); guardSetupViewModel.stopSession() }
        XCTAssertTrue(guardSetupViewModel.tunnel.available)
        XCTAssertEqual(guardSetupViewModel.tunnel.state, .off)
        guardSetupViewModel.loopback.simulate(.working(ms: 1591))
        guardSetupViewModel.setup.loopback = .builtIn

        if let loopbackIndex = SetupStep.shown.firstIndex(of: .loopback) {
            _ = try await renderedLabels(
                of: SetupView(start: loopbackIndex),
                model: guardSetupViewModel,
                waitFor: { _ in true }
            )
            await Task.yield()
            XCTAssertEqual(guardSetupViewModel.tunnel.state, .off,
                           "SetupView(.loopback) must not auto-connect built-in tunnel while external loopback is working")
        }

        let startSessionModel = makeModel()
        defer { startSessionModel.loopback.pause(); startSessionModel.stopSession() }
        XCTAssertTrue(startSessionModel.tunnel.available)
        XCTAssertEqual(startSessionModel.tunnel.state, .off)
        startSessionModel.loopback.simulate(.working(ms: 1591))
        startSessionModel.setup.loopback = .builtIn
        startSessionModel.startSession(reconnectLocal: false)
        XCTAssertEqual(startSessionModel.setup.loopback, .proxy,
                       "startSession must migrate .builtIn to .proxy when external loopback works and built-in tunnel is not connected")
        XCTAssertTrue(startSessionModel.sessionOn)
        XCTAssertNil(startSessionModel.problem)
        XCTAssertEqual(startSessionModel.tunnel.state, .off)

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

    /// 5. All PokiCore `RelayStatus.offline(why)` reasons (including unknown short English words)
    /// and pairing-refusal reasons (via `Issue.localizedProblem` and `Issue.current(model)` /
    /// `PokiDetailsView`) must render cleanly in Chinese with ZERO raw English reason leaks.
    func testAllRelayOfflineAndPairingReasonsNeverLeakRawEnglishInChinese() async throws {
        let relaySamples: [(raw: String, expectedZhHans: String)] = [
            ("stopped", "已停止"),
            ("Poki is shutting down", "Poki 正在关闭"),
            ("connecting to the relay did not finish within 15 s", "连接远程连接服务超时"),
            ("the relay's challenge did not finish within 15 s", "远程连接服务响应超时"),
            ("the relay's ready did not finish within 15 s", "远程连接服务响应超时"),
            ("the relay sent no challenge", "远程连接服务返回了异常响应"),
            ("the relay refused the phone: bad_signature", "远程连接服务认证失败"),
            ("the relay refused the phone: 403", "远程连接服务拒绝了此 iPhone（403）"),
            ("the relay refused the phone: rejected", "远程连接服务拒绝了此 iPhone 的连接"),
            ("the relay refused the phone: unsupported_version", "远程连接服务协议版本不兼容"),
            ("the relay closed the connection: replaced", "连接已被新会话替代"),
            ("the relay closed the connection: timeout", "远程连接服务响应超时"),
            ("the relay closed the connection: overloaded", "远程连接服务暂时繁忙"),
            ("the relay closed the connection: unexpected_eof", "远程连接服务关闭了连接"),
            ("the relay closed the connection: no reason", "远程连接服务关闭了连接"),
            ("Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"", "无网络连接"),
            ("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"", "连接超时"),
            ("Error Domain=NSURLErrorDomain Code=-1003 \"A server with the specified hostname could not be found.\"", "找不到远程连接服务地址"),
            ("Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\"", "无法连接到远程连接服务"),
            ("Error Domain=NSPOSIXErrorDomain Code=57 \"Socket is not connected\"", "连接已中断"),
            ("Error Domain=NSURLErrorDomain Code=-1200 \"An SSL error has occurred\"", "安全连接失败"),
            ("some unrecognized upstream failure", "连接失败"),
        ]

        AppLocalization.shared.preference = "zh-Hans"
        for sample in relaySamples {
            let reason = Health.relayOfflineReason(sample.raw)
            XCTAssertEqual(reason, sample.expectedZhHans, "raw: \(sample.raw)")
            let statusText = Health.relayStatusText(.offline(sample.raw))
            XCTAssertTrue(statusText.hasPrefix("离线"), "statusText: \(statusText)")
            XCTAssertTrue(statusText.contains(sample.expectedZhHans), "statusText: \(statusText)")
            for leaked in ["Error Domain=", "rejected", "unexpected_eof", "unsupported_version", "overloaded", "timeout"] {
                XCTAssertFalse(statusText.contains(leaked), "raw English '\(leaked)' leaked into: \(statusText)")
            }
        }

        // Pairing refusal via `Issue.localizedProblem` must translate known reasons and drop unknown English.
        let refusedCert = Issue.localizedProblem("The phone refused the pairing (invalid cert). Pair again in Setup.")
        XCTAssertTrue(refusedCert.contains("重新配对") && refusedCert.contains("配对证书已失效或不受信任"), refusedCert)
        XCTAssertFalse(refusedCert.contains("invalid cert") || refusedCert.contains("The phone refused"), refusedCert)

        let refusedUnknown = Issue.localizedProblem("The phone refused the pairing (x509 verify mismatch). Pair again in Setup.")
        XCTAssertTrue(refusedUnknown.contains("重新配对"), refusedUnknown)
        XCTAssertFalse(refusedUnknown.contains("x509") || refusedUnknown.contains("mismatch") || refusedUnknown.contains("The phone refused"), refusedUnknown)

        // Pairing trouble surfaced through `Issue.current(model)` and `PokiDetailsView` must also hide raw English.
        ModelKeys.customURL = "http://127.0.0.1:9/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let model = makeModel()
        defer { model.stopSession() }
        model.setup.loopback = .proxy
        model.loopback.simulate(.working(ms: 12))
        model.startSession()
        model.wakeRunner()
        model.runnerChanged(RunnerStatus(state: "failed", detail: "invalid cert from peer", code: "pairing"))

        let pairingIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "pairing" })
        XCTAssertEqual(pairingIssue.title, "重新配对此 iPhone")
        XCTAssertTrue(pairingIssue.text.contains("配对证书已失效或不受信任"), pairingIssue.text)
        XCTAssertFalse(pairingIssue.text.contains("invalid cert"), "raw English leaked in pairing issue: \(pairingIssue.text)")

        let detailsLabels = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: model,
            waitFor: { $0.contains { $0.contains("重新配对此 iPhone") } }
        )
        let detailsJoined = detailsLabels.joined(separator: " | ")
        XCTAssertTrue(detailsJoined.contains("配对证书已失效或不受信任"), "PokiDetailsView must localize pairing reason: \(detailsJoined)")
        XCTAssertFalse(detailsJoined.contains("invalid cert"), "PokiDetailsView leaked raw English pairing reason: \(detailsJoined)")

        // Unrecognized English pairing detail must also be summarized cleanly in Chinese without leaking raw text.
        model.runnerChanged(RunnerStatus(state: "failed", detail: "x509 verify mismatch", code: "pairing"))
        let unknownPairingIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "pairing" })
        XCTAssertTrue(unknownPairingIssue.text.contains("重新配对"), unknownPairingIssue.text)
        XCTAssertFalse(unknownPairingIssue.text.contains("x509") || unknownPairingIssue.text.contains("mismatch"),
                       "unrecognized English pairing reason leaked: \(unknownPairingIssue.text)")

        AppLocalization.shared.preference = "zh-Hant"
        XCTAssertEqual(Health.relayOfflineReason("Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\""), "無法連線至遠端連線服務")
        XCTAssertEqual(Health.relayOfflineReason("the relay refused the phone: rejected"), "遠端連線服務拒絕了此 iPhone 的連線")
        let refusedCertHant = Issue.localizedProblem("The phone refused the pairing (invalid cert). Pair again in Setup.")
        XCTAssertTrue(refusedCertHant.contains("重新配對") && refusedCertHant.contains("配對憑證已失效或不受信任"), refusedCertHant)
        XCTAssertFalse(refusedCertHant.contains("invalid cert"), refusedCertHant)
    }

    /// 6. Isolated test storage keeps a pre-configured host's real credentials and preferences intact
    /// while establishing an empty `ModelKeys.hasUsableKey == false` precondition inside the nested test scope.
    func testIsolatedStoragePreservesPreconfiguredHostCredentialsAndPreferences() throws {
        // Seed the outer test scope as a simulated pre-configured host with real model-key.* and preferences.
        try ModelKeys.save("test-host-openai-credential", for: .openai)
        ModelKeys.selectedProvider = .openai
        RelayAddress.saved = RelayAddress("https://host-relay.example")
        XCTAssertTrue(ModelKeys.hasUsableKey)

        let inner = try IsolatedTestStorage(prefix: "health-relay-inner")
        defer { try? inner.tearDown() }
        try PokiStorage.withScope(inner.scope) {
            XCTAssertFalse(ModelKeys.hasUsableKey, "inner isolated scope must not inherit host model keys")
            XCTAssertNil(RelayAddress.saved, "inner isolated scope must not inherit host relay address")
            let model = makeModel()
            defer { model.stopSession() }
            model.setup.loopback = .proxy
            model.loopback.simulate(.working(ms: 12))
            model.startSession()
            XCTAssertEqual(model.problem, AppModel.noRelay)
        }

        XCTAssertEqual(ModelKeys.key(.openai), "test-host-openai-credential")
        XCTAssertEqual(ModelKeys.selectedProvider, .openai)
        XCTAssertEqual(RelayAddress.saved?.origin.absoluteString, "https://host-relay.example")
        XCTAssertTrue(ModelKeys.hasUsableKey)
    }

    // MARK: - Helpers

    private func renderedLabels<Content: View>(
        of view: Content,
        model: AppModel,
        waitFor condition: @escaping ([String]) -> Bool = { !$0.isEmpty }
    ) async throws -> [String] {
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 1800)
        window.rootViewController = UIHostingController(
            rootView: view
                .environment(model)
                .environment(chat)
                .environment(\.locale, AppLocalization.locale)
                .environment(\.accessibilityEnabled, true)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let drawn = expectation(description: "rendered SwiftUI frame")
        let frames = DisplayFrameObserver { drawn.fulfill() }
        let display = CADisplayLink(target: frames, selector: #selector(DisplayFrameObserver.tick))
        display.add(to: .main, forMode: .common)
        await fulfillment(of: [drawn], timeout: 5)
        display.invalidate()

        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                window.layoutIfNeeded()
                return condition(Self.collectLabels(in: window))
            }
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
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

private final class DisplayFrameObserver: NSObject {
    private var remaining = 2
    private let onDone: () -> Void
    init(onDone: @escaping () -> Void) { self.onDone = onDone }
    @objc func tick() {
        remaining -= 1
        if remaining == 0 { onDone() }
    }
}
