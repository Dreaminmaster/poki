import Foundation
import Darwin

// The standalone signer fixture has no iOS App Group.
enum SharedContainer { static let defaults = UserDefaults.standard }

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

typealias UIBackgroundTaskIdentifier = Int
extension Int { static let invalid = -1 }

final class UIApplication {
    static let shared = UIApplication()
    static let willEnterForegroundNotification = Notification.Name("willEnterForeground")
    private var nextTask = 0
    var backgroundTasks: Set<Int> = []
    func beginBackgroundTask(withName: String) -> Int {
        nextTask += 1
        backgroundTasks.insert(nextTask)
        return nextTask
    }
    func endBackgroundTask(_ id: Int) { backgroundTasks.remove(id) }
    var suspendedAfterSave = false
    func perform(_ selector: Selector) {
        suspendedAfterSave = UpdateResources.stopped && UpdateResources.savedAfterStop
    }
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
    @MainActor static var holdsInstall = false
    @MainActor static var installHeld: CheckedContinuation<Void, Never>?
    @MainActor static var finishInstall: CheckedContinuation<Void, Never>?
    @MainActor static var prepareHeld: CheckedContinuation<Void, Never>?
    @MainActor static var finishPrepare: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) static var installProgress: (@Sendable ([String: Any]) -> Void)?
    static func installVault() {}
    @MainActor static func holdInstall() async {
        guard holdsInstall else { return }
        await withCheckedContinuation { finishInstall = $0; installHeld?.resume() }
    }
    @MainActor static func holdPrepare() async {
        guard prepareHeld != nil else { return }
        await withCheckedContinuation { finishPrepare = $0; prepareHeld?.resume() }
    }
    static func call(_ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> Data {
        installProgress = progress
        progress?(["kind": "step", "id": "install"])
        await Task.yield()
        await holdInstall()
        if fails { throw SignerError(message: "Installation failed.", code: "device") }
        return Data()
    }
    static func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> T {
        progress?(["kind": "step", "id": "release", "title": "Getting the newest Poki"])
        await Task.yield()
        await holdPrepare()
        let prepared = #"{"kind":"update","ipa":"/tmp/test.ipa","bundle_id":"test.poki","version":"9.0.0","build":"9999","tag":"test","team_name":"Test","team_is_free":true,"profile_expires_at":0,"prepared_at":0}"#
        return try JSONDecoder().decode(type, from: Data(prepared.utf8))
    }
}

enum UpdateResources {
    nonisolated(unsafe) static var voiceAudio = true
    nonisolated(unsafe) static var pairingListener = true
    nonisolated(unsafe) static var audio = true
    nonisolated(unsafe) static var pairingAudio = true
    nonisolated(unsafe) static var location = true
    nonisolated(unsafe) static var continuedRun = true
    nonisolated(unsafe) static var activity = true
    nonisolated(unsafe) static var automation = true
    nonisolated(unsafe) static var savedAfterStop = false
    nonisolated(unsafe) static var holdClose = false
    nonisolated(unsafe) static var finishClose: (@MainActor () -> Void)?
    nonisolated(unsafe) static var holdActivity = false
    nonisolated(unsafe) static var finishActivity: CheckedContinuation<Void, Never>?
    static var stopped: Bool { !voiceAudio && !pairingListener && !audio && !pairingAudio && !location && !continuedRun && !activity && !automation }
}
final class BackgroundKeeper {
    func stop() { UpdateResources.audio = false; UpdateResources.continuedRun = false }
    func releasePairing() { UpdateResources.location = false }
}
final class KeepAlive { func stop() { UpdateResources.pairingAudio = false } }
enum ActivityUIDismissalPolicy { case immediate }
final class ActivityController {
    @discardableResult func end(dismissalPolicy: ActivityUIDismissalPolicy? = nil) -> Task<Void, Never>? {
        Task {
            if UpdateResources.holdActivity {
                await withCheckedContinuation { UpdateResources.finishActivity = $0 }
            }
            UpdateResources.activity = false
        }
    }
}
final class Launcher { func stop() {} }
final class VoiceModel { func stop() { UpdateResources.voiceAudio = false } }
final class Pairer { func cancel() { UpdateResources.pairingListener = false } }
enum RunnerProbe { static func shutdown() async { UpdateResources.automation = false } }
enum AttentionNotice { static func clear() {} }
final class SessionStore {
    static let shared = SessionStore()
    func flush() { UpdateResources.savedAfterStop = UpdateResources.stopped }
}
enum ProcessExit {
    nonisolated(unsafe) static var attempts: [Int32] = []
    nonisolated(unsafe) static var real = false
    nonisolated(unsafe) static var safe = false
    static func terminate(_ code: Int32) {
        attempts.append(code)
        safe = UpdateResources.stopped && UpdateResources.savedAfterStop && UIApplication.shared.backgroundTasks.isEmpty
        if real {
            guard safe, code == 0 else { Darwin.exit(93) }
            print("PASS: confirmed update terminates the process with status 0")
            Darwin.exit(code)
        }
    }
}
final class DispatchQueue {
    static let main = DispatchQueue()
    private var pending: [() -> Void] = []
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { pending.append(execute) }
    func runPending() {
        let actions = pending
        pending = []
        for action in actions { action() }
    }
}

