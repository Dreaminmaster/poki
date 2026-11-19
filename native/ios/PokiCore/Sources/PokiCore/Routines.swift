import Foundation

// Routines and notes: the agent's memory, kept on the phone and shared by every agent that drives it
// (Poki's own chat and any MCP client over the relay).
//
// A task's `do` actions are recorded as they are sent, each target as what it is (role, label,
// identifier, and where it was) rather than its number, which changes from read to read. A recorded
// task saved under a name is a routine; `do {run: "name"}` replays it in one call. Each step waits for
// its target to be on screen, acts only on a single match, and stops at the first screen that differs,
// so a routine never taps the wrong thing: the agent goes on from the read the stop answers with.
// A routine keeps its runs, so one that keeps stopping is marked stale and no longer offered.
//
// Notes are short facts the agent or the owner saves ("Mom is the contact Mama"). Both live in one
// JSON file in the app's own storage; a copy in Documents/AgentBackup is what Poki Setup backs up.
// Typed text is a parameter of the routine; text typed into a password field is never stored.
//
// The owner can lock a note or a routine on the Memory page: no agent changes, replaces or forgets a
// locked one, and the caps never drop it. Every addition, change and forget is logged (the page's
// Recent Updates), and a change can be undone; a forgotten item is kept in its log entry so undo puts
// it back exactly. Fields added after the first release are optional, so a file written before them
// opens with everything in it.

/// What a step acts on, as it was found when the step was recorded.
public struct RoutineTarget: Codable, Equatable, Sendable {
    public var type: String
    public var label: String?
    public var identifier: String?
    /// The element's centre when recorded: picks one of several matches that are otherwise alike.
    public var x: Double
    public var y: Double

    /// A path's target: any element that reads `label`, whatever its type.
    static let anyType = "*"

    /// A target named by its text alone (a path's step): no recorded place.
    init(type: String, label: String) {
        self.type = type
        self.label = label
        identifier = nil
        x = -1
        y = -1
    }

    /// Whether the target was recorded at a place on the screen.
    var hasPlace: Bool { x >= 0 && y >= 0 }

    init(_ e: Element) {
        type = e.type
        label = e.label.flatMap { $0.isEmpty ? nil : $0 }
        identifier = e.identifier.flatMap { $0.isEmpty ? nil : $0 }
        let c = e.frame.centre
        x = (c.x * 10).rounded() / 10
        y = (c.y * 10).rounded() / 10
    }

    public var describe: String { type == Self.anyType ? "\"\(label ?? identifier ?? "")\"" : "\(type) \"\(label ?? identifier ?? "")\"" }

    func matches(_ e: Element) -> Bool {
        if type == Self.anyType {
            // By its text, as written or in another case; a container is never the thing to tap.
            guard !e.fromPicture, !Computer.containers.contains(e.type), let label, !label.isEmpty else { return false }
            return e.label?.caseInsensitiveCompare(label) == .orderedSame || e.identifier?.caseInsensitiveCompare(label) == .orderedSame
        }
        guard !e.fromPicture, e.type == type else { return false }
        if let identifier, e.identifier == identifier { return label == nil || e.label == label }
        return (e.label.flatMap { $0.isEmpty ? nil : $0 }) == label && (identifier == nil || e.identifier == nil || e.identifier == identifier)
    }
}

/// One recorded action. `action` is the `do` action with its element number taken out; `target` is
/// what the number pointed at. A type's text is `{{name}}` of a parameter.
public struct RoutineStep: Codable, Equatable, Sendable {
    public var action: JSON
    public var target: RoutineTarget?
    /// The app in front when the step was sent.
    public var app: String?
    /// A type into a password field: the text was not kept, so a run stops here for the agent.
    public var secret: Bool?
    /// Texts that must be on screen once the step is done ({tap: "Wi-Fi", expect: "Networks"}): read
    /// from the tree with no model; the run stops there when one does not appear.
    public var expect: [String]? = nil
    /// A step for something that is only sometimes there ({tap: "Not Now", optional: true}): when its
    /// target is not on a screen that holds still, the step is left out and the run goes on.
    public var optional: Bool? = nil
}

public struct RoutineStop: Codable, Equatable, Sendable {
    public var step: Int
    public var why: String
    public var at: Date
}

public struct Routine: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// The app the routine works in (it is launched first when another app is in front).
    public var app: String?
    public var steps: [RoutineStep]
    /// Parameters and the values they were recorded with: `{{text_1}}` in a type.
    public var params: [String: String]
    /// Texts that must be on screen when the routine has run (its end check).
    public var expect: [String]
    /// Labels whose values the run reads off the last screen (a learned readout).
    public var read: [String]
    public var runs: Int
    public var ok: Int
    /// Runs that stopped in a row; two or more mark the routine stale.
    public var failuresInARow: Int
    public var lastStop: RoutineStop?
    public var lastMs: Int?
    /// Texts of controls that may be closed when they are in the way of a step (a path's
    /// dismiss: ["Not Now", "Later"]): written ahead by the agent, applied with no model.
    public var dismiss: [String]? = nil
    public var savedBy: String
    public var created: Date
    public var updated: Date
    /// Locked by the owner: no agent saves over it, edits, renames or forgets it.
    public var locked: Bool? = nil

    public var stale: Bool { failuresInARow >= 2 }
    public var isLocked: Bool { locked == true }
    public var summary: String {
        "\(name): \(description.isEmpty ? "" : description + "; ")\(app.map { "in \($0), " } ?? "")\(steps.count) steps, \(runs) runs, \(ok) ok\(stale ? ", STALE (stopped \(failuresInARow) times in a row\(lastStop.map { " at step \($0.step): \($0.why)" } ?? ""))" : "")\(params.isEmpty ? "" : ", with: " + params.keys.sorted().map { "\($0) (recorded \"\(params[$0]!.prefix(30))\")" }.joined(separator: ", "))"
    }
}

public struct MemoryNote: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var by: String
    public var at: Date
    /// Locked by the owner: no agent changes or forgets it.
    public var locked: Bool? = nil
    /// The app it is about (the Memory page's Used In); nil: no one app.
    public var app: String? = nil
    /// The conversation Poki's chat heard it in.
    public var heard: NoteOrigin? = nil
    /// When the owner last changed it.
    public var edited: Date? = nil

    public var isLocked: Bool { locked == true }
}

/// Where a note was heard: a saved conversation, and the app in front then.
public struct NoteOrigin: Codable, Equatable, Sendable {
    public var session: String
    public var app: String?
    public init(session: String, app: String?) { self.session = session; self.app = app }
}

/// One addition, change or forget, for Recent Updates and undo.
public struct MemoryChangeRecord: Codable, Equatable, Sendable {
    /// "added", "edited" or "forgot" (a string, so a later kind never makes the file unreadable).
    public var action: String
    public var id: String
    public var at: Date
    /// "owner", or the agent's name ("Poki", an MCP client's).
    public var by: String
    /// The note after the change, or as it was when forgotten.
    public var note: MemoryNote?
    /// A routine's name after the change (and `app`); `routine` is the whole routine as it was before
    /// a forget or a change, to put back.
    public var routineName: String?
    public var routineApp: String?
    public var routine: Routine?
    /// An edit's text, or a rename's name, before.
    public var previous: String?
    /// The note as it was before an edit (its app, source and lock too), to put back.
    public var before: MemoryNote?
    public var undone: Bool?

    public static let added = "added", edited = "edited", forgot = "forgot"
}

/// One routine run, for the maintainers' log bundle.
public struct RoutineRunLog: Codable, Equatable, Sendable {
    public var routine: String
    public var at: Date
    public var ms: Int
    public var outcome: String
    public var steps: [String]
}

/// The file: routines, notes and the latest runs. The backup file has the same shape plus `schema`.
struct MemoryFile: Codable {
    var schema = RoutineStore.schema
    var exported: Date?
    var routines: [Routine] = []
    var notes: [MemoryNote] = []
    var runs: [RoutineRunLog] = []
    /// What the app adds to a backup (its saved sessions), opaque here.
    var extras: [String: JSON]?
    /// The latest changes, newest first. Kept on the phone only: an export leaves them out, since a
    /// forgotten note's text lives on in its entry until it falls off the end.
    var changes: [MemoryChangeRecord]? = nil
}

