import AVFoundation
import CoreLocation
import Foundation

/// Keeps Poki running in the background while it is on, so the relay connection and the launcher stay
/// up. Silent audio does it; location is the backup only when it is needed: while a pairing waits in
/// Settings, and when the silent audio cannot play (it failed to start, or another app's audio
/// interrupted it), when iOS would otherwise suspend Poki mid-session. Then it is the coarsest
/// accuracy, with no indicator under Always Allow, and it stops again as soon as the audio is back.
/// The location is never read or sent anywhere.
///
/// Screen History holds the keeper too, whether or not Poki is on (the owner, 2026-11-18). Held for
/// Screen History alone, it must not touch what the owner hears or show anything: under Always
/// Allow it is location only, with no audio session opened at all, and otherwise the silent audio,
/// which mixes with other apps' sound. It never asks for a location permission and never shows the
/// location indicator.
@MainActor
@Observable
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var activity: CLBackgroundActivitySession?
    private let audio = KeepAlive()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isOn = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var denied: Bool { authorization == .denied || authorization == .restricted }

    /// Always Allow lets Poki stay up without the location pill. iOS asks for While Using first and
    /// offers the upgrade on the second request.
    var always: Bool { authorization == .authorizedAlways }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestAlwaysAuthorization() }
    }

    /// Who wants Poki kept running: the session (Poki is on) and Screen History, each on its own.
    /// The keeper runs while either does.
    private var sessionHold = false
    private(set) var historyHold = false
    /// Held for Screen History alone under Always Allow: location only, no audio session.
    private var quiet: Bool { historyHold && !sessionHold && always }

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
        AppLog.shared.add("background", "Screen History keeps Poki running (\(quiet ? "location only" : "silent audio"))")
    }

    func releaseHistory() {
        guard historyHold else { return }
        historyHold = false
        apply()
    }

    /// Brings the keeper to what its holders need now.
    private func apply() {
        guard sessionHold || historyHold else { finish(); return }
        isOn = true
        if quiet {
            audio.stop()
            audioLost = false
            startLocation()
            return
        }
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
                    guard let self, self.isOn, !self.audioPaused, !self.quiet else { return }
                    self.setAudioLost(!self.audio.isOn)
                }
            }
        }
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, self.isOn, !self.audioPaused, !self.quiet else { return }
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
        guard isOn, !quiet else { return }
        startAudio()
    }

    private func finish() {
        guard isOn else { return }
        isOn = false
        audioLost = false
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if let recovered { NotificationCenter.default.removeObserver(recovered) }
        recovered = nil
        if !pairingHold { stopLocation() }
        audio.stop()
    }

    /// While a pairing waits in Settings, location keeps Poki running (with the silent audio), so the
    /// pairing listener answers when Settings connects. While Using is enough here: the updates start
    /// in front, and a CLBackgroundActivitySession carries them into the background (iOS shows its
    /// location indicator meanwhile). Ended when the pairing ends.
    private(set) var pairingHold = false
    func holdForPairing() {
        guard !pairingHold else { return }
        pairingHold = true
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        startPairingLocation()
    }

    func releasePairing() {
        guard pairingHold else { return }
        pairingHold = false
        activity?.invalidate(); activity = nil
        if isOn && (audioLost || quiet) { startLocation() } else { stopLocation() }
    }

    private func startPairingLocation() {
        guard pairingHold, allowed else { return }
        if activity == nil { activity = CLBackgroundActivitySession() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = !always
        manager.startUpdatingLocation()
    }

    private func startLocation() {
        if pairingHold { startPairingLocation(); return }
        guard audioLost || quiet, allowed else { stopLocation(); return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = !always
        if !always, activity == nil { activity = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
    }

    private func stopLocation() {
        manager.stopUpdatingLocation()
        activity?.invalidate(); activity = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // Always Allow given or taken away changes how Screen History alone is kept running.
            if self.isOn { self.apply() }
            if self.pairingHold || (self.isOn && self.audioLost) { self.startLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
