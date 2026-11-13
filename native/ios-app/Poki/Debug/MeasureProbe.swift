// Measurement only, never committed: applied the same way to the build before and after the change.
import Darwin
import QuartzCore
import UIKit

enum MeasureProbe {
    /// `-pokiMeasure launch|voice`.
    static let mode = UserDefaults.standard.string(forKey: "pokiMeasure")
    @MainActor private static var from: CFTimeInterval?
    @MainActor private static var waitingFor: String?

    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data("POKI-MEASURE \(line)\n".utf8))
    }

    private static func afterFrame(_ done: @escaping () -> Void) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock(done)
            CATransaction.commit()
        }
    }

    /// The first page is on screen: milliseconds since the process started.
    @MainActor static func launched() {
        guard mode == "launch" else { return }
        afterFrame { say("launch \(Int(Date().timeIntervalSince(processStart()) * 1000))") }
    }

    /// Three seconds after launch, does what the voice button's tap does (RootView.openLiveVoice).
    @MainActor static func drive(voice: () -> Void) async {
        guard mode == "voice" else { return }
        try? await Task.sleep(for: .seconds(3))
        waitingFor = "voice"
        from = CACurrentMediaTime()
        voice()
    }

    /// The page asked for is on screen: milliseconds since the tap.
    @MainActor static func reached(_ name: String) {
        guard waitingFor == name, let from else { return }
        waitingFor = nil
        afterFrame { say("\(name) \(Int((CACurrentMediaTime() - from) * 1000))") }
    }
}
