import Combine
import Foundation
import UIKit

/// Keeps Screen History reading without a manual start (issue 484).
///
/// While Screen History is on, the collector starts a run with no end of its own and starts it
/// again whenever it has ended for a reason that passes: the iPhone was locked, iOS took the
/// background time, the launcher gave up. Waiting inside a run (no local connection, an agent's
/// task) is `HistoryCapture`'s own; the collector only makes sure a run exists.
///
/// Reading another app means Poki is in the background, so something has to keep Poki running.
/// `BackgroundKeeper` does (location alone under Always Allow, else silent audio), and Screen History holds
/// it by itself while it is on, whether or not Poki is on (the owner, 2026-11-18: collection is
/// persistent whenever Screen History is on). `hold` and `staysUp` are the two places that decide
/// it, so another way of staying up can replace the keeper without touching the rest.
@MainActor
final class HistoryCollector {
    static let shared = HistoryCollector()

    /// Whether Poki keeps running in the background now, so a run can outlive iOS's background time.
    var staysUp: @MainActor (AppModel) -> Bool = { $0.background.isOn }
    /// Takes or gives back what keeps Poki running. Taking only works while Poki is in front,
    /// where iOS lets a background mode start.
    var hold: @MainActor (AppModel, Bool) -> Void = { model, on in
        if on { model.background.holdForHistory() } else { model.background.releaseHistory() }
    }

    private weak var model: AppModel?
    private var watching: Set<AnyCancellable> = []
    private var timer: Timer?
    private var startedAt = Date.distantPast
    /// The owner stopped the run by hand: nothing starts until Poki is opened again or the switch is turned.
    private var ownerStopped = false
    /// Why nothing was started at the last look, so the log says it once.
    private var idle = ""

    /// The least time between two starts, so a run that ends at once cannot spin.
    private static let pause: TimeInterval = 5
    /// How often the collector looks by itself. Changes it cannot observe (Poki turned on or off)
    /// are picked up here.
    private static let look: TimeInterval = 20

