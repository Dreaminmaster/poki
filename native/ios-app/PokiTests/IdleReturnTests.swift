import Foundation
import PokiCore
import XCTest
@testable import Poki

@MainActor
final class IdleReturnTests: XCTestCase {
    func testForegroundDuringIdleReturnKeepsAutomationUntilActivationAnswers() async throws {
        try XCTSkipUnless(AutomationPath.current == .inProcess, "Poki Runner path")
        InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
        let defaults = UserDefaults.standard
        let keys = ["relayAddress", "relayEnabled", "idleStopSeconds.v4"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let setup = SetupState.load()
        let session = FakeAutomation()
        let transport = IdleReturnTransport(session: session)
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: session, transport: transport)
        defer {
            model.stopSession()
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            setup.save()
        }
        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        model.startSession()
        model.idleStopSeconds = 60
        model.wakeRunner()
        await waitFor("prerequisites answered") { ["failed", "running"].contains(model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        await waitFor("automation opened") { model.hasOpenInProcessSession }

        let first = await model.runTool("look", arguments: "{}")
        XCTAssertFalse(first.isError, first.text)
        await waitFor("the read finished") { model.activityText == "Idle" }
        await transport.leaveOrigin()
        model.checkIdle(now: Date().addingTimeInterval(120))
        let returning = expectation(description: "return activation started")
        Task { await transport.waitForActivation(); returning.fulfill() }
        await fulfillment(of: [returning], timeout: 5)

        // UIKit delivers scene activation before XCTest answers the app activation request.
        model.becameActive()
        model.checkIdle(now: Date().addingTimeInterval(120))
        model.checkIdle(now: Date().addingTimeInterval(120))
        // Drain foreground and timer tasks while the activation is deliberately held open.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(session.isOpen, "foreground must not close the session used by the return")
        XCTAssertTrue(model.hasOpenInProcessSession)
        XCTAssertFalse(model.runnerPaused, "another idle tick must not pause an unfinished return")

        await transport.finishActivation()
        await waitFor("idle closes automation after the return") { model.runnerPaused && !session.isOpen }
        let activations = await transport.activationCount
        XCTAssertEqual(activations, 1)

        model.wakeRunner()
        await waitFor("the next prerequisite check answered") { ["failed", "running"].contains(model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        await waitFor("the next session opens") { model.hasOpenInProcessSession }
        let next = await model.runTool("look", arguments: "{}")
        XCTAssertFalse(next.isError, next.text)
        XCTAssertTrue(next.text.contains("General"), next.text)
    }

    private func waitFor(_ message: String, _ condition: @escaping () -> Bool) async {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = message
        await fulfillment(of: [done], timeout: 5)
    }
}

private actor IdleReturnTransport: HTTPTransport {
    private let screen: SessionScreenTransport
    private var atOrigin = true
    private var activation: CheckedContinuation<Void, Never>?
    private var activationWaiter: CheckedContinuation<Void, Never>?
    private(set) var activationCount = 0

    init(session: FakeAutomation) { screen = SessionScreenTransport(session: session) }
    func leaveOrigin() { atOrigin = false }
    func waitForActivation() async {
        if activationCount > 0 { return }
        await withCheckedContinuation { activationWaiter = $0 }
    }
    func finishActivation() {
        atOrigin = true
        activation?.resume()
        activation = nil
    }
    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        if url.path.hasSuffix("/wda/apps/activate") {
            activationCount += 1
            await withCheckedContinuation { continuation in
                activation = continuation
                activationWaiter?.resume()
                activationWaiter = nil
            }
        }
        if url.path.hasSuffix("/wda/activeAppInfo"), !atOrigin {
            let response: JSON = ["value": ["bundleId": "com.apple.calculator", "name": "Calculator"]]
            return (200, response.data())
        }
        return try await screen.send(method: method, url: url, body: body, timeout: timeout)
    }
}
