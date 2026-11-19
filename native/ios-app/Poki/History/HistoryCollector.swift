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

    /// Opens the connection again now, without waiting out a run's next try, and says whether it
    /// worked (`ReconnectPokiIntent`, and the cellular test in Testing Options). With Screen History
    /// on, the run in progress is ended and a new one started, and the answer is its first read. With
    /// it off, the answer is whether the local connection answers a new connection.
    func reconnect(_ model: AppModel, by source: String, within seconds: TimeInterval = 25) async -> Bool {
        let worked = await reopen(model, within: seconds)
        HistoryReconnect.shared.note(worked: worked, by: source)
        return worked
    }

    private func reopen(_ model: AppModel, within seconds: TimeInterval) async -> Bool {
        if self.model == nil { self.model = model }
        let asked = Date()
        let capture = HistoryCapture.shared
        guard capture.enabled else {
            model.loopback.check()
            while Date().timeIntervalSince(asked) < 6 {
                try? await Task.sleep(for: .milliseconds(300))
                if let checked = model.loopback.checkedAt, checked > asked { break }
            }
            return model.loopback.isWorking
        }
        ownerStopped = false
        capture.stop()
        startedAt = .distantPast
        // A background start cannot take the keeper, but the run itself starts wherever Poki runs.
        evaluate("a reconnect was asked for")
        model.loopback.check()
        while Date().timeIntervalSince(asked) < seconds {
            try? await Task.sleep(for: .milliseconds(500))
            if let read = capture.lastReadAt, read > asked { return true }
            if !capture.isRunning { evaluate("a reconnect was asked for") }
        }
        return false
    }

    /// Starts a run when one should be reading and none is.
    func evaluate(_ reason: String) {
        guard let model else { return }
        let capture = HistoryCapture.shared
        // Held for as long as the switch is on, a hand-stopped run included: the owner's Stop ends
        // reading, and the next time Poki is opened reading goes on without another start.
        if !capture.enabled {
            hold(model, false)
        } else if UIApplication.shared.applicationState == .active {
            hold(model, true)
        }
        guard !capture.isRunning else { idle = ""; return }
        let why: String? =
            !capture.enabled ? "Screen History is off"
            : ownerStopped ? "the owner stopped it"
            : capture.screenOff ? "the iPhone is locked"
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
