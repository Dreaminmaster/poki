import Foundation
import Observation

/// What the phone asks of the app to spare its battery: Low Power Mode. The home page's suggestion
/// rows, its light and the three-dimensional bear all read it here, so they rest together and go on
/// together when it ends.
///
/// `-pokiStrain lowPower` holds the state on, to see it in the simulator, which never has Low Power
/// Mode. Debug builds only.
@MainActor @Observable
final class DeviceStrain {
    static let shared = DeviceStrain()

    /// Low Power Mode is on.
    var lowPower: Bool

    @ObservationIgnored private let forced: Set<String>
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        #if DEBUG
        forced = Set((UserDefaults.standard.string(forKey: "pokiStrain") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #else
        forced = []
        #endif
        lowPower = false
        read()
        // Posted on whichever thread changed the state; read on the main one.
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        })
    }

    private func read() {
        let lowPower = forced.contains("lowPower") || ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower != self.lowPower { self.lowPower = lowPower }
    }
}
