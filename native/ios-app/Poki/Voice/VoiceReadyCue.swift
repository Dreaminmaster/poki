import AudioToolbox
import AVFoundation
import Foundation
import UIKit

enum VoiceReadyCue {
    private static let duration: TimeInterval = 0.18
    private static let silentThreshold: TimeInterval = 0.08
    @MainActor private static var soundID: SystemSoundID = 0

    /// The cue plays while the voice session records. iOS keeps system sounds and haptics off during a
    /// recording unless the session allows them, and then neither the chime nor the buzz that stands in
    /// for it in silent mode would be felt, so the session is told to allow them just before.
    @MainActor static func play() {
        AppLog.shared.add("voice", "ready cue triggered")
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            AppLog.shared.add("voice", "ready cue: could not allow system sounds during recording: \(error.localizedDescription)")
        }
        AppLog.shared.add("voice", "ready cue: system sounds during recording allowed=\(session.allowHapticsAndSystemSoundsDuringRecording)")
        playSound { elapsed in
            Task { @MainActor in
                if elapsed < silentThreshold {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    AppLog.shared.add("voice", "ready cue vibrated (silent mode), sound call returned after \(elapsed) s")
                } else {
                    AppLog.shared.add("voice", "ready cue played, sound call returned after \(elapsed) s")
                }
            }
        }
    }

    @MainActor private static func playSound(_ done: @escaping @Sendable (TimeInterval) -> Void) {
        #if targetEnvironment(simulator)
        done(duration)
        #else
        if soundID == 0 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("poki-voice-ready.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? wavData().write(to: url, options: .atomic)
            }
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError {
                var isUI: UInt32 = 1
                AudioServicesSetProperty(kAudioServicesPropertyIsUISound,
                                         UInt32(MemoryLayout<SystemSoundID>.size), &id,
                                         UInt32(MemoryLayout<UInt32>.size), &isUI)
                soundID = id
            }
        }
        guard soundID != 0 else {
            done(0)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        AudioServicesPlaySystemSoundWithCompletion(soundID) {
            done(ProcessInfo.processInfo.systemUptime - started)
        }
        #endif
    }

    private static func wavData() -> Data {
        let rate = 44_100
        let count = Int(Double(rate) * duration)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            var sample = 0.0
            if t < 0.075 {
                let attack = min(1.0, t / 0.008)
                let decay = exp(-t * 28.0)
                sample += 0.18 * attack * decay * sin(2.0 * .pi * 587.33 * t)
            }
            if t >= 0.065 {
                let dt = t - 0.065
                let attack = min(1.0, dt / 0.008)
                let decay = exp(-dt * 24.0)
                sample += 0.22 * attack * decay * sin(2.0 * .pi * 880.0 * dt)
            }
            let clamped = Int16(max(-1.0, min(1.0, sample)) * Double(Int16.max))
            var le = clamped.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func append32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + pcm.count))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(rate))
        append32(UInt32(rate * 2))
        append16(2)
        append16(16)
        wav.append(contentsOf: "data".utf8)
        append32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
