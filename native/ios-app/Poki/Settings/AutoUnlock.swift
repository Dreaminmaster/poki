import Foundation
import Observation
import os

@MainActor @Observable
final class AutoUnlock {
    enum SettingsError: Error { case invalidPasscode }

    private static let account = "device-unlock.passcode.v1"
    private static let enabledKey = "deviceUnlock.enabled"
    private static let retryKey = "deviceUnlock.needsPasscode"

    private(set) var enabled = UserDefaults.standard.bool(forKey: AutoUnlock.enabledKey)
    private(set) var needsPasscode = UserDefaults.standard.bool(forKey: AutoUnlock.retryKey)
    @ObservationIgnored private var attempt: OSAllocatedUnfairLock<Bool>?
    @ObservationIgnored private var configurationVersion: UInt64 = 0

    static func accepts(_ passcode: String) -> Bool {
        let bytes = passcode.utf8
        return (bytes.count == 4 || bytes.count == 6) && bytes.allSatisfy { (48...57).contains($0) }
    }

    func save(_ passcode: String) throws {
        guard Self.accepts(passcode) else { throw SettingsError.invalidPasscode }
        attempt?.withLock { $0 = false }
        configurationVersion &+= 1
        do {
            try Keychain.write(Data(passcode.utf8), account: Self.account)
        } catch {
            enabled = false
            UserDefaults.standard.removeObject(forKey: Self.enabledKey)
            throw error
        }
        resetAttempt()
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enabled = true
    }

    func disable() throws {
        attempt?.withLock { $0 = false }
        configurationVersion &+= 1
        enabled = false
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        try Keychain.remove(Self.account)
        resetAttempt()
    }

    private func resetAttempt() {
        needsPasscode = false
        UserDefaults.standard.removeObject(forKey: Self.retryKey)
    }

    func unlock(timeout: TimeInterval) async -> Bool {
        guard enabled, !needsPasscode, attempt == nil, !Task.isCancelled, timeout > 0,
              let data = try? Keychain.read(Self.account),
              let passcode = String(data: data, encoding: .utf8), Self.accepts(passcode) else { return false }
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let version = configurationVersion
        attempt = allowed
        // Losing the app in the middle of entry must not cause another automatic attempt on launch.
        UserDefaults.standard.set(true, forKey: Self.retryKey)
        let result: PKUnlockResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: PKInProcess.shared().unlockPhone(withPasscode: passcode, timeout: timeout) {
                        allowed.withLock { $0 }
                    })
                }
            }
        } onCancel: {
            allowed.withLock { $0 = false }
        }
        attempt = nil
        if configurationVersion == version {
            needsPasscode = result == .submissionUnconfirmed
            UserDefaults.standard.set(needsPasscode, forKey: Self.retryKey)
        }
        return result == .unlocked && !Task.isCancelled
    }
}
