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
        evaluate("Poki came to the front")
    }

    /// The owner's Stop in Testing Options: the run ends and stays ended until Poki is opened again.
    func ownerStop() {
        ownerStopped = true
        HistoryCapture.shared.stop()
        AppLog.shared.add("history", "collector: stopped by the owner until Poki is opened again")
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
