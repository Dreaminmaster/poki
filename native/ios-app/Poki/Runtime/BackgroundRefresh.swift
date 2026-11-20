import BackgroundTasks
import Foundation

/// Background App Refresh as one more way back for the keeper (the owner, 2026-11-19): iOS wakes
/// Poki now and then, with nothing shown, and each wake is a chance to start the silent audio and
/// the reading again. iOS chooses the times and may leave long gaps, so this stands beside the
/// silent audio and never replaces it. It is not the continued processing task, which shows a card.
///
/// The task's name is read from Info.plist and never built from the bundle id: a signer changes the
/// bundle id (Poki Setup renames the entry with it, other signers may not), and registering a name
/// that is not in Info.plist ends the app. With no entry there, nothing is registered.
@MainActor
enum BackgroundRefresh {
    static let id: String? = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?
        .first { $0.hasSuffix(".refresh") }

    private static var registered = false
    /// How long a wake is held open, so what it started has time to settle.
    private static let holds: Duration = .seconds(20)

    /// Called once while the app starts, before it has finished launching, as iOS requires.
    static func register(onWake: @escaping @MainActor () -> Void) {
        guard let id, !registered else {
            if id == nil { AppLog.shared.add("background", "refresh: no task name in Info.plist, not used") }
            return
        }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            let work = Task { @MainActor in
                AppLog.shared.add("background", "refresh: iOS woke Poki")
                schedule()
                onWake()
                try? await Task.sleep(for: holds)
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
        if !registered { AppLog.shared.add("background", "refresh: iOS did not take the registration") }
    }

    /// Asks for the next wake, no sooner than a quarter of an hour from now. Asked again at every
    /// wake and every time Poki leaves the front; a newer request replaces the one before.
    static func schedule() {
        guard let id, registered else { return }
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            AppLog.shared.add("background", "refresh: not scheduled (\(error.localizedDescription)); is Background App Refresh on in Settings?")
        }
    }

    static func cancel() {
        guard let id, registered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
    }
}
