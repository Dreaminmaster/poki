import AudioToolbox
import Foundation

enum VoiceOpeningFeedback {
    @MainActor
    static func vibrate() {
        #if !targetEnvironment(simulator)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
    }

    /// Two-tone ready chime at 48 kHz mono Float32 for playback through the VPIO audio engine,
    /// so hardware echo cancellation subtracts the chime instead of recording it.
    static let readyChime: [Float] = {
        let rate = 48_000.0
        let frames = Int(rate * 0.18)
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let t = Double(frame) / rate
            let first = t < 0.075 ? tone(at: t, frequency: 587.33, gain: 0.18, decay: 28) : 0
            let second = t >= 0.065 ? tone(at: t - 0.065, frequency: 880, gain: 0.22, decay: 24) : 0
            samples.append(Float(first + second))
        }
        return samples
    }()

    private static func tone(at t: Double, frequency: Double, gain: Double, decay: Double) -> Double {
        gain * min(1, t / 0.008) * exp(-t * decay) * sin(2 * .pi * frequency * t)
    }
}
