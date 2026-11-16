import Foundation
import SQLite3

/// One kept read of the screen: when, which app, the screen's title where the tree gave one, and
/// the screen's text.
struct HistoryEntry: Identifiable, Hashable {
    let id: Int64
    let at: Date
    let app: String
    let title: String
    let text: String
}

/// One line of the observing record: when reading was on, paused, blocked or left an app out.
struct HistoryRecord: Identifiable, Hashable {
    let id: Int64
    let at: Date
    let kind: String
    let detail: String
}

/// iPhone History's record (issue 356): text in one database in Poki's own container.
///
/// The file is unreadable while the iPhone is locked (complete file protection) and is left out of
/// iCloud and device backups. Nothing in it leaves the phone. Every call runs on one serial queue.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "nz.zheha.poki.history-store", qos: .utility)
    private var db: OpaquePointer?
    private let folder: URL
    private let file: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("History", isDirectory: true)
        file = folder.appendingPathComponent("history.sqlite")
    }

    // MARK: Opening

    /// Opens the database when it is not open. Fails while the phone is locked, and is tried again
    /// at the next call.
    private func open() -> Bool {
        if db != nil { return true }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try? marked.setResourceValues(values)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_FILEPROTECTION_COMPLETE
        guard sqlite3_open_v2(file.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS entries (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, app TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS entries_at ON entries (at);
        CREATE TABLE IF NOT EXISTS record (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS record_at ON record (at);
        CREATE TABLE IF NOT EXISTS notes (start REAL PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    /// Closes the file, as when the phone locks: an open file stays readable under file protection.
    func close() {
        queue.async {
            if let db = self.db { sqlite3_close(db) }
            self.db = nil
        }
    }

    // MARK: Statements

    private enum Bound {
        case text(String)
        case real(Double)
        case integer(Int64)
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Bound] = []) -> Bool {
        guard open() else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Bound]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            }
        }
    }

    private func rows<Row>(_ sql: String, _ values: [Bound] = [], _ make: (OpaquePointer) -> Row) -> [Row] {
        guard open() else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var found: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(make(statement)) }
        return found
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func entry(_ statement: OpaquePointer) -> HistoryEntry {
        HistoryEntry(id: sqlite3_column_int64(statement, 0), at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                     app: string(statement, 2), title: string(statement, 3), text: string(statement, 4))
    }

    // MARK: Writing

    func add(at: Date, app: String, title: String, text: String) {
        queue.async {
            self.run("INSERT INTO entries (at, app, title, text) VALUES (?, ?, ?, ?)", [.real(at.timeIntervalSince1970), .text(app), .text(title), .text(text)])
        }
    }

    func note(_ kind: String, _ detail: String = "", at: Date = Date()) {
        queue.async {
            self.run("INSERT INTO record (at, kind, detail) VALUES (?, ?, ?)", [.real(at.timeIntervalSince1970), .text(kind), .text(detail)])
        }
    }

    /// Deletes entries older than `days`, the record older than 30 days, and then the oldest entries
    /// while the file is over `megabytes`.
    func prune(days: Int, megabytes: Int = 200) {
        queue.async {
            let now = Date().timeIntervalSince1970
            self.run("DELETE FROM entries WHERE at < ?", [.real(now - Double(days) * 86_400)])
            self.run("DELETE FROM notes WHERE start < ?", [.real(now - Double(days) * 86_400)])
            self.run("DELETE FROM record WHERE at < ?", [.real(now - 30 * 86_400)])
            var rounds = 0
            while self.bytesNow() > Int64(megabytes) * 1_048_576, rounds < 20 {
                self.run("DELETE FROM entries WHERE id IN (SELECT id FROM entries ORDER BY at LIMIT 2000)")
                self.run("VACUUM")
                rounds += 1
            }
        }
    }

    func delete(entry id: Int64) async {
        await perform {
            self.run("DELETE FROM entries WHERE id = ?", [.integer(id)])
            self.run("DELETE FROM notes")
        }
    }

    func delete(from start: Date, to end: Date) async {
        await perform {
            self.run("DELETE FROM entries WHERE at >= ? AND at < ?", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
            self.run("DELETE FROM notes WHERE start >= ? AND start < ?", [.real(start.timeIntervalSince1970 - 600), .real(end.timeIntervalSince1970)])
            // Notes of an hour, a day or a week (kept a fraction of a second off the whole second,
            // see BacktapeZoom.key) that hold any of the forgotten time go too.
            self.run("DELETE FROM notes WHERE start != CAST(start AS INTEGER) AND start >= ? AND start < ?", [.real(start.timeIntervalSince1970 - 8 * 86_400), .real(end.timeIntervalSince1970)])
        }
    }

    func delete(app: String) async {
        await perform {
            self.run("DELETE FROM entries WHERE app = ?", [.text(app)])
            self.run("DELETE FROM notes")
        }
    }

    func deleteEverything() async {
        await perform {
            self.run("DELETE FROM entries")
            self.run("DELETE FROM notes")
            self.run("VACUUM")
        }
    }

    // MARK: Notes

    /// Keeps the note written for the block that starts at `start`.
    func keep(_ note: BacktapeNote, start: Date) {
        queue.async {
            self.run("INSERT OR REPLACE INTO notes (start, title, body) VALUES (?, ?, ?)", [.real(start.timeIntervalSince1970), .text(note.title), .text(note.body)])
        }
    }

    func note(start: Date) async -> BacktapeNote? {
        await fetch {
            self.rows("SELECT title, body FROM notes WHERE start = ?", [.real(start.timeIntervalSince1970)]) {
                BacktapeNote(title: Self.string($0, 0), body: Self.string($0, 1))
            }.first
        }
    }

    /// The kept notes whose blocks start in a span, oldest first, with the key each was kept under.
    func notes(from start: Date, to end: Date) async -> [(start: Double, note: BacktapeNote)] {
        await fetch {
            self.rows("SELECT start, title, body FROM notes WHERE start >= ? AND start < ? ORDER BY start", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]) {
                (start: sqlite3_column_double($0, 0), note: BacktapeNote(title: Self.string($0, 1), body: Self.string($0, 2)))
            }
        }
    }

    // MARK: Reading

    /// The newest entries with only the start of their text, for the list of blocks.
    func recent(limit: Int = 60_000) async -> [HistoryEntry] {
        await fetch {
            self.rows("SELECT id, at, app, title, substr(text, 1, 240) FROM entries ORDER BY at DESC LIMIT ?", [.integer(Int64(limit))], Self.entry)
        }
    }

    /// Whole entries of one span, oldest first, for an opened block.
    func entries(from start: Date, to end: Date) async -> [HistoryEntry] {
        await fetch {
            self.rows("SELECT id, at, app, title, text FROM entries WHERE at >= ? AND at < ? ORDER BY at", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)], Self.entry)
        }
    }

    /// Apps with kept reads, the most read first.
    func apps() async -> [String] {
        await fetch {
            self.rows("SELECT app FROM entries GROUP BY app ORDER BY COUNT(*) DESC LIMIT 200") { Self.string($0, 0) }.filter { !$0.isEmpty }
        }
    }

    func records(limit: Int = 500) async -> [HistoryRecord] {
        await fetch {
            self.rows("SELECT id, at, kind, detail FROM record ORDER BY at DESC, id DESC LIMIT ?", [.integer(Int64(limit))]) {
                HistoryRecord(id: sqlite3_column_int64($0, 0), at: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)), kind: Self.string($0, 2), detail: Self.string($0, 3))
            }
        }
    }

    /// Entries kept and the file's size in bytes.
    func size() async -> (entries: Int, bytes: Int64) {
        await fetch {
            let count = self.rows("SELECT COUNT(*) FROM entries") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            return (count, self.bytesNow())
        }
    }

    private func bytesNow() -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func perform(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                done.resume()
            }
        }
    }

    private func fetch<Value>(_ work: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { (done: CheckedContinuation<Value, Never>) in
            queue.async { done.resume(returning: work()) }
        }
    }
}
