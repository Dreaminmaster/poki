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
    static func installVault() {}
    static func call(_ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> Data {
        progress?(["kind": "step", "id": "install"])
        await Task.yield()
        return Data()
    }
    static func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> T {
        let prepared = #"{"kind":"update","ipa":"/tmp/test.ipa","bundle_id":"test.poki","version":"9.0.0","build":"9999","tag":"test","team_name":"Test","team_is_free":true,"profile_expires_at":0,"prepared_at":0}"#
        return try JSONDecoder().decode(type, from: Data(prepared.utf8))
    }
}

@main struct UpdateFinishRegression {
    @MainActor static func main() async {
        let signer = SelfSigner()
        signer.phone = { [:] }
        signer.isIdle = { true }
        await signer.prepare(kind: "update")
        await signer.install()
        signer.finishNoticeAnswered()
        Timer.advance(by: 15, oldProcessAlive: true)
        for _ in 0..<20 { await Task.yield() }
        let expected = "The update is installed. Swipe up on Poki in the app switcher to close it, then open Poki again. Features are unavailable until you reopen Poki."
        guard signer.working == expected else {
            print("FAIL: timeout should show restart instructions; got: \(signer.working ?? "nil")")
            exit(1)
        }
        print("PASS: timeout shows restart instructions")
    }
}
