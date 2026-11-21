import XCTest
@testable import Poki

/// The Screen History card's parts, read from the on-device model's reply (2026-11-21).
final class SensesShareTests: XCTestCase {
    private func reads(_ app: String, from start: Date, count: Int, every: TimeInterval) -> [HistoryEntry] {
        (0..<count).map { HistoryEntry(id: Int64($0), at: start.addingTimeInterval(Double($0) * every), app: app, title: "", text: "") }
    }

    func testStrayNoneIsTakenOut() {
        let entries = reads("com.xingin.discover", from: Date(), count: 3, every: 60)
        let share = SensesShare.parse("The owner looked at a post about a proof.\nNONE.", entries: entries)
        XCTAssertEqual(share?.answer, "The owner looked at a post about a proof.")
        XCTAssertNil(SensesShare.parse("NONE", entries: entries))
    }

    func testItemLineBecomesTheItem() {
        let entries = reads("com.xingin.discover", from: Date(), count: 3, every: 60)
        let name = HistoryNames.app("com.xingin.discover")
        let share = SensesShare.parse("A post on \(name).\nITEM: \(name) | “A short proof”", entries: entries)
        XCTAssertEqual(share?.item?.title, "A short proof")
        XCTAssertFalse(share?.answer.contains("ITEM") ?? true)
        XCTAssertTrue(share?.text.contains("A short proof") ?? false)
    }

    func testAShortNameIsMatchedAsAWord() {
        XCTAssertTrue(SensesShare.mentions("they used x and reddit", "x"))
        XCTAssertFalse(SensesShare.mentions("they watched videos", "x"))
    }
}