/// The agent's memory: thread-safe, saved to one file after every change.
public final class RoutineStore: @unchecked Sendable {
    public static let schema = "poki.agent-backup/1"
    public static let backupName = "poki-agent-backup.json"
    static let maxNotes = 50, maxRoutines = 200, maxRuns = 50, maxNoteLength = 300, maxChanges = 100
    /// Who the Memory page writes as.
    public static let owner = "owner"
    /// The names that are not an agent's: the owner, a file the owner imported or restored, and Dream.
    static func isReserved(_ name: String) -> Bool { [owner, "import", "restore", "dream"].contains(name.lowercased()) }

    private let lock = NSLock()
    private var file = MemoryFile()
    /// Where the memory is kept (nil: in memory only, as in tests).
    public let url: URL?
    /// Where a copy goes after every change, for Poki Setup's backup (Documents/AgentBackup).
    public let backupDirectory: URL?
    private var lastBackupHash: String?

    public init(url: URL?, backupDirectory: URL? = nil) {
        self.url = url
        self.backupDirectory = backupDirectory
        if let url, let data = try? Data(contentsOf: url) {
            if let saved = try? Self.decoder.decode(MemoryFile.self, from: data) {
                file = saved
            } else {
                // A file this version cannot read is set aside, not written over with an empty memory.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: url, to: aside)
            }
        }
        if let backupDirectory { lastBackupHash = try? String(contentsOf: backupDirectory.appendingPathComponent(".last-written"), encoding: .utf8) }
    }

