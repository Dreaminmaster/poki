import XCTest
@testable import Poki

/// Screen History keeps only what the owner allows: a left-out app or the Home Screen leaves no read
/// and no line in the record, a fresh install leaves out passwords, payments, messages and Apple's
/// sign-in sheet, and clearing everything leaves nothing behind. Reads go in as the launcher sends
/// them, through the same call a run makes.
@MainActor
final class ScreenHistoryTests: XCTestCase {
    private let keys = ["history.listMode", "history.excluded", "history.included"]
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        await HistoryStore.shared.deleteEverything()
    }

    override func tearDown() async throws {
        await HistoryStore.shared.deleteEverything()
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// A read as the launcher reports it for a screen whose text changed.
    private func read(_ app: String, _ text: [String]) -> [String: Any] {
        ["ok": true, "app": app, "title": "", "text": text, "changed": true]
    }

    func testALeftOutAppAndTheHomeScreenLeaveNothingInTheStore() async {
        let capture = HistoryCapture()
        capture.exclude("com.example.bank")
        let start = Date()
        XCTAssertFalse(capture.keep(read("com.example.bank", ["Balance", "12,480.00"])))
        XCTAssertFalse(capture.keep(read("com.apple.springboard", ["Notification", "Messages, now, Your code is 482913"])))
        let reads = await HistoryStore.shared.recent()
        let record = await HistoryStore.shared.records().filter { $0.at >= start }
        XCTAssertEqual(reads.map(\.text), [])
        XCTAssertEqual(record.map(\.kind), [])
    }

    func testAFreshInstallLeavesOutPasswordsPaymentsMessagesAndAppleSignIn() async {
        let capture = HistoryCapture()
        for app in ["com.apple.MobileSMS", "com.tencent.xin", "com.apple.Passwords", "com.alipay.iphoneclient", "com.apple.AuthKitUIService"] {
            XCTAssertFalse(capture.keep(read(app, ["Your code is 482913"])), app)
        }
        XCTAssertTrue(capture.keep(read("com.apple.mobilenotes", ["Shopping list"])))
        let reads = await HistoryStore.shared.recent()
        XCTAssertEqual(reads.map(\.app), ["com.apple.mobilenotes"])
    }

    func testReadsWithoutABundleIDLeaveNothingInTheStore() async {
        let capture = HistoryCapture()
        let unknown = ["", "Notes", "no app name, pid 412", "com.example bank", "com..bank", ".com.bank", "com.bank.", "com.bank/app", "com.\u{94F6}\u{884C}"]
        for mode in HistoryCapture.ListMode.allCases {
            capture.listMode = mode
            capture.included = unknown
            for app in unknown {
                XCTAssertFalse(capture.keep(read(app, ["Private account details"])), app)
            }
            XCTAssertFalse(capture.keep(["ok": true, "text": ["Private account details"]]))
        }
        let reads = await HistoryStore.shared.recent()
        let record = await HistoryStore.shared.records()
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(record.isEmpty)
        capture.listMode = .exclude
        XCTAssertTrue(capture.keep(read("com.example.Bank-2", ["Public page"])))
    }

    func testASummaryFinishingAfterDeletionCannotRestoreForgottenText() async {
        let capture = HistoryCapture()
        let store = HistoryStore.shared
        let start = Date().addingTimeInterval(-600)
        let end = start.addingTimeInterval(600)
        for clearAll in [true, false] {
            store.add(at: start, app: "com.apple.mobilenotes", title: "Notes", text: "Private shopping list")
            let source = await store.entries(from: start, to: end)
            XCTAssertEqual(source.map(\.text), ["Private shopping list"])
            if clearAll {
                await capture.clearEverything()
            } else {
                await capture.delete(from: start, to: end)
            }
            let reads = await store.recent()
            XCTAssertTrue(reads.isEmpty)
            store.keep(BacktapeNote(title: "Forgotten list", body: "Private shopping list"), start: start)
            let stale = await store.notes(from: .distantPast, to: .distantFuture)
            XCTAssertTrue(stale.isEmpty, "A late summary restored forgotten text")
            store.add(at: start, app: "com.apple.mobilenotes", title: "Notes", text: "New shopping list")
            store.keep(BacktapeNote(title: "New list", body: "New shopping list"), start: start)
            let fresh = await store.note(start: start)
            XCTAssertEqual(fresh?.title, "New list")
            await capture.clearEverything()
        }
    }

    func testClearingEverythingLeavesNoReadsSummariesOrRecord() async {
        let capture = HistoryCapture()
        HistoryStore.shared.add(at: Date(), app: "com.apple.mobilenotes", title: "Notes", text: "Shopping list")
        HistoryStore.shared.keep(BacktapeNote(title: "Shopping", body: "You wrote a list."), start: Date(timeIntervalSince1970: 1_800_000_000))
        HistoryStore.shared.note("leftOut", "com.example.bank")
        await capture.clearEverything()
        let size = await HistoryStore.shared.size()
        let notes = await HistoryStore.shared.notes(from: .distantPast, to: .distantFuture)
        let record = await HistoryStore.shared.records()
        XCTAssertEqual(size.entries, 0)
        XCTAssertEqual(notes.map(\.note.title), [])
        XCTAssertEqual(record.map(\.kind), [])
    }
}
