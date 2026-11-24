import Foundation
import Observation
import os

@MainActor @Observable
final class AutoUnlock {
    enum SettingsError: Error { case invalidPasscode }

    private static let account = "device-unlock.passcode.v1"
    private static let enabledKey = "deviceUnlock.enabled"
    private static let retryKey = "deviceUnlock.needsPasscode"
    private static let deletionFailedKey = "deviceUnlock.deletionFailed"

    private(set) var enabled = UserDefaults.standard.bool(forKey: AutoUnlock.enabledKey)
    private(set) var needsPasscode = UserDefaults.standard.bool(forKey: AutoUnlock.retryKey)
    private(set) var deletionFailed = UserDefaults.standard.bool(forKey: AutoUnlock.deletionFailedKey) {
        didSet { UserDefaults.standard.set(deletionFailed, forKey: Self.deletionFailedKey) }
    }
    @ObservationIgnored private var attempt: OSAllocatedUnfairLock<Bool>?
    @ObservationIgnored private var configurationVersion: UInt64 = 0

    static func accepts(_ passcode: String) -> Bool {
        let bytes = passcode.utf8
        return (bytes.count == 4 || bytes.count == 6) && bytes.allSatisfy { (48...57).contains($0) }
    }

    func save(_ passcode: String) throws {
        guard Self.accepts(passcode) else { throw SettingsError.invalidPasscode }
        try Keychain.write(Data(passcode.utf8), account: Self.account)
        attempt?.withLock { $0 = false }
        configurationVersion &+= 1
        resetAttempt()
        deletionFailed = false
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enabled = true
    }

    func disable() throws {
        attempt?.withLock { $0 = false }
        do {
            try Keychain.remove(Self.account)
        } catch {
            deletionFailed = true
            throw error
        }
        configurationVersion &+= 1
        enabled = false
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        deletionFailed = false
        resetAttempt()
    }

    private func resetAttempt() {
        needsPasscode = false
        UserDefaults.standard.removeObject(forKey: Self.retryKey)
    }

    func unlock(using automation: InProcessAutomation, opensSession: Bool, timeout: TimeInterval) async -> Bool {
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
                    let start = ProcessInfo.processInfo.systemUptime
                    let result: PKUnlockResult = {
                        guard allowed.withLock({ $0 }) else { return .unavailable }
                        defer { if opensSession { _ = automation.close() } }
                        if opensSession {
                            let ready = InProcessWDA.openThroughGate { ["ok": automation.prepareForUnlock()] }
                            guard ready["ok"] as? Bool == true else { return .unavailable }
                        }
                        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
                        guard remaining > 0 else { return .unavailable }
                        return automation.submitUnlockPasscode(passcode, timeout: remaining) { allowed.withLock { $0 } }
                    }()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            allowed.withLock { $0 = false }
        }
        attempt = nil
        let resultMessage: String
        switch result {
        case .unlocked: resultMessage = "iOS confirmed the phone is unlocked"
        case .submissionUnconfirmed: resultMessage = "all lock-screen keypad touches were delivered, but iOS did not confirm unlock"
        case .submissionIncomplete: resultMessage = "lock-screen keypad entry stopped before all touches were confirmed"
        case .keypadUnavailable: resultMessage = "could not confirm an untouched SpringBoard passcode keypad"
        case .touchRejected: resultMessage = "iOS automation did not confirm delivery of the lock-screen gesture or touch"
        default: resultMessage = "the lock-screen session or display was unavailable"
        }
        AppLog.shared.add("auto-unlock", resultMessage)
        if configurationVersion == version {
            needsPasscode = result == .submissionUnconfirmed || result == .submissionIncomplete
            UserDefaults.standard.set(needsPasscode, forKey: Self.retryKey)
        }
        return result == .unlocked && !Task.isCancelled
    }
}