    /// The shared memory of the app (Application Support/Poki/agent-memory.json, and its backup copy
    /// in Documents/AgentBackup). The app may replace it before PokiCore starts.
    public static var shared: RoutineStore = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Poki", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AgentBackup", isDirectory: true)
        #if os(iOS)
        return RoutineStore(url: support?.appendingPathComponent("agent-memory.json"), backupDirectory: documents)
        #else
        return RoutineStore(url: nil)
        #endif
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func withFile<T>(_ change: Bool = false, _ body: (inout MemoryFile) throws -> T) rethrows -> T {
        lock.lock()
        let result = try body(&file)
        let snapshot = change ? file : nil
        lock.unlock()
        if let snapshot { persist(snapshot) }
        return result
    }

    /// Notified after every change (the app's Memory page).
    public var onChange: (@Sendable () -> Void)?

    private func persist(_ snapshot: MemoryFile) {
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? Self.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        if let backupDirectory, let data = try? exportData(includeExtras: false) {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let target = backupDirectory.appendingPathComponent(Self.backupName)
            try? data.write(to: target, options: .atomic)
            let hash = Self.hash(data)
            lastBackupHash = hash
            try? hash.write(to: backupDirectory.appendingPathComponent(".last-written"), atomically: true, encoding: .utf8)
        }
        onChange?()
    }

    static func hash(_ data: Data) -> String {
        // FNV-1a: only to tell our own copy from one put there by Poki Setup.
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// A backup file Poki Setup put in Documents/AgentBackup since the app last wrote it is merged in.
    /// Returns what was imported, or nil when there was nothing new.
    @discardableResult
    public func importRestoredBackup() -> String? {
        guard let backupDirectory else { return nil }
        let target = backupDirectory.appendingPathComponent(Self.backupName)
        guard let data = try? Data(contentsOf: target), Self.hash(data) != lastBackupHash else { return nil }
        return try? importData(data, by: "restore")
    }

    // MARK: Reading

    public var routines: [Routine] { withFile { $0.routines } }
    public var notes: [MemoryNote] { withFile { $0.notes } }
    /// The latest changes, newest first.
    public var changes: [MemoryChangeRecord] { withFile { $0.changes ?? [] } }
    public func note(_ idOrText: String) -> MemoryNote? {
        withFile { f in f.notes.first { $0.id == idOrText || $0.text.caseInsensitiveCompare(idOrText) == .orderedSame } }
    }
    public var runLog: [RoutineRunLog] { withFile { $0.runs } }
    public func routine(named name: String) -> Routine? {
        withFile { f in f.routines.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    // MARK: Changing

    /// Saves a routine, over one with the same name unless that one is locked and this is not the
    /// owner's. False when it was not saved.
    @discardableResult
    public func save(_ routine: Routine) -> Bool {
        withFile(true) { f in
            var r = routine
            if let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(routine.name) == .orderedSame }) {
                let old = f.routines[i]
                guard !old.isLocked || routine.savedBy == Self.owner else { return false }
                r.created = old.created
                r.locked = old.locked
                // A routine saved again after it stopped is the path that worked: its record starts over.
                if old.steps == r.steps { r.runs = old.runs; r.ok = old.ok; r.failuresInARow = old.failuresInARow; r.lastStop = old.lastStop }
                f.routines[i] = r
                Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: routine.savedBy,
                                                routineName: r.name, routineApp: r.app, routine: old))
            } else {
                f.routines.append(r)
                Self.trim(&f.routines, to: Self.maxRoutines, keeping: \.isLocked)
                Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.added, id: Self.newID(), at: Date(), by: routine.savedBy,
                                                routineName: r.name, routineApp: r.app))
            }
            return true
        }
    }

    /// Forgets a routine; an agent cannot forget a locked one. The log keeps it for undo.
    @discardableResult
    public func forget(_ name: String, by: String = RoutineStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !f.routines[i].isLocked || by == Self.owner else { return false }
            let old = f.routines.remove(at: i)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.forgot, id: Self.newID(), at: Date(), by: by,
                                            routineName: old.name, routineApp: old.app, routine: old))
            return true
        }
    }

    /// Renames a routine; an agent cannot rename a locked one, and the owner's rename locks it.
    @discardableResult
    public func rename(_ name: String, to new: String, by: String = RoutineStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !f.routines[i].isLocked || by == Self.owner,
                  // Not onto another routine's name, which would hide that one.
                  !f.routines.indices.contains(where: { $0 != i && f.routines[$0].name.caseInsensitiveCompare(new) == .orderedSame }) else { return false }
            let old = f.routines[i]
            f.routines[i].name = new
            f.routines[i].updated = Date()
            if by == Self.owner { f.routines[i].locked = true }
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: by,
                                            routineName: new, routineApp: old.app, routine: old, previous: old.name))
            return true
        }
    }

    /// Changes a routine in place. With `by`, it is an edit: logged, and refused for an agent when
    /// the routine is locked. Without, it is the run's own bookkeeping (counts, the last stop).
    @discardableResult
    public func update(_ name: String, by: String? = nil, _ change: (inout Routine) -> Void) -> Bool {
        withFile(true) { f in
            guard let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            guard let by else { change(&f.routines[i]); return true }
            guard !f.routines[i].isLocked || by == Self.owner else { return false }
            let old = f.routines[i]
            change(&f.routines[i])
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: by,
                                            routineName: f.routines[i].name, routineApp: f.routines[i].app, routine: old))
            return true
        }
    }

    /// Locks or unlocks a note (by id) or a routine (by name). Only the Memory page calls it.
    public func setLocked(_ idOrName: String, _ locked: Bool) {
        withFile(true) { f in
            if let i = f.notes.firstIndex(where: { $0.id == idOrName }) { f.notes[i].locked = locked ? true : nil }
            else if let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }) { f.routines[i].locked = locked ? true : nil }
        }
    }

    /// Keeps a note. The same text again answers the note already kept. `heard` is the conversation
    /// it came up in; the owner's own notes come locked.
    @discardableResult
    public func remember(_ text: String, by: String, app: String? = nil, heard: NoteOrigin? = nil, locked: Bool = false) -> MemoryNote? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return withFile(true) { f in
            if let same = f.notes.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return same }
            let note = MemoryNote(id: String(UUID().uuidString.prefix(8)).lowercased(), text: String(clean.prefix(Self.maxNoteLength)), by: by, at: Date(),
                                  locked: locked ? true : nil, app: app, heard: heard)
            f.notes.append(note)
            Self.trim(&f.notes, to: Self.maxNotes, keeping: \.isLocked)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.added, id: Self.newID(), at: Date(), by: by, note: note))
            return note
        }
    }

    /// Forgets a note; an agent cannot forget a locked one. The log keeps it for undo.
    @discardableResult
    public func forgetNote(_ idOrText: String, by: String = RoutineStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.notes.firstIndex(where: { $0.id == idOrText || $0.text.caseInsensitiveCompare(idOrText) == .orderedSame }),
                  !f.notes[i].isLocked || by == Self.owner else { return false }
            let old = f.notes.remove(at: i)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.forgot, id: Self.newID(), at: Date(), by: by, note: old))
            return true
        }
    }

    /// The owner's change to a note: its text and app. It locks, and no longer links to where it was
    /// heard, since the words are now the owner's.
    public func editNote(_ id: String, text: String, app: String?? = .none) {
        withFile(true) { f in
            guard let i = f.notes.firstIndex(where: { $0.id == id }) else { return }
            let old = f.notes[i]
            f.notes[i].text = String(text.prefix(Self.maxNoteLength))
            if case .some(let app) = app { f.notes[i].app = app }
            f.notes[i].locked = true
            f.notes[i].heard = nil
            f.notes[i].edited = Date()
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: Self.owner, note: f.notes[i],
                                            previous: old.text == f.notes[i].text ? nil : old.text, before: old))
        }
    }

    /// Puts back what a change took away or changed, and marks it undone. Undoing an agent's change
    /// locks the item, so the agent does not make it again. False when there is nothing to put back
    /// (already undone, or the item is gone or its place taken).
    @discardableResult
    public func undo(_ changeID: String) -> Bool {
        withFile(true) { f in
            guard var changes = f.changes, let c = changes.firstIndex(where: { $0.id == changeID }), changes[c].undone != true else { return false }
            let change = changes[c]
            let locks: Bool? = change.by == Self.owner ? nil : true
            func routineIndex(_ name: String?) -> Int? { name.flatMap { n in f.routines.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } } }
            switch (change.action, change.note, change.routine) {
            case (MemoryChangeRecord.forgot, var note?, _):
                guard !f.notes.contains(where: { $0.id == note.id || $0.text.caseInsensitiveCompare(note.text) == .orderedSame }) else { return false }
                if let locks { note.locked = locks }
                f.notes.append(note)
            case (MemoryChangeRecord.forgot, nil, var routine?):
                guard routineIndex(routine.name) == nil else { return false }
                if let locks { routine.locked = locks }
                f.routines.append(routine)
            case (MemoryChangeRecord.added, let note?, _):
                guard let i = f.notes.firstIndex(where: { $0.id == note.id }) else { return false }
                f.notes.remove(at: i)
            case (MemoryChangeRecord.added, nil, _):
                guard let i = routineIndex(change.routineName) else { return false }
                f.routines.remove(at: i)
            case (MemoryChangeRecord.edited, let note?, _):
                guard let i = f.notes.firstIndex(where: { $0.id == note.id }) else { return false }
                if var old = change.before {
                    if let locks { old.locked = locks }
                    f.notes[i] = old
                } else {
                    // An entry with only the text before (an agent's edit).
                    guard let previous = change.previous else { return false }
                    f.notes[i].text = previous
                    if let locks { f.notes[i].locked = locks }
                }
            case (MemoryChangeRecord.edited, nil, var routine?):
                guard let i = routineIndex(change.routineName) else { return false }
                routine.locked = locks ?? f.routines[i].locked
                f.routines[i] = routine
            default:
                return false
            }
            changes[c].undone = true
            f.changes = changes
            return true
        }
    }

    private static func log(_ f: inout MemoryFile, _ change: MemoryChangeRecord) {
        var changes = f.changes ?? []
        changes.insert(change, at: 0)
        if changes.count > maxChanges { changes.removeLast(changes.count - maxChanges) }
        f.changes = changes
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }

    /// Drops the oldest unlocked items over the cap; locked ones are never dropped.
    private static func trim<T>(_ items: inout [T], to cap: Int, keeping kept: (T) -> Bool) {
        while items.count > cap, let i = items.firstIndex(where: { !kept($0) }) { items.remove(at: i) }
    }

    func logRun(_ log: RoutineRunLog) {
        withFile(true) { f in
            f.runs.append(log)
            if f.runs.count > Self.maxRuns { f.runs.removeFirst(f.runs.count - Self.maxRuns) }
        }
    }

    public func clearAll() { withFile(true) { $0 = MemoryFile() } }

    // MARK: Export and import

    /// What the app adds to a backup and takes back from one (its saved chat sessions). Off unless set.
    public var extrasProvider: (@Sendable () -> [String: JSON])?
    public var extrasRestorer: (@Sendable ([String: JSON]) -> Void)?

    /// The backup file: routines, notes and the run log; with `includeExtras`, what the app adds.
    public func exportData(includeExtras: Bool = false) throws -> Data {
        var snapshot = withFile { $0 }
        snapshot.schema = Self.schema
        snapshot.exported = Date()
        snapshot.extras = includeExtras ? extrasProvider?() : nil
        snapshot.changes = nil
        return try Self.encoder.encode(snapshot)
    }

    /// Merges a backup in: a routine with the same name is replaced when the incoming one is newer;
    /// notes are added unless the same text is there. Returns what changed, in words.
    @discardableResult
    public func importData(_ data: Data, by: String) throws -> String {
        let incoming: MemoryFile
        do { incoming = try Self.decoder.decode(MemoryFile.self, from: data) }
        catch { throw ImportError("not a Poki agent backup: \(error)") }
        guard incoming.schema.hasPrefix("poki.agent-backup/") else { throw ImportError("not a Poki agent backup (schema \(incoming.schema))") }
        guard incoming.schema == Self.schema else { throw ImportError("a backup of a newer Poki (\(incoming.schema)); update Poki to import it") }
        var added = 0, replaced = 0, kept = 0, notes = 0
        // An agent's import brings what it says, but not the owner's say: nothing comes locked, and
        // nothing claims to be the owner's, an import's or Dream's. A note's "edited" and "heard"
        // are the owner's change and one of our own conversations, so they are not carried either.
        let agent = !Self.isReserved(by)
        withFile(true) { f in
            for var r in incoming.routines where !r.name.isEmpty {
                if agent { r.locked = nil; if Self.isReserved(r.savedBy) { r.savedBy = by } }
                if let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(r.name) == .orderedSame }) {
                    // The owner locked ours: a newer copy from elsewhere does not replace it.
                    if r.updated > f.routines[i].updated, !f.routines[i].isLocked { f.routines[i] = r; replaced += 1 } else { kept += 1 }
                } else { f.routines.append(r); added += 1 }
            }
            for var n in incoming.notes where !f.notes.contains(where: { $0.text.caseInsensitiveCompare(n.text) == .orderedSame }) {
                if agent { n.locked = nil; n.edited = nil; n.heard = nil; if Self.isReserved(n.by) { n.by = by } }
                // Another note's id would make forgetting or undoing by id reach the wrong one.
                if f.notes.contains(where: { $0.id == n.id }) { n.id = String(UUID().uuidString.prefix(8)).lowercased() }
                f.notes.append(n); notes += 1
            }
            Self.trim(&f.notes, to: Self.maxNotes, keeping: \.isLocked)
        }
        if let extras = incoming.extras, !extras.isEmpty { extrasRestorer?(extras) }
        return "imported: \(added) routines added, \(replaced) replaced by newer ones, \(kept) kept (ours were newer), \(notes) notes added\(incoming.extras?.isEmpty == false ? ", and the app's saved sessions" : "")"
    }

    public struct ImportError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// The maintainers' bundle: every routine with its record, the latest runs and the notes' count.
    /// No screenshots and no typed text beyond what the routines keep as parameters.
    public func debugBundle(extra: [String: JSON] = [:]) -> Data {
        let snapshot = withFile { $0 }
        var bundle: [String: JSON] = extra
        bundle["schema"] = "poki.agent-debug/1"
        bundle["made"] = .string(ISO8601DateFormatter().string(from: Date()))
        bundle["routines"] = .array(snapshot.routines.map { r in
            ["name": .string(r.name), "app": r.app.map(JSON.string) ?? .null, "steps": .array(r.steps.map { s in
                ["action": s.action, "target": s.target.map { .string($0.describe) } ?? .null, "app": s.app.map(JSON.string) ?? .null] }),
             "runs": .number(Double(r.runs)), "ok": .number(Double(r.ok)), "stale": .bool(r.stale),
             "last_stop": r.lastStop.map { ["step": .number(Double($0.step)), "why": .string($0.why), "at": .string(ISO8601DateFormatter().string(from: $0.at))] } ?? .null,
             "last_ms": r.lastMs.map { .number(Double($0)) } ?? .null]
        })
        bundle["runs"] = .array(snapshot.runs.map { l in
            ["routine": .string(l.routine), "at": .string(ISO8601DateFormatter().string(from: l.at)), "ms": .number(Double(l.ms)), "outcome": .string(l.outcome), "steps": .array(l.steps.map(JSON.string))]
        })
        bundle["notes"] = .number(Double(snapshot.notes.count))
        return JSON.object(bundle).data()
    }

    // MARK: For the agent

    /// The brief goes into every task's prompt, so it stays this short (in characters); the routines
    /// tool lists the rest.
    static let maxBriefLength = 4000

    /// What a model should know at the start of a task: the routines that fit it best (stale ones
    /// left out) in up to half of `maxBriefLength`, and the newest notes in the rest. Empty when
    /// nothing is saved.
    public func brief(for task: String, app: String? = nil, limit: Int = 12) -> String {
        let (routines, notes) = withFile { ($0.routines, $0.notes) }
        let words = Set(Self.words(task))
        let fit = routines.filter { !$0.stale }.map { r -> (Routine, Int) in
            let score = Set(Self.words(r.name + " " + r.description)).intersection(words).count * 3 + (app != nil && r.app == app ? 2 : 0)
            return (r, score)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updated > $1.0.updated }.prefix(limit).map(\.0)
        var room = Self.maxBriefLength
        func section(_ header: String, _ items: [String], within limit: Int) -> [String] {
            var left = min(room, limit) - header.count - 1
            var taken: [String] = []
            for item in items where item.count + 1 <= left {
                taken.append(item)
                left -= item.count + 1
            }
            guard !taken.isEmpty else { return [] }
            room -= ([header] + taken).reduce(0) { $0 + $1.count + 1 }
            return [header] + taken
        }
        let routineLines = section("Saved routines: do {run: \"name\"} replays one in a single call and stops cleanly at a screen that differs, so try a routine that fits before stepping by hand (with: {text_1: \"…\"} changes what it types). The routines tool lists, shows, edits and saves them:",
                                   fit.map { "- \($0.summary)" }, within: Self.maxBriefLength / 2)
        let noteLines = section("Notes saved about the owner and their phone, newest first (use them; the routines tool's remember adds one, forget_note drops one):",
                                notes.suffix(20).reversed().map { "- \($0.text)" }, within: room)
        return (noteLines + routineLines).joined(separator: "\n")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }
}