    /// Called whenever Poki comes to the front. The first call starts the watching.
    func attach(_ model: AppModel) {
        ownerStopped = false
        if self.model == nil {
            self.model = model
            let capture = HistoryCapture.shared
            capture.$enabled.dropFirst().sink { [weak self] on in
                Task { @MainActor in
                    guard let self else { return }
                    if on { self.ownerStopped = false }
                    self.evaluate(on ? "Screen History turned on" : "Screen History turned off")
                }
            }.store(in: &watching)
            // A run that ended is looked at again once its ending has settled.
            capture.$status.removeDuplicates().sink { [weak self] status in
                guard status != .waiting, status != .reading else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.pause))
                    self?.evaluate("the last run ended (\(status.rawValue))")
                }
            }.store(in: &watching)
            timer = Timer.scheduledTimer(withTimeInterval: Self.look, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.evaluate("a regular look") }
            }
        }
        model.background.onWake = { [weak self] in self?.evaluate("iOS woke Poki") }
        model.loopback.onNetworkChange = { [weak self] in self?.networkChanged() }
        // The shared shortcut's way in, whether or not Screen History is on.
        HistoryReconnect.shared.listen(true, model: model)
        evaluate("Poki came to the front")
    }

    /// The owner's Stop in Testing Options: the run ends and stays ended until Poki is opened again.
    func ownerStop() {
        ownerStopped = true
        HistoryCapture.shared.stop()
        AppLog.shared.add("history", "collector: stopped by the owner until Poki is opened again")
    }

    /// How long the tunnel is tried fast after a change of network, and after the shortcut asked.
    private static let catchFor: UInt32 = 30
    /// When the network last changed, as far as Poki saw.
    private var changedAt = Date.distantPast
    /// The network as the log last had it, so the same one is not said twice.
    private var networkSaid = ""
    private var networkChanges = 0
    /// Whether the proxy's VPN ever showed as an interface with a 10.7.0.x address on this
    /// iPhone. Some proxy apps route 10.7.0.1 without one, and theirs cannot be told up from down.
    private var vpnShows = false

    /// Whether the proxy's VPN is up, where that can be told: an interface holds a 10.7.0.x address.
    private var vpnUp: Bool {
        let up = loopbackInterface() != nil
        if up { vpnShows = true }
        return up
    }

    /// The network in a few words: what is up, and the proxy's VPN.
    private func network(_ model: AppModel) -> String {
        let monitor = model.loopback
        let physical = monitor.wifiUp ? (monitor.cellularUp ? "Wi-Fi and cellular" : "Wi-Fi") : monitor.cellularUp ? "cellular" : "no network"
        let up = vpnUp
        return vpnShows ? "\(physical), VPN \(up ? "up" : "down")" : physical
    }

    /// Cellular or Wi-Fi came or went. The loopback takes a new connection only in the moment
    /// around such a change, so the run tries its tunnel fast now and is started if none is going.
    private func networkChanged() {
        guard let model else { return }
        changedAt = Date()
        guard HistoryCapture.shared.enabled, !ownerStopped else { return }
        HistoryBridge.hurry(Self.catchFor)
        // One line for each network, not one for each report of it: iOS reports a change several
        // times over, and the path's own text was most of the log.
        let now = network(model)
        if now != networkSaid {
            networkSaid = now
            AppLog.shared.add("history", "network: \(now)")
        }
        if !HistoryCapture.shared.isRunning {
            startedAt = .distantPast
            evaluate("the network changed")
        }
        // Once the change has settled, the tunnel is asked whether it lived through it.
        networkChanges += 1
        let mine = networkChanges
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard mine == self.networkChanges, !self.answering else { return }
            let capture = HistoryCapture.shared
            let said = await capture.tunnel(replace: false, within: 6)
            guard case .some(.dead(let why, _)) = said else { return }
            // Given up only with Wi-Fi there, where a new one opens: on cellular a tunnel given
            // up by mistake could not be opened again, so there the next read decides.
            let replaces = model.loopback.wifiUp
            AppLog.shared.add("history", "tunnel does not answer after the change (\(why))\(replaces ? ", opening a new one" : "")")
            if replaces { _ = capture.askTunnel(replace: true) }
        }
    }

    /// How long the network must have stayed the same before Cellular Data is turned off. The
    /// owner's phone (build 58, 2026-11-19): with the proxy's VPN up for 6 s and for 44 s before
    /// cellular went off, the VPN stayed and the tunnel opened within 2.5 s. With a change of
    /// network 0.2 s and 0.4 s before (Wi-Fi had just dropped, which is when the automation
    /// runs), the VPN went down with cellular and no try could work.
    private static let settle: TimeInterval = 3
    /// The longest the shortcut's first question is held.
    private static let readyWithin: TimeInterval = 12
    /// The longest the shortcut's reconnect is held, so cellular stays off just long enough.
    private static let holdFor: TimeInterval = 6
    /// How long the run has to say whether its tunnel answers before it is started again.
    private static let answerWithin: TimeInterval = 3
    /// A shortcut's question is being answered: the look after a change of network stays out of it.
    private var answering = false

    /// The shortcut's first question, asked before it turns Cellular Data off: `true` when there is
    /// nothing to do (the tunnel still answers, or Wi-Fi is there and a tunnel opens without the
    /// trick), `false` when Cellular Data has to go off for a moment. A `false` is held until the
    /// proxy's VPN has been up and the network the same for a few seconds, because that is the
    /// only state in which the VPN was seen to outlive cellular going off.
    func ready(_ model: AppModel, by source: String) async -> Bool {
        if self.model == nil { self.model = model }
        let asked = Date()
        let capture = HistoryCapture.shared
        guard capture.enabled else {
            // Nothing to keep open. The shortcut ran, which is what Setup waits for.
            AppLog.shared.add("loopback", "ready asked by \(source): Screen History is off, nothing to do")
            HistoryReconnect.shared.note(worked: true)
            return true
        }
        answering = true
        defer { answering = false }
        HistoryBridge.hurry(Self.catchFor)
        ownerStopped = false
        if !capture.isRunning {
            startedAt = .distantPast
            evaluate("a shortcut asked")
        }
        let found = await capture.tunnel(replace: false, within: 4)
        if case .some(.alive(let ms)) = found {
            AppLog.shared.add("loopback", "ready asked by \(source): the tunnel answers (\(ms) ms), nothing to do")
            HistoryReconnect.shared.note(worked: true)
            return true
        }
        // With Wi-Fi up iOS takes a new connection as it is.
        if model.loopback.wifiUp {
            if case .some(.dead) = found { _ = capture.askTunnel(replace: true) }
            var opened = false
            while !opened, Date().timeIntervalSince(asked) < Self.holdFor {
                try? await Task.sleep(for: .milliseconds(100))
                opened = capture.lastOpenedAt.map { $0 > asked } ?? false
            }
            AppLog.shared.add("loopback", "ready asked by \(source): on Wi-Fi, \(opened ? "a tunnel opened" : "no tunnel yet"), Cellular Data stays as it is")
            HistoryReconnect.shared.note(worked: opened)
            return true
        }
        var steady = false
        while !steady, Date().timeIntervalSince(asked) < Self.readyWithin {
            try? await Task.sleep(for: .milliseconds(100))
            steady = (vpnUp || !vpnShows) && Date().timeIntervalSince(changedAt) >= Self.settle
        }
        AppLog.shared.add("loopback", "ready asked by \(source): no tunnel, \(network(model)), \(steady ? "steady" : "not steady") after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s, Cellular Data can go off")
        return false
    }

    /// The shortcut's reconnect, asked while Cellular Data is off. A tunnel that still answers is
    /// kept and the answer is `true` at once. Otherwise the request is held until a new tunnel
    /// opens, at most a few seconds, and the run goes on trying. The run is no longer started
    /// again for it: that closed a tunnel that may have been alive, and a try under way with it
    /// (builds 57 to 61). Only a run that does not say anything is.
    func reconnectSoon(_ model: AppModel, by source: String) async -> Bool {
        if self.model == nil { self.model = model }
        let capture = HistoryCapture.shared
        guard capture.enabled else { return await reconnect(model, by: source) }
        let asked = Date()
        answering = true
        defer { answering = false }
        HistoryBridge.hurry(Self.catchFor)
        ownerStopped = false
        if !capture.isRunning {
            startedAt = .distantPast
            evaluate("a reconnect was asked for")
        }
        let before = network(model)
        let check = capture.askTunnel(replace: true)
        var found = check == nil ? "no run was going" : ""
        var restarted = false
        var looks = 0
        while Date().timeIntervalSince(asked) < Self.holdFor {
            if let open = capture.lastOpenedAt, open > asked {
                AppLog.shared.add("loopback", "reconnect asked by \(source): \(found.isEmpty ? "a tunnel" : found + ", a new one") opened after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s (\(before))")
                HistoryReconnect.shared.note(worked: true)
                return true
            }
            if found.isEmpty, let check, let answer = capture.answer(to: check) {
                switch answer {
                case .alive(let ms):
                    AppLog.shared.add("loopback", "reconnect asked by \(source): the tunnel answers (\(ms) ms), kept (\(before))")
                    HistoryReconnect.shared.note(worked: true)
                    return true
                case .dead(let why, let givenUp):
                    found = "the old tunnel did not answer (\(why))"
                    // Said to another check, which left the tunnel where it was: the run goes.
                    if !givenUp, !restarted {
                        restarted = true
                        capture.stop()
                        startedAt = .distantPast
                    }
                case .missing: found = "there was no tunnel"
                }
            }
            if found.isEmpty, !restarted, Date().timeIntervalSince(asked) >= Self.answerWithin {
                // A read or a try hangs on a way that is gone: the run is started again, as before.
                restarted = true
                found = "the run did not answer and was started again"
                capture.stop()
                startedAt = .distantPast
            }
            if !capture.enabled { break }
            looks += 1
            if !capture.isRunning, restarted || looks % 5 == 0 { evaluate("a reconnect was asked for") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        AppLog.shared.add("loopback", "reconnect asked by \(source): \(found.isEmpty ? "no answer" : found), none opened in \(Int(Self.holdFor)) s (\(before), now \(network(model))), last reason: \(HistoryCapture.brief(capture.lastFailure ?? "none given"))")
        HistoryReconnect.shared.note(worked: false)
        return false
    }

    /// Opens the connection again now and says whether it worked (the Reconnect Poki action, a
    /// link, and Testing Options). With Screen History on it is the shortcut's reconnect. With it
    /// off, the answer is whether the local connection answers a new connection.
    func reconnect(_ model: AppModel, by source: String) async -> Bool {
        if self.model == nil { self.model = model }
        guard !HistoryCapture.shared.enabled else { return await reconnectSoon(model, by: source) }
        let asked = Date()
        model.loopback.check()
        while Date().timeIntervalSince(asked) < 6 {
            try? await Task.sleep(for: .milliseconds(300))
            if let checked = model.loopback.checkedAt, checked > asked { break }
        }
        let worked = model.loopback.isWorking
        AppLog.shared.add("loopback", "reconnect asked by \(source): Screen History is off, the local connection \(worked ? "answers" : "does not answer")")
        HistoryReconnect.shared.note(worked: worked)
        return worked
    }

    /// Whether an agent's task has the screen.
    func taskOpen() -> Bool { model?.hasOpenInProcessSession ?? false }

    /// Starts a run when one should be reading and none is.
    func evaluate(_ reason: String) {
        guard let model else { return }
        let capture = HistoryCapture.shared
        // Held for as long as the switch is on, a hand-stopped run included: the owner's Stop ends
        // reading, and the next time Poki is opened reading goes on without another start.
        // Taken in the background too: iOS may have started Poki there (a change of place, the
        // shortcut's action), and the silent audio mixes with other sound, so it may start there.
        hold(model, capture.enabled)
        model.background.ensure(reason)
        guard !capture.isRunning else { idle = ""; return }
        let why: String? =
            !capture.enabled ? "Screen History is off"
            : ownerStopped ? "the owner stopped it"
            : !staysUp(model) ? "nothing keeps Poki running in the background until it is opened once"
            : Date().timeIntervalSince(startedAt) < Self.pause ? "a run started a moment ago"
            : nil
        if let why {
            if why != idle { idle = why; AppLog.shared.add("history", "collector: not reading, \(why)") }
            return
        }
        idle = ""
        startedAt = Date()
        AppLog.shared.add("history", "collector: starting a run (\(reason))")
        capture.start(always: true, model: model)
    }
}
