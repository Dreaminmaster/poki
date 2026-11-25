import XCTest
@testable import Poki

/// The Screen History card's parts, read from the on-device model's reply (2026-11-21).
@MainActor
final class SensesShareTests: XCTestCase {
    private func reads(_ app: String, from start: Date, count: Int, every: TimeInterval) -> [HistoryEntry] {
        (0..<count).map { HistoryEntry(id: Int64($0), at: start.addingTimeInterval(Double($0) * every), app: app, title: "", text: "") }
    }

    /// Guards: a sentinel NONE the model adds after a real answer does not reach the card or Poki's
    /// model, and a reply of only NONE is no answer. Fails if `isSentinel` or the trailing rule in
    /// `clean` is dropped, or if `parse` stops returning nil for a bare NONE.
    func testStrayNoneIsTakenOut() {
        let entries = reads("com.xingin.discover", from: Date(), count: 3, every: 60)
        let share = SensesShare.parse("The owner looked at a post about a proof.\nNONE.", entries: entries)
        XCTAssertEqual(share?.answer, "The owner looked at a post about a proof.")
        XCTAssertNil(SensesShare.parse("NONE", entries: entries))
        XCTAssertEqual(SensesShare.parse("The owner looked at a post about a proof. NONE.", entries: entries)?.answer,
                       "The owner looked at a post about a proof.")
    }

    /// Guards: NONE inside a title or a sentence is a word, not the sentinel (review of #627). Fails
    /// if `clean` goes back to removing every NONE, which turned "NONE left to lose" into "left to lose".
    func testNoneInsideATitleIsKept() {
        let entries = reads("com.spotify.client", from: Date(), count: 3, every: 60)
        let name = HistoryNames.app("com.spotify.client")
        let share = SensesShare.parse("They played NONE left to lose on \(name).\nITEM: \(name) | NONE left to lose", entries: entries)
        XCTAssertEqual(share?.answer, "They played NONE left to lose on \(name).")
        XCTAssertEqual(share?.item?.title, "NONE left to lose")
        XCTAssertNil(SensesShare.parse("A song.\nITEM: \(name) | NONE", entries: entries)?.item)
    }

    /// Guards: the card's app rows come from the answer's evidence, not from whatever was used
    /// longest around it (review of #627: a Reddit answer listed Spotify and Notes). Fails if `uses`
    /// falls back to the longest-used apps, or stops counting the item's app as evidence.
    func testOnlyTheAppsBehindTheAnswerAreListed() {
        let start = Date().addingTimeInterval(-3600)
        var entries = reads("com.spotify.client", from: start, count: 30, every: 60)
        entries += reads("com.apple.mobilenotes", from: start.addingTimeInterval(1900), count: 20, every: 60)
        entries.append(HistoryEntry(id: 99, at: start.addingTimeInterval(3300), app: "com.reddit.Reddit", title: "r/math", text: "A short proof that primes never run out"))
        let reddit = HistoryNames.app("com.reddit.Reddit")
        // Named through the item only.
        let share = SensesShare.parse("They read a post about a short proof.\nITEM: \(reddit) | A short proof", entries: entries)
        XCTAssertEqual(share?.apps.map(\.app), ["com.reddit.Reddit"])
        XCTAssertFalse(share?.text.contains(HistoryNames.app("com.spotify.client")) ?? true)
        // Named nowhere: the app whose own screen text holds the answer's words.
        let bare = SensesShare.parse("They read about primes and a short proof.", entries: entries)
        XCTAssertEqual(bare?.apps.map(\.app), ["com.reddit.Reddit"])
        // No evidence at all: no rows rather than unrelated ones.
        XCTAssertEqual(SensesShare.parse("Something else entirely.", entries: entries)?.apps.count, 0)
    }

    /// Guards: when the answer names no app and two apps both have screen text, the card lists the one
    /// whose text shares the most of the answer's words, and both only on a tie, in the order they were
    /// used (review of #649). Fails if the shared-words fallback lists every app with any shared word,
    /// or stops ordering the rows by first use.
    func testSharedWordsPickTheAppWhoseScreenTextFitsBest() {
        let start = Date().addingTimeInterval(-3600)
        let entries = [
            HistoryEntry(id: 1, at: start.addingTimeInterval(100), app: "com.apple.mobilenotes", title: "Groceries", text: "Milk, eggs, proof of purchase"),
            HistoryEntry(id: 2, at: start.addingTimeInterval(3300), app: "com.reddit.Reddit", title: "r/math", text: "A short proof that primes never run out"),
        ]
        let best = SensesShare.parse("They read about primes and a short proof.", entries: entries)
        XCTAssertEqual(best?.apps.map(\.app), ["com.reddit.Reddit"])
        let tie = SensesShare.parse("Something about a proof.", entries: entries)
        XCTAssertEqual(tie?.apps.map(\.app), ["com.apple.mobilenotes", "com.reddit.Reddit"])
    }

    /// Guards: the ITEM line becomes the card's item and leaves the answer text. Fails if the ITEM
    /// prefix is no longer recognized or the line is kept in the answer.
    func testItemLineBecomesTheItem() {
        let entries = reads("com.xingin.discover", from: Date(), count: 3, every: 60)
        let name = HistoryAppNames.name("com.xingin.discover")
        let share = SensesShare.parse("A post on \(name).\nITEM: \(name) | “A short proof”", entries: entries)
        XCTAssertEqual(share?.item?.title, "A short proof")
        XCTAssertFalse(share?.answer.contains("ITEM") ?? true)
        XCTAssertTrue(share?.text.contains("A short proof") ?? false)
    }

    /// Guards: a one-letter app name such as X is matched as a word, so "videos" does not name X.
    /// Fails if `mentions` drops its word boundaries.
    func testAShortNameIsMatchedAsAWord() {
        XCTAssertTrue(SensesShare.mentions("they used x and reddit", "x"))
        XCTAssertFalse(SensesShare.mentions("they watched videos", "x"))
    }
}
