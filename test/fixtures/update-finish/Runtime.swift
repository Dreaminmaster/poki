import Foundation

final class Timer: @unchecked Sendable {
    nonisolated(unsafe) static var now: TimeInterval = 0
    nonisolated(unsafe) static var pending: [Timer] = []
    let deadline: TimeInterval
    let action: (Timer) -> Void
    var valid = true
    init(seconds: TimeInterval, action: @escaping (Timer) -> Void) {
        deadline = Self.now + seconds
        self.action = action
    }
    static func scheduledTimer(withTimeInterval seconds: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(seconds: seconds, action: block)
        pending.append(timer)
        return timer
    }
    func invalidate() { valid = false }
    static func advance(by seconds: TimeInterval, oldProcessAlive: Bool) {
        now += seconds
        let due = pending.filter { $0.valid && $0.deadline <= now }
        for timer in due {
            timer.invalidate()
            if oldProcessAlive { timer.action(timer) }
        }
    }
}

final class UIApplication {
    static let shared = UIApplication()
    static let willEnterForegroundNotification = Notification.Name("willEnterForeground")
    func beginBackgroundTask(withName: String) -> Int { 1 }
    func endBackgroundTask(_ id: Int) {}
    func perform(_ selector: Selector) {}
}
final class UIDevice { static let current = UIDevice(); let name = "Test iPhone" }
final class UNMutableNotificationContent {
    var title = "", body = ""
    var userInfo: [AnyHashable: Any] = [:]
}
struct UNTimeIntervalNotificationTrigger { init(timeInterval: TimeInterval, repeats: Bool) {} }
struct UNNotificationRequest {
    init(identifier: String, content: UNMutableNotificationContent, trigger: UNTimeIntervalNotificationTrigger?) {}
}
final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    func add(_ request: UNNotificationRequest) {}
    func removePendingNotificationRequests(withIdentifiers: [String]) {}
}
final class AppLog {
    static let shared = AppLog()
    func add(_ kind: String, _ message: String) {}
}
enum AppFiles { static let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
enum LoopbackMonitor { static let needsWiFi = "Connect to Wi-Fi." }
enum SignerBridge {
    nonisolated(unsafe) static var fails = false
    static func installVault() {}
    static func call(_ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> Data {
        progress?(["kind": "step", "id": "install"])
        await Task.yield()
        if fails { throw SignerError(message: "Installation failed.", code: "device") }
        return Data()
    }
    static func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> T {
        let prepared = #"{"kind":"update","ipa":"/tmp/test.ipa","bundle_id":"test.poki","version":"9.0.0","build":"9999","tag":"test","team_name":"Test","team_is_free":true,"profile_expires_at":0,"prepared_at":0}"#
        return try JSONDecoder().decode(type, from: Data(prepared.utf8))
    }
}

final class FakeCore {
    func tool(_ name: String, arguments: String) async -> (text: String, isError: Bool) {
        ("UNEXPECTED: task reached the closed automation session", false)
    }
}

@main struct UpdateFinishRegression {
    @MainActor static func installed() async -> SelfSigner {
        let signer = SelfSigner()
        signer.phone = { [:] }
        signer.isIdle = { true }
        await signer.prepare(kind: "update")
        await signer.install()
        signer.finishNoticeAnswered()
        return signer
    }

    @MainActor static func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ label: String, actual: String? = nil) {
        guard condition else {
            print("FAIL: \(label); got: \(actual ?? "nil")")
            failures += 1
            return
        }
        print("PASS: \(label)")
    }

    @MainActor static func main() async {
        let expected = "The update is installed. Swipe up on Poki in the app switcher to close it, then open Poki again. Features are unavailable until you reopen Poki."
        let timedOut = await installed()
        Timer.advance(by: 15, oldProcessAlive: true)
        await drain()
        check(timedOut.working == expected, "timeout shows restart instructions", actual: timedOut.working)

        let returned = await installed()
        Timer.advance(by: 1, oldProcessAlive: true)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drain()
        check(returned.working == expected, "foreground return shows restart instructions before timeout", actual: returned.working)

        let waiting = await installed()
        let task = await AppModel(signer: waiting).phoneTool("look", arguments: "{}")
        check(task.isError && task.text == "The update is installed. Waiting for Poki to close. Features are unavailable until you reopen Poki.", "task during update is refused with an explanation", actual: task.text)
        let afterTimeout = await AppModel(signer: timedOut).phoneTool("look", arguments: "{}")
        check(afterTimeout.isError && afterTimeout.text == expected, "task after timeout receives restart instructions", actual: afterTimeout.text)

        SignerBridge.fails = true
        let failed = await installed()
        check(failed.lastError == "Installation failed." && failed.working?.contains("If the update is still available, try again.") == true, "failed installation does not claim the update is installed", actual: failed.working)
        exit(failures == 0 ? 0 : 1)
    }
}
