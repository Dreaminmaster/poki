import XCTest
@testable import Poki

/// A probe that answers "connected" only when the test lets it, so a check can be in flight for as
/// long as the test wants (a timed-out connect to 10.7.0.1 takes seconds in the app).
@MainActor
private final class HeldProbe {
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    var isWaiting: Bool { !held.isEmpty }

    func answer(port: UInt16 = 49152) async -> ProbeResult {
        // This iPhone refuses ports nothing listens on, at once.
        if LoopbackMonitor.decoyPorts.contains(port) { return ProbeResult(label: "loopback", target: "10.7.0.1:\(port)", outcome: "refused", milliseconds: 2) }
        calls += 1
        await withCheckedContinuation { held.append($0) }
        return ProbeResult(label: "loopback", target: "10.7.0.1:49152", outcome: "connected", milliseconds: 4)
    }

    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
final class LoopbackMonitorTests: XCTestCase {
    private func yield(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// A probe that takes longer than the 3 s timer is always overlapped by the next timer tick. That
    /// tick must not throw the finished answer away: the first answer is published even though a tick
    /// arrived while it was in flight, however many rounds the probe takes.
    func testAnAnswerIsPublishedWhenTheTimerTicksWhileTheProbeIsInFlight() async {
        let held = HeldProbe()
        let monitor = LoopbackMonitor(probe: { _, port, _ in await held.answer(port: port) })
        defer { monitor.pause(); held.release() }
        monitor.check()
        for _ in 0..<5 where !monitor.isWorking {
            await yield { held.isWaiting }
            monitor.check()
            held.release()
            await yield { monitor.isWorking }
        }
        XCTAssertTrue(monitor.isWorking, "the answer of a probe that overlapped a timer tick was dropped, state: \(monitor.state)")
    }

    /// A proxy app that takes 10.7.0.1 for itself (Karing without TUN › Loopback address) accepts
    /// every connect, so the remote pairing port "answers" though this iPhone never sees it. The
    /// page must not say Working then, and must name the proxy's setting (report 2026-11-21).
    func testAProxyThatAcceptsEveryPortIsNotWorking() async {
        let monitor = LoopbackMonitor(probe: { _, port, _ in
            ProbeResult(label: "loopback", target: "10.7.0.1:\(port)", outcome: "connected", milliseconds: 1593)
        })
        defer { monitor.pause() }
        monitor.check()
        await yield { monitor.state != .checking }
        XCTAssertEqual(monitor.state, .noAnswer)
        XCTAssertTrue(monitor.proxyAnswers)
        XCTAssertFalse(monitor.isWorking)
        XCTAssertTrue(monitor.detail.contains("Karing"), monitor.detail)
    }

    /// The iPhone itself answers its own port and refuses one nothing listens on: Working.
    func testTheIPhoneAnsweringItsOwnPortIsWorking() async {
        let monitor = LoopbackMonitor(probe: { _, port, _ in
            ProbeResult(label: "loopback", target: "10.7.0.1:\(port)", outcome: LoopbackMonitor.decoyPorts.contains(port) ? "refused" : "connected", milliseconds: 4)
        })
        defer { monitor.pause() }
        monitor.check()
        await yield { monitor.state != .checking }
        XCTAssertTrue(monitor.isWorking, "state: \(monitor.state)")
        XCTAssertFalse(monitor.proxyAnswers)
    }
}