final class FakeCore {
    func stop() {}
    func tool(_ name: String, arguments: String) async -> (text: String, isError: Bool) {
        ("UNEXPECTED: task reached the closed automation session", false)
    }
}

@main struct UpdateFinishRegression {
    @MainActor static func prepared() async -> SelfSigner {
        let signer = SelfSigner()
        signer.phone = { [:] }
        signer.isIdle = { true }
        await signer.prepare(kind: "update")
        return signer
    }

    @MainActor static func installed() async -> SelfSigner {
        let signer = await prepared()
        await signer.install()
        signer.finishNoticeAnswered()
        return signer
    }

    @MainActor static func drain() async {
        for _ in 0..<20 { DispatchQueue.main.runPending(); await Task.yield() }
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
        let language = CommandLine.arguments.first { ["en", "zh-Hans", "zh-Hant"].contains($0) } ?? "en"
        AppLocalization.shared.preference = language
        let expected: String
        let beforeConfirmation: String
        switch language {
        case "zh-Hans":
            expected = "如果几秒内没完成，请从多任务界面划掉 Poki 再打开。重新打开 Poki 前，功能暂不可用。"
            beforeConfirmation = "正在安装更新。重新打开 Poki 前，功能暂不可用。"
        case "zh-Hant":
            expected = "如果幾秒內沒完成，請從多工處理畫面滑掉 Poki 再開啟。重新開啟 Poki 前，功能暫不可用。"
            beforeConfirmation = "正在安裝更新。重新開啟 Poki 前，功能暫不可用。"
        default:
            expected = "If the update has not finished after a few seconds, swipe up on Poki in the app switcher to close it, then open Poki again. Features are unavailable until you reopen Poki."
            beforeConfirmation = "Installing the update. Features are unavailable until you reopen Poki."
        }
        print("Language: \(language)")
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
        check(task.isError && task.text == expected, "task during update is refused with an explanation", actual: task.text)
        let afterTimeout = await AppModel(signer: timedOut).phoneTool("look", arguments: "{}")
        check(afterTimeout.isError && afterTimeout.text == expected, "task after timeout receives restart instructions", actual: afterTimeout.text)

        let downloading = SelfSigner()
        downloading.phone = { [:] }
        let prepare = Task { @MainActor in await downloading.prepare(kind: "update") }
        await withCheckedContinuation { SignerBridge.prepareHeld = $0 }
        Timer.advance(by: 15, oldProcessAlive: true)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drain()
        check(downloading.installMessage == nil && !downloading.needsReopen,
              "unfinished preparation does not show exit instructions", actual: downloading.installMessage)
        SignerBridge.prepareHeld = nil
        SignerBridge.finishPrepare?.resume()
        await prepare.value

        SignerBridge.holdsInstall = true
        let slow = await prepared()
        let install = Task { @MainActor in await slow.install() }
        await withCheckedContinuation { SignerBridge.installHeld = $0 }
        await drain()
        check(slow.finishNotice, "a running install announces that Poki will close")
        check(slow.installMessage == beforeConfirmation, "unconfirmed install does not offer an early manual close", actual: slow.installMessage)
        slow.finishNoticeAnswered()
        check(slow.installMessage == expected, "confirmed install without percentage shows restart instructions", actual: slow.installMessage)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drain()
        check(!slow.needsReopen && slow.installMessage == expected, "foreground return without percentage preserves restart instructions", actual: slow.installMessage)
        Timer.advance(by: 15, oldProcessAlive: true)
        await drain()
        check(!slow.needsReopen && slow.installMessage == expected, "missing percentage after 15 seconds preserves restart instructions", actual: slow.installMessage)
        for fraction in [0.0, 0.4, 0.9] {
            SignerBridge.installProgress?(["kind": "part", "id": "install", "fraction": fraction])
            await drain()
            check(slow.installMessage == expected && !slow.needsReopen,
                  "system installation at \(fraction) offers conditional exit guidance without claiming success", actual: slow.installMessage)
        }
        SignerBridge.holdsInstall = false
        SignerBridge.finishInstall?.resume()
        await install.value
        Timer.advance(by: 4, oldProcessAlive: true)
        await drain()
        let afterFour = slow.installMessage
        Timer.advance(by: 1, oldProcessAlive: true)
        await drain()
        check(afterFour == expected && slow.needsReopen && slow.working == expected,
              "the confirmed exit falls back after 5 seconds", actual: "\(afterFour ?? "nil") | then: \(slow.working ?? "nil")")

        ProcessExit.attempts = []
        ProcessExit.real = CommandLine.arguments.contains("--exit-process")
        UpdateResources.holdClose = true
        UpdateResources.holdActivity = true
        SignerBridge.holdsInstall = true
        let closing = await prepared()
        let model = AppModel(signer: closing)
        model.wireSigner()
        let updating = Task { @MainActor in await closing.install() }
        await withCheckedContinuation { SignerBridge.installHeld = $0 }
        await drain()
        closing.finishNoticeAnswered()
        await drain()
        check(ProcessExit.attempts.isEmpty, "confirming before upload completes does not exit")
        check(ProcessExit.attempts.isEmpty && !UpdateResources.savedAfterStop,
              "pending automation close prevents saving and exit")
        check(!UpdateResources.audio && !UpdateResources.continuedRun && !UpdateResources.voiceAudio,
              "confirmation stops audio without waiting for installation percentage")
        UpdateResources.finishClose?()
        UpdateResources.finishClose = nil
        await drain()
        check(ProcessExit.attempts.isEmpty && !UpdateResources.savedAfterStop,
              "pending Live Activity dismissal prevents saving and exit")
        UpdateResources.finishActivity?.resume()
        UpdateResources.finishActivity = nil
        await drain()
        check(UpdateResources.stopped && UpdateResources.savedAfterStop && UIApplication.shared.suspendedAfterSave,
              "confirmation stops runtime, saves state, and backgrounds before installation percentage",
              actual: "resources stopped \(UpdateResources.stopped), saved \(UpdateResources.savedAfterStop), suspended safely \(UIApplication.shared.suspendedAfterSave)")
        check(ProcessExit.attempts.isEmpty && !UIApplication.shared.backgroundTasks.isEmpty,
              "upload keeps its background task until the system accepts installation")
        SignerBridge.installProgress?(["kind": "part", "id": "install", "fraction": 0.4])
        await drain()
        check(ProcessExit.attempts == [0] && ProcessExit.safe,
              "confirmed system installation stops keep-alives, saves state, and exits normally",
              actual: "exit codes \(ProcessExit.attempts), resources stopped \(UpdateResources.stopped), saved after stop \(UpdateResources.savedAfterStop), background tasks \(UIApplication.shared.backgroundTasks.count)")
        closing.finishNoticeAnswered()
        await drain()
        check(ProcessExit.attempts.count <= 1, "duplicate confirmation does not repeat exit")
        Timer.advance(by: 5, oldProcessAlive: true)
        await drain()
        check(closing.needsReopen && closing.installMessage == expected,
              "surviving process gets fallback without claiming install success", actual: closing.installMessage)
        SignerBridge.holdsInstall = false
        SignerBridge.finishInstall?.resume()
        await updating.value
        check(closing.needsReopen && closing.installMessage == expected,
              "late install result preserves restart instructions", actual: closing.installMessage)

        SignerBridge.fails = true
        let failed = await installed()
        check(failed.lastError == "Installation failed." && failed.working == expected, "failed installation does not claim the update is installed", actual: failed.working)
        Darwin.exit(failures == 0 ? 0 : 1)
    }
}
