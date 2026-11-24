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

/// A proxy that accepts every port until the owner fixes its setting; counts the extra ports tried.
@MainActor
private final class ProxyFixture {
    var fixed = false
    private(set) var decoys = 0

    func answer(_ port: UInt16) -> ProbeResult {
        let decoy = LoopbackMonitor.decoyPorts.contains(port)
        if decoy { decoys += 1 }
        return ProbeResult(label: "loopback", target: "10.7.0.1:\(port)", outcome: decoy && fixed ? "refused" : "connected", milliseconds: 3)
    }
}

@MainActor
final class LoopbackMonitorTests: XCTestCase {
    func testOwnerDisconnectCancelsReconnectWhileOldTunnelStops() async {
        var ownerWantsConnection = true
        var sleeps = 0
        let mayReconnect = await LoopbackTunnel.waitForDisconnect(isDisconnecting: { true }, wanted: { ownerWantsConnection }, sleep: {
            sleeps += 1
            ownerWantsConnection = false
        })
        XCTAssertFalse(mayReconnect)
        XCTAssertEqual(sleeps, 1)
    }

    private func yield(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    func testOldProbeDoesNotStartLockdownCheckAfterNetworkChanges() async {
        var ports: [UInt16] = []
        var first: CheckedContinuation<Void, Never>?
        let monitor = LoopbackMonitor(probe: { _, port, _ in
            ports.append(port)
            if ports.count == 1 {
                await withCheckedContinuation { first = $0 }
                return ProbeResult(label: "loopback", target: "old", outcome: "refused", milliseconds: 1)
            }
            return ProbeResult(label: "loopback", target: "new", outcome: "connected", milliseconds: 1)
        })
        defer { monitor.pause(); first?.resume() }
        monitor.check()
        await yield { first != nil }
        XCTAssertNotNil(first)
        monitor.simulateNetworkChange()
        let continuation = first
        first = nil
        continuation?.resume()
        await yield { ports.count >= 2 }
        XCTAssertGreaterThanOrEqual(ports.count, 2)
        XCTAssertEqual(ports.first, ports.dropFirst().first, "A stale refusal must trigger a fresh pairing probe, not a lockdown check")
    }

    func testInvalidatedThirdSearchIsRetriedOnNewTunnelPath() async {
        var browsing: CheckedContinuation<(ports: [UInt16], problem: String?), Never>?
        var searches = 0
        let monitor = LoopbackMonitor(probe: { _, port, _ in
            ProbeResult(label: "test", target: "test", outcome: port == 62078 ? "connected" : "refused", milliseconds: 1)
        }, browsePorts: {
            searches += 1
            if searches == 1 { return await withCheckedContinuation { browsing = $0 } }
            return ([], nil)
        }, observeNetwork: false)
        defer { monitor.pause(); browsing?.resume(returning: ([], nil)); RemotePairingPort.setSearching(false) }
        monitor.simulateSearchBudget(2)
        monitor.check()
        await yield { browsing != nil }
        XCTAssertNotNil(browsing)
        XCTAssertTrue(RemotePairingPort.searching, "The launcher fallback remains suspended during the lookup")
        monitor.simulateNetworkChange(physical: false)
        let held = browsing
        browsing = nil
        held?.resume(returning: ([], nil))
        await yield { searches >= 2 }
        XCTAssertEqual(searches, 2, "The invalidated third search must be retried")
        await yield { !RemotePairingPort.searching }
        XCTAssertFalse(RemotePairingPort.searching, "An exhausted retry must release the launcher fallback")
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

    /// While a proxy keeps answering on the same network, the timer does not open the extra ports on
    /// every check (review on #671). Once the owner fixes the proxy's setting, the next recheck
    /// turns the page green.
    func testAProxyIsProbedOncePerNetworkAndTheFixIsSeen() async {
        let proxy = ProxyFixture()
        let monitor = LoopbackMonitor(probe: { _, port, _ in await proxy.answer(port) })
        defer { monitor.pause() }
        func checkOnce() async {
            let before = monitor.checkedAt
            monitor.check()
            await yield { monitor.checkedAt != before && monitor.state != .checking }
        }
        // The path monitors report the simulator's network once at start, as a new network.
        await checkOnce()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await checkOnce()
        XCTAssertTrue(monitor.proxyAnswers)
        let settled = proxy.decoys
        for _ in 0..<5 { await checkOnce() }
        XCTAssertTrue(monitor.proxyAnswers)
        XCTAssertEqual(proxy.decoys, settled, "the extra ports are not opened again on every check")

        proxy.fixed = true
        monitor.proxyRecheck = 0
        let before = monitor.checkedAt
        monitor.check()
        await yield { monitor.checkedAt != before && monitor.isWorking }
        XCTAssertTrue(monitor.isWorking, "state: \(monitor.state)")
        XCTAssertFalse(monitor.proxyAnswers)
    }

    /// The two extra ports are never the same port drawn twice.
    func testTheTwoExtraPortsDiffer() {
        for _ in 0..<2000 {
            let pair = LoopbackMonitor.decoyPair()
            XCTAssertNotEqual(pair[0], pair[1])
            XCTAssertTrue(pair.allSatisfy { LoopbackMonitor.decoyPorts.contains($0) })
        }
    }

    /// The setup page and the home issue list name the proxy's own setting, with the Karing item
    /// the setup steps use.
    func testTheProxyHintUsesTheKaringItemName() {
        XCTAssertTrue(LoopbackMonitor.proxyHint.contains("Loopback Address"), LoopbackMonitor.proxyHint)
    }
}
