import XCTest
@testable import Poki

/// A probe that answers "connected" only when the test lets it, so a check can be in flight for as
/// long as the test wants (a timed-out connect to 10.7.0.1 takes seconds in the app).
@MainActor
private final class HeldProbe {
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    var isWaiting: Bool { !held.isEmpty }

    func answer() async -> ProbeResult {
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
        var searchEnded = false
        monitor.onPairingPortSearchEnded = { searchEnded = true }
        defer { monitor.pause(); browsing?.resume(returning: ([], nil)); RemotePairingPort.setSearching(false) }
        monitor.simulateSearchBudget(2)
        monitor.check()
        await yield { browsing != nil }
        XCTAssertNotNil(browsing)
        monitor.simulateNetworkChange(physical: false)
        let held = browsing
        browsing = nil
        held?.resume(returning: ([], nil))
        await yield { searches >= 2 }
        XCTAssertEqual(searches, 2, "The invalidated third search must be retried")
        await yield { searchEnded }
        XCTAssertTrue(searchEnded, "An exhausted retry must release the launcher fallback")
    }

    /// A probe that takes longer than the 3 s timer is always overlapped by the next timer tick. That
    /// tick must not throw the finished answer away: the first answer is published even though a tick
    /// arrived while it was in flight, however many rounds the probe takes.
    func testAnAnswerIsPublishedWhenTheTimerTicksWhileTheProbeIsInFlight() async {
        let held = HeldProbe()
        let monitor = LoopbackMonitor(probe: { _, _, _ in await held.answer() })
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
}
