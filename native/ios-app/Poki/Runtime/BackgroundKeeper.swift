import AVFoundation
import CoreLocation
import Foundation

/// Keeps Poki running in the background while it is on, so the relay connection and the launcher stay
/// up. Silent audio does it; location is the backup only when it is needed: while a pairing waits in
/// Settings, and when the silent audio cannot play (it failed to start, or another app's audio
/// interrupted it), when iOS would otherwise suspend Poki mid-session. Then it is the coarsest
/// accuracy, only under Always Allow where iOS shows no indicator, and it stops again as soon as the audio is back.
/// The location is never read or sent anywhere.
///
/// Screen History holds the keeper too, whether or not Poki is on (the owner, 2026-11-18), and is
/// kept running the same way as a session: the silent audio, which mixes with other apps' sound.
/// Location alone was tried for it and did not hold (build 54, iOS 27: Poki was suspended a few
/// minutes into the background). Since iOS 16.4 an app that asks for coarse, distance-filtered
/// location is suspended anyway, and on iOS 27 deliveries are reported to stop after a few minutes
/// even with the settings Apple asks for (developer forums 726945, 844579). So location is only
/// ever the backup beside the audio, with those settings. It never asks for a location permission
/// and never shows the location indicator.
@MainActor
@Observable
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let audio = KeepAlive()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isOn = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // What iOS 16.4 and later need to keep an app running on location: a hundred metres or
        // better and no distance filter. Coarser than that, the app is suspended all the same.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var denied: Bool { authorization == .denied || authorization == .restricted }

    /// Always Allow lets Poki stay up without the location pill. iOS asks for While Using first and
    /// offers the upgrade on the second request.
    var always: Bool { authorization == .authorizedAlways }

    /// iOS shows its "Change to Always Allow" prompt once for an app, ever. After that only Settings
    /// can change it, so Setup sends the owner there and does not offer a button that does nothing.
    private(set) var askedAlways = UserDefaults.standard.bool(forKey: "background.askedAlways")
    /// Set by Setup's first request, so the Always Allow prompt follows While Using at once and the
    /// owner answers both in one place, one time.
    private var upgradeAfterFirstAnswer = false

    /// Setup's button, and nothing else, asks for location: no prompt comes up by itself later.
    func requestPermission() {
        if authorization == .notDetermined {
            upgradeAfterFirstAnswer = true
            manager.requestWhenInUseAuthorization()
        } else {
            askAlways()
        }
    }

    private func askAlways() {
        guard authorization == .authorizedWhenInUse, !askedAlways else { return }
        askedAlways = true
        UserDefaults.standard.set(true, forKey: "background.askedAlways")
        manager.requestAlwaysAuthorization()
    }

    /// Who wants Poki kept running: the session (Poki is on) and Screen History, each on its own.
    /// The keeper runs while either does.
    private var sessionHold = false
    private(set) var historyHold = false

    /// Poki turned on. Called while Poki is in front (iOS only starts background location from the foreground).
    func start() {
        sessionHold = true
        apply()
    }

    /// Poki turned off. The keeper stays while Screen History holds it.
    func stop() {
        sessionHold = false
        apply()
    }

    /// Screen History is on. Called while Poki is in front, as `start` is.
    func holdForHistory() {
        guard !historyHold else { return }
        historyHold = true
        apply()
        AppLog.shared.add("background", "Screen History keeps Poki running (silent audio\(audio.isOn ? "" : ", not playing"))")
    }

    func releaseHistory() {
        guard historyHold else { return }
        historyHold = false
        apply()
    }

    /// Looked at every few seconds while Poki runs, and whenever iOS wakes it: a silent engine that
    /// stopped without a word is started again, and location stands in at once if it will not start.
    /// Without this, a keeper that died stayed dead until Poki was opened.
    func ensure(_ why: String) {
        guard isOn, !audioPaused, !audio.isOn else { return }
        // While it cannot play (a call has the audio), one try a minute is enough.
        guard !audioLost || Date().timeIntervalSince(lastEnsure) > 60 else { return }
        lastEnsure = Date()
        AppLog.shared.add("background", "silent audio was not playing (\(why)): starting it again")
        audio.stop()
        startAudio()
        if !audio.isOn { setAudioLost(true); startLocation() }
    }

    /// Wakes Poki when the iPhone moves to another cell tower, also after iOS suspended it or ended
    /// it: a wake is a chance to start the silent audio again. Only under Always Allow, which
    /// shows no indicator for it, and it asks for nothing. Kept on while a holder wants Poki up.
    private var lastEnsure = Date.distantPast
    private var wakesOnMoves = false
    private func watchMoves(_ on: Bool) {
        let on = on && always && CLLocationManager.significantLocationChangeMonitoringAvailable()
        guard on != wakesOnMoves else { return }
        wakesOnMoves = on
        if on { manager.startMonitoringSignificantLocationChanges() } else { manager.stopMonitoringSignificantLocationChanges() }
        AppLog.shared.add("background", on ? "wakes on a change of place: on" : "wakes on a change of place: off")
    }

    /// Brings the keeper to what its holders need now.
    private func apply() {
        guard sessionHold || historyHold else { finish(); return }
        isOn = true
        watchMoves(true)
        watchInterruptions()
        if !audioPaused, !audio.isOn { startAudio() }
        if !audioLost, !pairingHold { stopLocation() }
    }

    /// Silent audio could not hold Poki up (it would be suspended): location stands in until it can.
    private(set) var audioLost = false
    private var interruption: NSObjectProtocol?

    private func startAudio() {
        do { try audio.start(); setAudioLost(false) } catch { setAudioLost(true) }
    }

    private func setAudioLost(_ lost: Bool) {
        guard lost != audioLost else { return }
        audioLost = lost
        AppLog.shared.add("background", lost ? "silent audio stopped: location keeps Poki running until it is back" : "silent audio back: location off")
        if lost { startLocation() } else if !pairingHold { stopLocation() }
    }

    private var recovered: NSObjectProtocol?

    private func watchInterruptions() {
        // The silent engine restarts itself after a route change or a media reset; location stands
        // in when it could not, and goes again when it could.
        if recovered == nil {
            recovered = NotificationCenter.default.addObserver(forName: KeepAlive.changed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isOn, !self.audioPaused else { return }
                    self.setAudioLost(!self.audio.isOn)
                }
            }
        }
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, self.isOn, !self.audioPaused else { return }
                switch type {
                case .began: self.setAudioLost(true)
                case .ended:
                    // KeepAlive restarts its engine on its own; check a moment later.
                    try? await Task.sleep(for: .seconds(1))
                    if self.audio.isOn { self.setAudioLost(false) } else { self.audio.stop(); self.startAudio() }
                @unknown default: break
                }
            }
        }
    }

    /// A voice conversation needs the audio session for the microphone; the voice-chat session keeps
    /// Poki running meanwhile. The silent audio comes back when it ends, if Poki is still on.
    /// While a voice conversation holds the audio session (it keeps Poki running itself).
    private var audioPaused = false
    func pauseAudio() { audioPaused = true; audio.stop() }
    func resumeAudio() {
        audioPaused = false
        guard isOn else { return }
        startAudio()
    }

    private func finish() {
        guard isOn else { return }
        isOn = false
        watchMoves(false)
        audioLost = false
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if let recovered { NotificationCenter.default.removeObserver(recovered) }
        recovered = nil
        if !pairingHold { stopLocation() }
        audio.stop()
    }

    /// Location runs only under Always Allow, and never with iOS's blue indicator in the status bar
    /// or the Dynamic Island (the owner, 2026-11-18). iOS shows that indicator for an app that has
    /// only While Using and carries updates into the background with a CLBackgroundActivitySession,
    /// or that asks for it with `showsBackgroundLocationIndicator`: Poki does neither. With While
    /// Using alone the silent audio is all that keeps Poki running.
    ///
    /// While a pairing waits in Settings, location keeps Poki running beside the silent audio, so the
    /// pairing listener answers when Settings connects. Ended when the pairing ends.
    private(set) var pairingHold = false
    func holdForPairing() {
        guard !pairingHold else { return }
        pairingHold = true
        startPairingLocation()
    }

    func releasePairing() {
        guard pairingHold else { return }
        pairingHold = false
        if isOn && audioLost { startLocation() } else { stopLocation() }
    }

    private func startPairingLocation() {
        guard pairingHold, always else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    private func startLocation() {
        if pairingHold, always { startPairingLocation(); return }
        guard audioLost, always else { stopLocation(); return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    private func stopLocation() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // Setup's first answer was While Using: iOS's Always Allow prompt follows at once.
            if self.upgradeAfterFirstAnswer, status != .notDetermined {
                self.upgradeAfterFirstAnswer = false
                self.askAlways()
            }
            // Always Allow taken away while location was running: it stops, so no indicator shows.
            if !self.always { self.stopLocation() }
            if self.pairingHold || (self.isOn && self.audioLost) { self.startLocation() }
            self.watchMoves(self.isOn)
        }
    }

    /// The place is never read. A delivery is only a moment in which Poki runs.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.ensure("woken by a change of place")
            self.onWake?()
        }
    }

    /// iOS woke Poki some other way (Background App Refresh).
    func woke(_ why: String) {
        ensure(why)
        onWake?()
    }

    /// Called when iOS woke Poki, so what should be reading can look again.
    var onWake: (@MainActor () -> Void)?
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