// MARK: Recording and replay in `do`

/// A step as recorded while the task ran, with what the screen held before it (for the end check).
struct RecordedStep {
    var step: RoutineStep
    var typed: String?
    var keysBefore: Set<String>
}

extension Computer {
    /// The `do` action as a routine step: element numbers become targets. nil for what is not kept
    /// (a handoff, a run, which records its own steps).
    func recordable(_ action: JSON) -> RecordedStep? {
        guard case .object(var o) = action, o["handoff"] == nil, o["run"] == nil, o["path"] == nil else { return nil }
        var target: RoutineTarget?
        var typed: String?
        var secret: Bool?
        func element(_ spec: JSON?) -> Element? {
            guard let spec else { return nil }
            if let n = spec.int, spec.array == nil, case .number = spec { return refs[n] }
            if case .string = spec, let n = spec.int { return refs[n] }
            if let n = spec["ref"]?.int { return refs[n] }
            return nil
        }
        func point(_ e: Element) -> JSON { let c = e.frame.centre; return [.number(c.x.rounded()), .number(c.y.rounded())] }
        for key in ["tap", "long_press"] {
            if let spec = o[key], let e = element(spec) {
                target = RoutineTarget(e)
                if case .object(var inner) = spec { inner["ref"] = "@"; o[key] = .object(inner) } else { o[key] = "@" }
            }
        }
        if let text = o["type"]?.text {
            if let e = element(o["ref"]) { target = RoutineTarget(e); o["ref"] = "@" }
            let hidden = describe(action).hasSuffix("(hidden)")
            if hidden { secret = true; o["type"] = "" } else { typed = text }
        }
        if case .object(var s) = o["scroll_to"], let e = element(s["ref"]) {
            s["ref"] = nil
            s["text"] = .string(e.label ?? e.text)
            o["scroll_to"] = .object(s)
        }
        if case .object(var s) = o["scroll_to"], s["in"] != nil { s["in"] = nil; o["scroll_to"] = .object(s) }
        if case .object(var s) = o["swipe"], s["in"] != nil { s["in"] = nil; o["swipe"] = .object(s) }
        if case .object(var d) = o["drag"] {
            for k in ["from", "to"] { if let e = element(d[k]) { d[k] = point(e) } }
            o["drag"] = .object(d)
        }
        if case .object(var p) = o["pinch"], let e = element(.object(p)) { p["ref"] = nil; let c = e.frame.centre; p["x"] = .number(c.x.rounded()); p["y"] = .number(c.y.rounded()); o["pinch"] = .object(p) }
        let keys = Set(listed.map(\.element.key))
        return RecordedStep(step: RoutineStep(action: .object(o), target: target, app: lastForeground?.bundleID, secret: secret), typed: typed, keysBefore: keys)
    }

    /// The task's recorded steps as a routine (nil and why, when they cannot make one).
    func routine(named name: String, description: String, read: [String], expect: [String]?, by: String) -> (Routine?, String) {
        let recorded = trace
        guard !recorded.isEmpty else { return (nil, "nothing was recorded in this task yet: a routine is made of the do actions sent since the task began (the first look or do after a finish)") }
        var params: [String: String] = [:]
        var steps: [RoutineStep] = []
        for r in recorded {
            var s = r.step
            if let text = r.typed, case .object(var o) = s.action {
                let id = params.first(where: { $0.value == text })?.key ?? "text_\(params.count + 1)"
                params[id] = text
                o["type"] = .string("{{\(id)}}")
                s.action = .object(o)
            }
            steps.append(s)
        }
        steps = Self.withoutRefocusTaps(steps)
        // The end check: what the last screen shows that was not there before the last step (its
        // headings and texts, three at most), else what the step went to.
        var checks = expect ?? []
        if expect == nil, let last = recorded.last {
            let fresh = listed.map(\.element).filter { e in
                !e.fromPicture && !e.text.isEmpty && !Self.containers.contains(e.type) && !last.keysBefore.contains(e.key) && e.text.count <= 60
                    && listed.filter({ $0.element.key == e.key }).count == 1
            }
            let preferred = fresh.filter { ["NavigationBar", "StaticText", "Heading"].contains($0.type) } + fresh.filter { !["NavigationBar", "StaticText", "Heading"].contains($0.type) }
            checks = Array(preferred.prefix(3).map { $0.label ?? $0.text })
        }
        // The app of the first step that touched something (a launch step was recorded where it began).
        let app = recorded.first(where: { $0.step.target != nil && $0.step.app != nil })?.step.app ?? recorded.first(where: { $0.step.app != nil })?.step.app
        let now = Date()
        let routine = Routine(name: name, description: description, app: app, steps: steps, params: params, expect: checks.filter { !$0.isEmpty }, read: read,
                              runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: by, created: now, updated: now)
        var notes: [String] = []
        let points = steps.filter { s in s.target == nil && (s.action["tap"]?.array != nil || s.action["long_press"]?.array != nil) }.count
        if points > 0 { notes.append("\(points) step\(points == 1 ? "" : "s") tap a point, not an element: they replay at the same point whatever is there") }
        if steps.contains(where: { $0.secret == true }) { notes.append("a password typed in it was not kept: a run stops there for you to type it") }
        if routine.expect.isEmpty { notes.append("no end check could be chosen from the last screen; give expect: [\"text\"] to add one") }
        return (routine, notes.joined(separator: "; "))
    }

