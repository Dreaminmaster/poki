import AVFoundation

/// Keeps the app running in the background while a session is on, so the launcher's connections
/// (and with them the runner) stay up: a silent audio session mixed with whatever else is playing.
///
/// Every keep-alive (the session's, the pairing's, a voice test run's) shares one silent engine, so
/// two of them never render audio twice, and only the last one to stop ends it. The session is
/// mixable, so music and podcasts keep playing, Poki never takes Now Playing, and nothing is ducked.
/// The engine follows route changes (earphones in or out, Bluetooth, CarPlay) and a media services
/// reset, which otherwise stop it without a word and leave Poki to be suspended.
@MainActor
final class KeepAlive {
    private var holding = false
    /// Posted after the shared engine tried to start again on its own: `isOn` says how it went.
    static let changed = Notification.Name("PokiKeepAliveChanged")

    /// This keep-alive is held and the shared engine is playing.
    var isOn: Bool { holding && Silence.shared.isPlaying }

    func start() throws {
        guard !holding else { return }
        try Silence.shared.acquire()
        holding = true
    }

    /// Only a keep-alive that is held stops anything, so stopping one never silences another.
    func stop() {
        guard holding else { return }
        holding = false
        Silence.shared.release()
    }
}

/// The one silent engine behind every KeepAlive.
@MainActor
private final class Silence {
    static let shared = Silence()

    private var holders = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var lastRecovery = Date.distantPast

    var isPlaying: Bool { engine?.isRunning == true && player?.isPlaying == true }

    func acquire() throws {
        if holders > 0, isPlaying { holders += 1; return }
        try activateSession()
        do { try build() } catch {
            if holders == 0 { deactivateSession() }
            throw error
        }
        if holders == 0 { observe() }
        holders += 1
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        tearDown()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        deactivateSession()
    }

    private func activateSession(keepingVoice: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // A voice conversation may own the session (play and record) while a keep-alive is held: a
        // recovery leaves its category alone, so the microphone keeps working.
        if !(keepingVoice && session.category == .playAndRecord) {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        // Silence needs no low latency: a long buffer wakes the audio thread a few times a second
        // instead of every few milliseconds. Only a preference, and other apps' own needs win.
        try? session.setPreferredIOBufferDuration(0.5)
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A fresh engine at the route's current format, looping one second of zeros at no volume.
    private func build() throws {
        tearDown()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            throw NSError(domain: "Poki.KeepAlive", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio output format"])
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffer.frameLength = buffer.frameCapacity // zero-filled: silence
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
        // The route changed under the engine (earphones, Bluetooth, CarPlay, AirPlay): iOS stops it
        // and its format may differ, so it is built again for the new route.
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recover("audio route changed") }
        }
    }

    private func tearDown() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    private func observe() {
        let center = NotificationCenter.default
        // Another app's audio that does not mix (a call, Siri, an alarm) interrupts the session.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.recover("audio interruption ended") }
        })
        // The media server restarted: every engine and the session's settings are gone.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recover("media services reset") }
        })
        // Earphones out, a Bluetooth device gone: a check that the silence still plays.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.isPlaying else { return }
                self.recover("audio route changed")
            }
        })
    }

    /// Builds the engine again while anything still holds it. A failure is logged; the keeper's
    /// location backup sees `isOn` false and stands in.
    func recover(_ why: String) {
        guard holders > 0 else { return }
        // One route change can bring several notices: the first rebuild serves them all.
        let now = Date()
        guard now.timeIntervalSince(lastRecovery) > 1 || !isPlaying else { return }
        lastRecovery = now
        do {
            try activateSession(keepingVoice: true)
            try build()
            AppLog.shared.add("background", "silent audio started again (\(why))")
        } catch {
            AppLog.shared.add("background", "silent audio could not start again (\(why)): \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: KeepAlive.changed, object: nil)
    }
}