    /// The steps without a tap on a text field that comes right after typing into it and right before
    /// Return: the field still has the focus there, so the tap does nothing a run needs, and a run would
    /// repeat it every time (ESP-465: the model tapped the message field before Send in 3 of 6 sends).
    static func withoutRefocusTaps(_ steps: [RoutineStep]) -> [RoutineStep] {
        steps.indices.compactMap { i in
            let step = steps[i]
            guard step.action["tap"] != nil, let target = step.target, fieldTypes.contains(target.type),
                  i > 0, steps[i - 1].action["type"] != nil, i + 1 < steps.count, isReturn(steps[i + 1].action) else { return step }
            // The field typed into: the type's own target, else the tap that came before the type.
            let typedInto = steps[i - 1].target ?? (i > 1 && steps[i - 2].action["tap"] != nil ? steps[i - 2].target : nil)
            if let typedInto, typedInto.type != target.type || typedInto.label != target.label || typedInto.identifier != target.identifier { return step }
            return nil
        }
    }

    /// `{run: "name"}` or `{run: {name, with: {text_1: "…"}}}`: the routine's steps in order, each when
    /// its target is on screen. Throws (not sent) at the first step that cannot be done as recorded.
    func runRoutine(_ spec: JSON, until: Double) async throws -> String {
        let name = spec.string ?? spec["name"]?.string ?? ""
        guard let store = memory, let routine = store.routine(named: name) else {
            let known = memory?.routines.prefix(12).map { "\"\($0.name)\"" }.joined(separator: ", ") ?? ""
            throw ActionFailure(message: "no routine named \"\(name)\"\(known.isEmpty ? " (none are saved)" : "; saved: \(known)")", delivery: .notSent)
        }
        var params = routine.params
        if case .object(let given) = spec["with"] { for (k, v) in given { if let t = v.text { params[k] = t } } }
        return try await replay(routine, params: params, store: store, until: until)
    }

    /// `{path: {goal, steps: [...]}}`: steps the agent wrote ahead for screens it has not read yet, each
    /// target named by its text. They run as a routine does, without being saved.
    func runPath(_ spec: JSON, until: Double) async throws -> String {
        let routine = try Self.pathRoutine(spec)
        return try await replay(routine, params: [:], store: nil, until: until)
    }

    /// A path's steps as a routine with no name. A target is the text the element shows, or
    /// {label, type?}; a point stays a point. Numbers are refused: they are the latest read's, and a
    /// path is for the screens after it.
    static func pathRoutine(_ spec: JSON) throws -> Routine {
        func refuse(_ why: String) -> ActionFailure { ActionFailure(message: "path: \(why); nothing was sent", delivery: .notSent) }
        guard let given = spec["steps"]?.array ?? spec.array, !given.isEmpty else { throw refuse("give steps: [{tap: \"text\"}, …]") }
        guard given.count <= 20 else { throw refuse("at most 20 steps") }
        func target(_ spec: JSON) throws -> RoutineTarget? {
            if spec.array != nil { return nil }
            if case .string(let label) = spec, Double(label) == nil, !label.isEmpty { return RoutineTarget(type: RoutineTarget.anyType, label: label) }
            if case .object = spec, let label = spec["label"]?.string ?? spec["text"]?.string, !label.isEmpty {
                return RoutineTarget(type: spec["type"]?.string ?? RoutineTarget.anyType, label: label)
            }
            if case .object = spec, spec["x"] != nil, spec["y"] != nil { return nil }
            throw refuse("a target in a path is the element's text, {label, type?} or a point [x, y], not a number from an earlier read")
        }
        var steps: [RoutineStep] = []
        for (i, step) in given.enumerated() {
            guard case .object(var o) = step, let kind = ActionKind(step), kind != .run, kind != .path, kind != .handoff else { throw refuse("step \(i + 1) is not an action a path can hold") }
            let expect = (o["expect"]?.array?.compactMap(\.string) ?? o["expect"]?.string.map { [$0] })?.filter { !$0.isEmpty }
            o["expect"] = nil
            let optional = o["optional"]?.bool == true
            o["optional"] = nil
            var found: RoutineTarget?
            switch kind {
            case .tap, .longPress:
                if let t = try target(o[kind.rawValue] ?? .null) {
                    found = t
                    if case .object(var inner) = o[kind.rawValue] { inner["label"] = nil; inner["text"] = nil; inner["type"] = nil; inner["ref"] = "@"; o[kind.rawValue] = .object(inner) } else { o[kind.rawValue] = "@" }
                }
            case .type:
                if o["ref"] != nil { throw refuse("step \(i + 1): name the field with into: \"its text\", not a number") }
                if let into = o["into"] {
                    guard let t = try target(into) else { throw refuse("step \(i + 1): into is the field's text") }
                    found = t
                    o["into"] = nil
                    o["ref"] = "@"
                }
            case .scrollTo:
                if o["scroll_to"]?["ref"] != nil || o["scroll_to"]?["in"] != nil { throw refuse("step \(i + 1): scroll_to takes the text to reach") }
            case .drag, .pinch:
                if Computer.refs(in: step).isEmpty == false { throw refuse("step \(i + 1) uses a number from an earlier read") }
            default: break
            }
            steps.append(RoutineStep(action: .object(o), target: found, app: nil, secret: nil, expect: expect?.isEmpty == false ? Array(expect!.prefix(4)) : nil, optional: optional ? true : nil))
            if optional, found == nil { throw refuse("step \(i + 1): optional needs a target named by its text") }
        }
        let now = Date()
        let dismiss = (spec["dismiss"]?.array?.compactMap(\.string) ?? []).filter { !$0.isEmpty }.prefix(6)
        return Routine(name: "", description: spec["goal"]?.string ?? "", app: nil, steps: steps, params: [:], expect: spec["expect"]?.array?.compactMap(\.string) ?? [],
                       read: Array((spec["read"]?.array?.compactMap(\.string) ?? []).prefix(6)),
                       runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, dismiss: dismiss.isEmpty ? nil : Array(dismiss), savedBy: "", created: now, updated: now)
    }

    /// The steps of a saved routine (`store` given) or of a path, in order. Each step waits for its
    /// target and acts only on a single match. A step whose target is missing stops the run, with
    /// nothing sent for it; a path may first close what it said may be closed (its `dismiss`).
    func replay(_ routine: Routine, params: [String: String], store: RoutineStore?, until: Double) async throws -> String {
        let saved = store != nil
        let title = saved ? "run \"\(routine.name)\"" : "path"
        let started = now()
        var log: [String] = []
        var done = 0
        /// What was closed on the way because the path said it may be.
        var closed: [String] = []
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        /// Optional steps whose target was not there.
        var skipped = 0
        func fixedNote() -> String {
            (closed.isEmpty ? "" : "; closed on the way: " + closed.joined(separator: "; "))
                + (skipped > 0 ? "; \(skipped) optional \(skipped == 1 ? "step was" : "steps were") left out" : "")
        }
        func finish(_ outcome: String, stop: RoutineStop?) {
            let ms = Int(((now() - started) * 1000).rounded())
            guard let store else { return }
            store.update(routine.name) { r in
                r.runs += 1
                r.lastMs = ms
                if let stop { r.failuresInARow += 1; r.lastStop = stop } else { r.ok += 1; r.failuresInARow = 0 }
            }
            store.logRun(RoutineRunLog(routine: routine.name, at: Date(), ms: ms, outcome: outcome, steps: log))
        }
        func stop(_ index: Int, _ why: String, _ delivery: Delivery = .notSent) -> ActionFailure {
            finish("stopped at step \(index + 1): \(why)", stop: RoutineStop(step: index + 1, why: why, at: Date()))
            let sent = done == 0 ? "no step was sent" : "steps 1 to \(done) were sent"
            let after = saved ? "; when the task is done, routines {action: \"save\", name: \"\(routine.name)\"} saves the path that worked over this one" : ""
            return ActionFailure(message: "\(title) stopped at step \(index + 1) of \(routine.steps.count): \(why); \(sent)\(fixedNote()). Go on by hand from the screen below\(after)", delivery: delivery)
        }

        // The app the next step lands in: a launch is not read until a later step reads the screen.
        var front = lastForeground
        // Another app in front: the routine's app is launched first.
        if let app = routine.app, lastForeground?.bundleID != app, routine.steps.first?.action["launch"] == nil, !config.isPoki(Foreground(bundleID: app, name: nil)) {
            do {
                _ = try await perform(["launch": .string(app)], until: until)
                log.append("launched \(app)")
                front = Foreground(bundleID: app, name: nil)
            } catch { throw stop(0, "\(app) could not be launched (\(error))") }
        }

        /// No input goes into Poki, where the approval card and the approval settings are: a step that
        /// would send it there stops the run, as a do sending it there is refused.
        let inPoki = "Poki is in front, and \(CoreConfig.ownAppRefusal). Leave Poki first ({button: \"home\"} or {launch: \"bundle id\"})"

        var previous: String?
        /// What may be closed when it is in the way of a step: what the path allows.
        let allowed = (routine.dismiss ?? []).map { RoutineTarget(type: RoutineTarget.anyType, label: $0) }
        steps: for (index, step) in routine.steps.enumerated() {
            if step.secret == true { throw stop(index, "it types into a password field, which a routine never keeps: type it yourself") }
            var action = step.action
            // The text with its parameters filled in.
            if let text = action["type"]?.string, case .object(var o) = action {
                o["type"] = .string(text.replacingParams(params))
                action = .object(o)
            }
            // Each step is held by the rules a do is held by, on the screen it lands on: a step the owner
            // must approve is theirs, and the run hands it back rather than send it.
            var scan: SensitiveScan?
            /// The screen this step lands on was read for it, so `front` is the app really in front.
            var read = false
            if let target = step.target {
                // Wait for the target, alone, on screen; after a step that changed nothing yet, give the
                // screen a moment to move on so the same label on the old screen is not taken for it.
                var stepEnds = min(until, now() + config.actionCap)
                var found: Element?
                var why = "\(target.describe) is not on screen"
                var reads = 0
                var closedHere = 0
                /// The still screen already looked at for something to close, and found without.
                var lookedAt: String?
                let readStart = now()
                attempts: while true {
                    // The match and its frame in the read before: a target is tapped only once it holds still
                    // across two reads (a page sliding in moves its rows, and a tap then is lost), or after 1.5 s.
                    var candidate: String?
                    let attemptStart = now()
                    var stillSince = attemptStart
                    var lastSignature: String?
                    var elements: [Element] = []
                    var early = false
                    while now() < stepEnds - 0.2 {
                        // A read that fails (an app still launching, a runner busy with the last step) is
                        // tried again while the step has time: one missed read is not a screen that differs.
                        guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, stepEnds - now() - 0.1)), format: config.treeFormat) else {
                            why = "the screen could not be read"
                            await sleep(seconds: 0.25)
                            continue
                        }
                        if why == "the screen could not be read" { why = "\(target.describe) is not on screen" }
                        reads += 1
                        elements = listable(tree.elements, screen)
                        let signature = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                        let moved = previous == nil || signature != previous || now() - attemptStart > 0.8
                        if signature != lastSignature { stillSince = now(); lastSignature = signature }
                        lastAll = tree.elements
                        lastForeground = tree.foreground
                        var matches = elements.filter(target.matches)
                        // An alert takes every touch: a target behind one is not there to tap yet (the
                        // tap would go nowhere, and the step after it would be the one to stop).
                        if !matches.isEmpty, let alert = tree.elements.last(where: { $0.type == "Alert" && !$0.frame.isEmpty }), !matches.contains(where: { alert.contains($0) }) {
                            matches = []
                            why = "\(target.describe) is behind an alert\(alert.text.isEmpty ? "" : " (\"\(alert.text.prefix(60))\")")"
                        }
                        if moved, !matches.isEmpty {
                            let layout = Layout(all: tree.elements, screen: screen)
                            let reachable = matches.filter { layout.touchPoint($0) != nil }
                            let (pick, reason) = Self.pick(among: reachable, for: target)
                            if let reason { why = reason }
                            if let pick {
                                let here = "\(pick.key)@\(pick.frame.described)"
                                if here == candidate || now() - attemptStart > 1.5 { found = pick; break }
                                candidate = here
                                why = "\(target.describe) was still moving"
                                continue
                            }
                        }
                        candidate = nil
                        // A step for something only sometimes there does not wait for it on a still screen.
                        if step.optional == true, moved, now() - stillSince >= Self.askAfterStill { break }
                        // With something the path allows closing, a screen that has held still without
                        // the target is looked at now, not after the step's whole time.
                        if !allowed.isEmpty, moved, closedHere < Self.maxClosesPerStep, closed.count < Self.maxClosesPerRun, signature != lookedAt, now() - stillSince >= Self.askAfterStill { early = true; break }
                        await sleep(seconds: 0.12)
                    }
                    if found != nil || step.optional == true { break attempts }
                    guard closedHere < Self.maxClosesPerStep, closed.count < Self.maxClosesPerRun, until - now() > 1.5, !elements.isEmpty else { break attempts }
                    let layout = Layout(all: lastAll, screen: screen)
                    // What the path said may be closed, alone on screen: closed, and the step is tried again.
                    var closer: Element?
                    for name in allowed {
                        let there = elements.filter { name.matches($0) && layout.touchPoint($0) != nil && Self.tappable.contains($0.type) }
                        if there.count == 1 { closer = there[0]; break }
                    }
                    // Nothing to close. Looked at early: the step still has its time, and a page that was
                    // only slow gets it.
                    guard let element = closer else {
                        if !early { break attempts }
                        lookedAt = lastSignature
                        continue attempts
                    }
                    let signatureNow = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                    if config.isPoki(lastForeground) { throw stop(index, "\(why); \(inPoki)") }
                    // Closing it is a tap like any other: what the owner must approve stays theirs.
                    refs[Self.runRef] = element
                    let tap: JSON = ["tap": .number(Double(Self.runRef))]
                    var closeScan = SensitiveScan(front: lastForeground, secureOnScreen: lastAll.contains(where: \.isSecure))
                    if let reason = sensitive(tap, &closeScan) {
                        refs[Self.runRef] = nil
                        throw stop(index, "\(why); \(element.type) \"\(element.text.prefix(40))\" is in the way and closing it needs the owner's approval (\(reason))")
                    }
                    do { _ = try await perform(tap, until: min(until, now() + config.actionCap)) }
                    catch let failure as ActionFailure { refs[Self.runRef] = nil; throw stop(index, "\(why); closing \(element.type) \"\(element.text.prefix(40))\" failed (\(failure.message))", failure.delivery) }
                    catch { refs[Self.runRef] = nil; throw stop(index, "\(why); closing what was in the way failed (\(error))", .unknown) }
                    refs[Self.runRef] = nil
                    closedHere += 1
                    closed.append("step \(index + 1): closed \(element.type) \"\(element.text.prefix(40))\" (allowed by the path)")
                    log.append("before \(index + 1): closed \(element.type) \"\(element.text.prefix(40))\"")
                    previous = signatureNow
                    // Closing it changed the screen: the step gets its time again from here.
                    stepEnds = min(until, now() + config.actionCap)
                }
                if found == nil, step.optional == true {
                    skipped += 1
                    log.append("\(index + 1) left out: \(target.describe) was not there")
                    done = index + 1
                    continue steps
                }
                guard let element = found else { throw stop(index, why + " (\(reads) reads in \(Int(((now() - readStart) * 1000).rounded())) ms)") }
                refs[Self.runRef] = element
                action = Self.replacingTarget(action, with: Self.runRef)
                front = lastForeground
                read = true
                scan = SensitiveScan(front: lastForeground, secureOnScreen: lastAll.contains(where: \.isSecure))
            } else if config.sensitive.enabled, ActionKind(action)?.movesScreen == true {
                // A step recorded without an element (a point, a key, a swipe) is judged on the screen read
                // now; unread, it is a screen not read yet.
                scan = SensitiveScan(front: front, read: false, secureOnScreen: false)
                if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, until - now() - 0.1)), format: config.treeFormat) {
                    lastAll = tree.elements
                    lastForeground = tree.foreground
                    front = tree.foreground ?? front
                    read = true
                    let elements = listable(tree.elements, screen)
                    scan = SensitiveScan(front: front, secureOnScreen: elements.contains(where: \.isSecure), elements: elements)
                }
            }
            if ActionKind(action)?.movesScreen == true {
                // Not read for this step: a launch may not have opened what it named, so the runner says.
                if !read, let info = try? await runner.raw("GET", "/wda/activeAppInfo", timeout: 1.5, countsAsMiss: false), let bundle = info["bundleId"]?.string, !bundle.isEmpty {
                    front = Foreground(bundleID: bundle, name: info["name"]?.string)
                }
                if config.isPoki(front) {
                    refs[Self.runRef] = nil
                    throw stop(index, inPoki)
                }
            }
            if var scan, let reason = sensitive(action, &scan) {
                refs[Self.runRef] = nil
                throw stop(index, "it needs the owner's approval (\(reason)); send it as an ordinary do so the owner is asked")
            }
            let began = now()
            let kind: String, text: String
            do { (kind, text) = try await perform(action, until: min(until, now() + actionCap(action))) }
            catch let failure as ActionFailure {
                refs[Self.runRef] = nil
                throw stop(index, failure.message, failure.delivery)
            } catch {
                refs[Self.runRef] = nil
                throw stop(index, "\(error)", .unknown)
            }
            // The step is in this task's record too, so a task that goes on by hand saves whole. A
            // path's target is kept as the element it found, the way a step sent by hand is.
            var recorded = step
            if let element = refs[Self.runRef], step.target?.type == RoutineTarget.anyType { recorded.target = RoutineTarget(element) }
            refs[Self.runRef] = nil
            if let spec = action["launch"] { front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil) }
            done = index + 1
            log.append("\(index + 1) \(text.prefix(80)) (\(Int(((now() - began) * 1000).rounded())) ms)")
            recorded.app = lastForeground?.bundleID ?? step.app
            recorded.optional = nil
            // A path's typed text is what a saved routine's parameter is made of.
            trace.append(RecordedStep(step: recorded, typed: kind == "type" ? action["type"]?.string : nil, keysBefore: []))
            previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            // Typing and keys change nothing a next target needs to move away from.
            if kind == "type" || kind == "key" { previous = nil }
            // What the step said must be there afterwards, read from the tree: no model is asked.
            if let wanted = step.expect, !wanted.isEmpty {
                let ends = min(until, now() + 3)
                var missing = wanted
                while true {
                    if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, ends - now())), format: config.treeFormat) {
                        lastAll = tree.elements
                        lastForeground = tree.foreground
                        let texts = listable(tree.elements, screen)
                        missing = wanted.filter { want in !texts.contains { $0.text.localizedCaseInsensitiveContains(want) } }
                    }
                    if missing.isEmpty || now() >= ends - 0.2 { break }
                    await sleep(seconds: 0.12)
                }
                if !missing.isEmpty { throw stop(index, "the step was sent, but \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) did not appear after it", .sent) }
                log.append("after \(index + 1): \(wanted.map { "\"\($0)\"" }.joined(separator: ", ")) on screen")
                previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            }
        }

        if routine.steps.last?.expect?.isEmpty == false { runEndedOnARead = true }
        // The end check and the readout.
        var outcome = "\(routine.steps.count) steps in \(Self.seconds(now() - started)) s"
        if !routine.expect.isEmpty || !routine.read.isEmpty {
            let checkEnds = min(until, now() + 3)
            var missing = routine.expect
            var values: [String] = []
            while now() < checkEnds {
                guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, checkEnds - now())), format: config.treeFormat) else { break }
                let texts = listable(tree.elements, screen)
                missing = routine.expect.filter { want in !texts.contains { $0.text.localizedCaseInsensitiveContains(want) } }
                values = routine.read.compactMap { label in
                    guard let e = texts.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame && !($0.value ?? "").isEmpty })
                        ?? texts.first(where: { ($0.label ?? "").localizedCaseInsensitiveContains(label) && ($0.label ?? "").count > label.count }) else { return nil }
                    if let v = e.value, !v.isEmpty { return "\(label) = \(v)" }
                    let rest = (e.label ?? "").replacingOccurrences(of: label, with: "", options: .caseInsensitive).trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
                    return rest.isEmpty ? nil : "\(label) = \(rest)"
                }
                if missing.isEmpty && values.count == routine.read.count { break }
                await sleep(seconds: 0.15)
            }
            if !missing.isEmpty {
                let why = "the end check did not pass: \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) not on screen"
                finish("ran, end check failed", stop: RoutineStop(step: routine.steps.count, why: why, at: Date()))
                return "\(title): \(outcome), but \(why)\(fixedNote()); look at the screen below before going on"
            }
            if !routine.expect.isEmpty || !values.isEmpty { runEndedOnARead = true }
            if !routine.expect.isEmpty { outcome += ", end check passed (\(routine.expect.map { "\"\($0)\"" }.joined(separator: ", ")) on screen)" }
            if !values.isEmpty { outcome += "; read: " + values.joined(separator: "; ") }
            else if !routine.read.isEmpty { outcome += "; the values to read (\(routine.read.joined(separator: ", "))) were not found: read them from the screen below" }
        }
        outcome += fixedNote()
        finish("ok", stop: nil)
        if saved { routineRanWhole = true }
        return "\(title): \(outcome)"
    }

    /// The one element a step acts on among those that match its target, or why none is taken: a
    /// single match, or the one clearly nearest to where the target was recorded.
    static func pick(among reachable: [Element], for target: RoutineTarget) -> (Element?, String?) {
        guard !reachable.isEmpty else { return (nil, "\(target.describe) is listed but not where a tap reaches it") }
        if reachable.count == 1 { return (reachable[0], nil) }
        // A path names a target by its text alone: among several, the one that takes a tap.
        if !target.hasPlace {
            let controls = reachable.filter { tappable.contains($0.type) }
            if controls.count == 1 { return (controls[0], nil) }
            return (nil, "\(reachable.count) elements read \(target.describe) and none is clearly the one meant")
        }
        func distance(_ e: Element) -> Double { hypot(e.frame.centre.x - target.x, e.frame.centre.y - target.y) }
        let near = reachable.sorted { distance($0) < distance($1) }
        let d0 = distance(near[0]), d1 = distance(near[1])
        if d0 < 40, d1 > 2 * d0 + 20 { return (near[0], nil) }
        return (nil, "\(near.count) elements match \(target.describe) and none is clearly the recorded one")
    }

    /// The number a run gives the element it found, for the one action it sends.
    static let runRef = 900_001

    static func replacingTarget(_ action: JSON, with ref: Int) -> JSON {
        guard case .object(var o) = action else { return action }
        for key in ["tap", "long_press"] {
            if o[key]?.string == "@" { o[key] = .number(Double(ref)) }
            else if case .object(var inner) = o[key], inner["ref"]?.string == "@" { inner["ref"] = .number(Double(ref)); o[key] = .object(inner) }
        }
        if o["ref"]?.string == "@" { o["ref"] = .number(Double(ref)) }
        return .object(o)
    }

    /// A new task: its recording starts empty.
    func beginRecording() {
        trace = []
        routineRanWhole = false
    }

    /// The routines saved for the app in front, for the first look of a task (nil when none).
    func routinesLine() -> String? {
        guard let memory else { return nil }
        let app = lastForeground?.bundleID
        let all = memory.routines.filter { !$0.stale }
        guard !all.isEmpty else { return nil }
        let here = all.filter { $0.app == app }
        let shown = (here.isEmpty ? all : here).sorted { $0.updated > $1.updated }.prefix(6)
        let names = shown.map { "\"\($0.name)\"\($0.description.isEmpty ? "" : " (\($0.description.prefix(60)))")" }.joined(separator: ", ")
        return "routines\(here.isEmpty ? "" : " for this app"): \(names)\(all.count > shown.count ? ", and \(all.count - shown.count) more (routines {action: \"list\"})" : ""); do {run: \"name\"} repeats one in a single call"
    }
}

extension String {
    /// `{{name}}` replaced by the parameter's value.
    func replacingParams(_ params: [String: String]) -> String {
        var out = self
        for (k, v) in params { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }
}

// MARK: The routines tool

extension PokiCore {
    /// What a model should know at the start of a task about this phone's owner and saved routines:
    /// the notes, and the routines that fit `task` best. "" when nothing is saved.
    public static func memoryBrief(for task: String) -> String { RoutineStore.shared.brief(for: task) }

    static let routinesTool: JSON = [
        "name": "routines",
        "description": "The agent's memory on this phone, shared by every agent that drives it. Routines are saved paths through apps: the do actions of a task, each target kept as what it is (role and label), so do {run: \"name\"} replays it in one call, waits for each target, and stops cleanly at a screen that differs. Notes are short facts about the owner. action: list (routines and notes) | show (one routine's steps, name) | save (the do actions sent since this task began, as name, with description; expect: texts that must be on screen at the end, chosen from the last screen when left out; read: labels whose values a run reports) | edit (name; rename, description, expect, read, steps as JSON to replace them) | forget (name) | remember (text: a fact worth keeping, never a password) | forget_note (id or text) | export (the whole memory as JSON, to review or move) | import (data: such JSON; newer routines win). Save a routine after a task that worked and that someone may ask for again; save it again under the same name to fix one that stopped.",
        "inputSchema": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "show", "save", "edit", "forget", "remember", "forget_note", "export", "import"]],
            "name": ["type": "string"], "description": ["type": "string"], "rename": ["type": "string"],
            "text": ["type": "string"], "data": ["type": "string"],
            "expect": ["type": "array", "items": ["type": "string"]], "read": ["type": "array", "items": ["type": "string"]],
            "steps": ["type": "string"],
        ], "required": ["action"], "additionalProperties": false],
    ]

    /// `conversation` is the app's saved conversation the call came from (Poki's own chat), kept with a
    /// note as where it was heard.
    func routinesCall(_ args: JSON, session: String?, conversation: String? = nil) -> ToolResult {
        guard let store = computer.memory else { return ToolResult(text: "routines: no memory on this phone", jpeg: nil, isError: true) }
        let action = args["action"]?.string ?? "list"
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A client's own name never passes for the owner, an import or Dream: those are the app's own.
        let named = session.flatMap { clientNames.value[$0] }.flatMap { $0.isEmpty || RoutineStore.isReserved($0) ? nil : $0 }
        let by = session == nil ? "Poki" : named ?? "an MCP client"
        func fail(_ text: String) -> ToolResult { ToolResult(text: "routines \(action): \(text)", jpeg: nil, isError: true) }
        let locked = "is locked by the owner: only they change or forget it, on Poki's Memory page"
        switch action {
        case "list":
            let routines = store.routines, notes = store.notes
            var lines = ["routines (\(routines.count)):"] + routines.map { "- \($0.summary)\($0.isLocked ? " (locked)" : "")" }
            if routines.isEmpty { lines = ["routines: none saved yet. After a task that worked, routines {action: \"save\", name, description} keeps its steps so do {run: name} repeats them in one call."] }
            lines.append(notes.isEmpty ? "notes: none" : "notes (\(notes.count)):")
            lines += notes.map { "- [\($0.id)] \($0.text) (by \($0.by)\($0.isLocked ? ", locked" : ""))" }
            if !computer.trace.isEmpty { lines.append("this task has \(computer.trace.count) recorded steps so far (save keeps them)") }
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        case "show":
            guard let r = store.routine(named: name) else { return fail("no routine named \"\(name)\"") }
            var lines = [r.summary]
            for (i, s) in r.steps.enumerated() {
                lines.append("\(i + 1). \(s.action.serialized())\(s.target.map { " on \($0.describe)\($0.hasPlace ? " at [\(Int($0.x)), \(Int($0.y))]" : "")" } ?? "")\(s.app.map { " in \($0)" } ?? "")")
            }
            if !r.expect.isEmpty { lines.append("end check: " + r.expect.map { "\"\($0)\"" }.joined(separator: ", ")) }
            if !r.read.isEmpty { lines.append("reads: " + r.read.joined(separator: ", ")) }
            let compact = JSONEncoder(); compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; compact.dateEncodingStrategy = .iso8601
            let steps = (try? String(decoding: compact.encode(r.steps), as: UTF8.self)) ?? "[]"
            lines.append("steps as JSON (edit takes this shape): \(steps)")
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        case "save":
            guard !name.isEmpty else { return fail("give the routine a name") }
            let expect = args["expect"]?.array?.compactMap(\.string)
            let read = args["read"]?.array?.compactMap(\.string) ?? store.routine(named: name)?.read ?? []
            let (routine, note) = computer.routine(named: name, description: args["description"]?.string ?? store.routine(named: name)?.description ?? "", read: read, expect: expect, by: by)
            guard let routine else { return fail(note) }
            let replacing = store.routine(named: name) != nil
            guard store.save(routine) else { return fail("\"\(name)\" \(locked); save this one under another name") }
            return ToolResult(text: "routines: \(replacing ? "saved over" : "saved") \"\(routine.name)\" (\(routine.steps.count) steps\(routine.app.map { " in \($0)" } ?? "")\(routine.params.isEmpty ? "" : "; it types " + routine.params.keys.sorted().joined(separator: ", ") + ", which with: changes")\(routine.expect.isEmpty ? "" : "; end check: " + routine.expect.map { "\"\($0)\"" }.joined(separator: ", "))). do {run: \"\(routine.name)\"} repeats it.\(note.isEmpty ? "" : " Note: \(note).")", jpeg: nil)
        case "edit":
            guard let current = store.routine(named: name) else { return fail("no routine named \"\(name)\"") }
            guard !current.isLocked else { return fail("\"\(name)\" \(locked)") }
            var newSteps: [RoutineStep]?
            if let text = args["steps"]?.string {
                guard let steps = try? RoutineStore.decoder.decode([RoutineStep].self, from: Data(text.utf8)), !steps.isEmpty else { return fail("steps must be the JSON array show gives") }
                newSteps = steps
            }
            store.update(name, by: by) { r in
                if let d = args["description"]?.string { r.description = d }
                if let e = args["expect"]?.array { r.expect = e.compactMap(\.string) }
                if let e = args["read"]?.array { r.read = e.compactMap(\.string) }
                if let steps = newSteps { r.steps = steps; r.failuresInARow = 0; r.lastStop = nil }
                r.updated = Date()
            }
            if let rename = args["rename"]?.string, !rename.isEmpty, !store.rename(name, to: rename, by: by) {
                return fail("edited \"\(name)\", but kept its name: \"\(rename)\" is another routine's")
            }
            return ToolResult(text: "routines: edited \"\(args["rename"]?.string ?? name)\"", jpeg: nil)
        case "forget":
            if store.routine(named: name)?.isLocked == true { return fail("\"\(name)\" \(locked)") }
            guard store.forget(name, by: by) else { return fail("no routine named \"\(name)\"") }
            return ToolResult(text: "routines: forgot \"\(name)\"", jpeg: nil)
        case "remember":
            let text = args["text"]?.string ?? ""
            // Heard in a conversation of Poki's own: kept with it, and with the app in front then.
            let front = computer.lastForeground.flatMap { f in computer.config.isPoki(f) || f.bundleID == "com.apple.springboard" ? nil : f.bundleID }
            let heard = conversation.map { NoteOrigin(session: $0, app: front) }
            guard let note = store.remember(text, by: by, heard: heard) else { return fail("give the text to remember") }
            return ToolResult(text: "routines: remembered [\(note.id)] \(note.text)", jpeg: nil)
        case "forget_note":
            let which = args["text"]?.string ?? name
            if store.note(which)?.isLocked == true { return fail("that note \(locked)") }
            guard store.forgetNote(which, by: by) else { return fail("no such note") }
            return ToolResult(text: "routines: note forgotten", jpeg: nil)
        case "export":
            guard let data = try? store.exportData() else { return fail("could not be made") }
            return ToolResult(text: String(decoding: data, as: UTF8.self), jpeg: nil)
        case "import":
            guard let text = args["data"]?.string else { return fail("give data: the JSON export gives") }
            do {
                let summary = try store.importData(Data(text.utf8), by: by)
                    return ToolResult(text: "routines: \(summary)", jpeg: nil)
            } catch { return fail("\(error)") }
        default:
            return fail("unknown action; the actions are list, show, save, edit, forget, remember, forget_note, export, import")
        }
    }
}
