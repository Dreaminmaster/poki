import Foundation

public struct ScreenHistoryEntry: Sendable, Equatable {
    public var startAt: Date
    public var at: Date
    public var app: String
    public var bundleID: String
    public var appAliases: [String]
    public var title: String
    public var text: String

    public init(
        startAt: Date? = nil,
        at: Date,
        app: String,
        bundleID: String,
        appAliases: [String] = [],
        title: String = "",
        text: String
    ) {
        self.startAt = startAt ?? at
        self.at = at
        self.app = app
        self.bundleID = bundleID
        self.appAliases = appAliases
        self.title = title
        self.text = text
    }
}

/// What the check on the iPhone decided about one screen_history answer before it leaves Poki
/// (the owner, 2026-11-20: outside agents' screen_history goes through the same on-device check as
/// Poki's chat). `ask` puts an approval in front of the owner, as a sensitive step does.
public enum ScreenHistoryVerdict: Sendable, Equatable {
    case share
    case ask(reason: String)
    case refuse(String)
}

public struct ScreenHistorySource: Sendable {
    public var isEnabled: @Sendable () -> Bool
    public var unavailableMessage: @Sendable () -> String
    /// Changes whenever the owner revokes or re-grants access, changes the app allowlist,
    /// or deletes history. A Boolean alone cannot detect an off -> on transition.
    public var accessRevision: @Sendable () -> UInt64
    public var now: @Sendable () -> Date
    public var entries: @Sendable (_ from: Date, _ to: Date) async -> [ScreenHistoryEntry]
    /// Reads the answer (the JSON about to be returned) and the call's arguments, and decides. Nil
    /// lets every answer through, as before.
    public var check: (@Sendable (_ answer: String, _ arguments: String) async -> ScreenHistoryVerdict)?

    public init(
        isEnabled: @escaping @Sendable () -> Bool,
        accessRevision: @escaping @Sendable () -> UInt64,
        unavailableMessage: @escaping @Sendable () -> String = { "Screen History is not turned on." },
        now: @escaping @Sendable () -> Date = { Date() },
        entries: @escaping @Sendable (_ from: Date, _ to: Date) async -> [ScreenHistoryEntry],
        check: (@Sendable (_ answer: String, _ arguments: String) async -> ScreenHistoryVerdict)? = nil
    ) {
        self.isEnabled = isEnabled
        self.unavailableMessage = unavailableMessage
        self.accessRevision = accessRevision
        self.now = now
        self.entries = entries
        self.check = check
    }
}

enum ScreenHistoryTextCleaner {
    private static let chromeLabels: Set<String> = [
        "add", "plus", "close", "dismiss", "back", "more", "menu", "share",
        "clear text", "system input assistant", "dictation", "emoji", "space", "return",
        "ellipsis", "xmark", "chevron.right", "chevron.left", "magnifyingglass",
        "清除文本", "清除文字", "系统输入助手", "系統輸入輔助",
    ]

    static func cleanLines(_ raw: String) -> [String] {
        var result: [String] = []
        for slice in raw.components(separatedBy: .newlines) {
            let line = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isNoise(line) else { continue }
            if result.last != line {
                result.append(line)
            }
        }
        return result
    }

    static func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNoise(trimmed) ? "" : trimmed
    }

    private static func isNoise(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        if line.unicodeScalars.allSatisfy({ isPrivateUse($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return true
        }
        let lowered = line.lowercased()
        if lowered.contains("scroll bar") || line.contains("滚动条") || line.contains("捲動列") {
            return true
        }
        if isBarePercentage(line) {
            return true
        }
        if chromeLabels.contains(lowered) || lowered.hasPrefix("ic_") || lowered.hasPrefix("btn_") {
            return true
        }
        return false
    }

    private static func isBarePercentage(_ line: String) -> Bool {
        guard line.last == "%" else { return false }
        var body = line.dropLast().trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("+") || body.hasPrefix("-") {
            body.removeFirst()
        }
        guard !body.isEmpty else { return false }
        var sawDigit = false
        var sawDot = false
        for scalar in body.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                sawDigit = true
            } else if scalar == "." && !sawDot {
                sawDot = true
            } else {
                return false
            }
        }
        return sawDigit
    }

    private static func isPrivateUse(_ scalar: UnicodeScalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value)
            || (0xF0000...0xFFFFD).contains(scalar.value)
            || (0x100000...0x10FFFD).contains(scalar.value)
    }
}

enum ScreenHistoryCoalescer {
    private static let maxGapSeconds: TimeInterval = 900
    private static let maxMergedLines = 120

    static func prepare(_ rawEntries: [ScreenHistoryEntry]) -> [ScreenHistoryEntry] {
        let sorted = rawEntries.sorted { $0.at < $1.at }
        var merged: [(entry: ScreenHistoryEntry, lines: [String])] = []

        for item in sorted {
            let lines = ScreenHistoryTextCleaner.cleanLines(item.text)
            let title = ScreenHistoryTextCleaner.cleanTitle(item.title)
            guard !lines.isEmpty || !title.isEmpty else { continue }

            var cleaned = item
            cleaned.title = title
            cleaned.text = lines.joined(separator: "\n")

            if let last = merged.last,
               sameApp(last.entry, cleaned),
               cleaned.at.timeIntervalSince(last.entry.at) <= maxGapSeconds,
               areNearlySame(last.lines, lines, lastTitle: last.entry.title, nextTitle: title) {
                let combinedLines = mergeLines(last.lines, lines)
                var updated = last.entry
                updated.at = cleaned.at
                if !title.isEmpty { updated.title = title }
                updated.text = combinedLines.joined(separator: "\n")
                merged[merged.count - 1] = (updated, combinedLines)
            } else {
                merged.append((cleaned, lines))
            }
        }

        return merged.map(\.entry)
    }

    private static func sameApp(_ lhs: ScreenHistoryEntry, _ rhs: ScreenHistoryEntry) -> Bool {
        if !lhs.bundleID.isEmpty && !rhs.bundleID.isEmpty {
            return lhs.bundleID.caseInsensitiveCompare(rhs.bundleID) == .orderedSame
        }
        return lhs.app.caseInsensitiveCompare(rhs.app) == .orderedSame
    }

    private static func areNearlySame(_ lhs: [String], _ rhs: [String], lastTitle: String, nextTitle: String) -> Bool {
        if lhs == rhs {
            return !lhs.isEmpty || lastTitle.caseInsensitiveCompare(nextTitle) == .orderedSame
        }
        let leftJoined = lhs.joined(separator: "\n")
        let rightJoined = rhs.joined(separator: "\n")
        if !leftJoined.isEmpty && !rightJoined.isEmpty && (rightJoined.contains(leftJoined) || leftJoined.contains(rightJoined)) {
            return true
        }
        let leftSet = Set(lhs)
        let rightSet = Set(rhs)
        let smaller = min(leftSet.count, rightSet.count)
        guard smaller >= 2 else { return false }
        let shared = leftSet.intersection(rightSet).count
        let overlap = Double(shared) / Double(smaller)
        let dice = Double(2 * shared) / Double(leftSet.count + rightSet.count)
        return overlap >= 0.7 || dice >= 0.6
    }

    private static func mergeLines(_ earlier: [String], _ later: [String]) -> [String] {
        var result = earlier
        for line in later {
            if result.contains(line) { continue }
            if let prefixIndex = result.firstIndex(where: { line.hasPrefix($0) && line.count > $0.count }) {
                result[prefixIndex] = line
            } else if result.contains(where: { $0.hasPrefix(line) && $0.count > line.count }) {
                continue
            } else if result.count < maxMergedLines {
                result.append(line)
            }
        }
        return result
    }
}

enum ScreenHistoryPeriod: String {
    case lastHour = "last_hour"
    case morning
    case afternoon
    case evening
    case night
    case today
    case yesterday
    case week

    private static let dayParts: [ScreenHistoryPeriod: (startHour: Int, endHour: Int)] = [
        .night: (0, 6),
        .morning: (5, 12),
        .afternoon: (12, 18),
        .evening: (18, 24),
    ]

    func bounds(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        if let part = Self.dayParts[self] {
            let todayStart = calendar.startOfDay(for: now)
            let candidateStart = calendar.date(byAdding: .hour, value: part.startHour, to: todayStart) ?? todayStart
            let dayBase = now < candidateStart
                ? (calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-86_400))
                : todayStart
            let start = calendar.date(byAdding: .hour, value: part.startHour, to: dayBase) ?? dayBase
            let end = calendar.date(byAdding: .hour, value: part.endHour, to: dayBase) ?? start.addingTimeInterval(Double(part.endHour - part.startHour) * 3600)
            return (start, end)
        }
        switch self {
        case .lastHour:
            return (now.addingTimeInterval(-3600), now.addingTimeInterval(1))
        case .today:
            return (calendar.startOfDay(for: now), now.addingTimeInterval(1))
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-86_400)
            return (yesterdayStart, todayStart)
        case .week:
            return (now.addingTimeInterval(-7 * 86_400), now.addingTimeInterval(1))
        case .morning, .afternoon, .evening, .night:
            return (now.addingTimeInterval(-3600), now.addingTimeInterval(1))
        }
    }
}

struct ScreenHistoryQuery {
    struct ParseError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    var start: Date
    var end: Date
    var app: String?
    var query: String?
    var limit: Int?

    static func parse(_ args: JSON, now: Date, calendar: Calendar = .current) -> Result<ScreenHistoryQuery, ParseError> {
        let startRaw = args["start"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endRaw = args["end"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStart = startRaw?.isEmpty == false
        let hasEnd = endRaw?.isEmpty == false

        let bounds: (start: Date, end: Date)
        if hasStart || hasEnd {
            let parsedStart: Date
            if let raw = startRaw, !raw.isEmpty {
                guard let date = parseTimestamp(raw, isEnd: false, now: now, calendar: calendar) else {
                    return .failure(ParseError("error: invalid start time \"\(raw)\". Use ISO-8601, YYYY-MM-DD HH:mm, or HH:mm."))
                }
                parsedStart = date
            } else {
                parsedStart = now.addingTimeInterval(-86_400)
            }
            let parsedEnd: Date
            if let raw = endRaw, !raw.isEmpty {
                guard let date = parseTimestamp(raw, isEnd: true, now: now, calendar: calendar) else {
                    return .failure(ParseError("error: invalid end time \"\(raw)\". Use ISO-8601, YYYY-MM-DD HH:mm, or HH:mm."))
                }
                parsedEnd = date
            } else {
                parsedEnd = now.addingTimeInterval(1)
            }
            guard parsedStart <= parsedEnd else {
                return .failure(ParseError("error: start must not be after end."))
            }
            bounds = (parsedStart, parsedEnd)
        } else if let periodRaw = args["period"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !periodRaw.isEmpty {
            guard let period = ScreenHistoryPeriod(rawValue: periodRaw) else {
                return .failure(ParseError("error: unknown period \"\(periodRaw)\"."))
            }
            bounds = period.bounds(now: now, calendar: calendar)
        } else {
            bounds = (now.addingTimeInterval(-86_400), now.addingTimeInterval(1))
        }

        let appFilter = args["app"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let textQuery = args["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ScreenHistoryQuery(
            start: bounds.start,
            end: bounds.end,
            app: appFilter?.isEmpty == false ? appFilter : nil,
            query: textQuery?.isEmpty == false ? textQuery : nil,
            limit: args["limit"]?.int
        ))
    }

    private static func parseTimestamp(_ raw: String, isEnd: Bool, now: Date, calendar: Calendar) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: raw) { return isEnd ? date.addingTimeInterval(0.001) : date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return isEnd ? date.addingTimeInterval(0.001) : date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = calendar.timeZone

        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = pattern
            if let date = local.date(from: raw) {
                return isEnd ? date.addingTimeInterval(pattern.hasSuffix("mm") ? 60 : 1) : date
            }
        }

        local.dateFormat = "yyyy-MM-dd"
        if let day = local.date(from: raw) {
            if isEnd {
                return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            return day
        }

        for pattern in ["HH:mm:ss", "HH:mm"] {
            local.dateFormat = pattern
            if let clock = local.date(from: raw) {
                let parts = calendar.dateComponents([.hour, .minute, .second], from: clock)
                guard let todayTime = calendar.date(
                    bySettingHour: parts.hour ?? 0,
                    minute: parts.minute ?? 0,
                    second: parts.second ?? 0,
                    of: now
                ) else { return nil }
                return isEnd ? todayTime.addingTimeInterval(pattern == "HH:mm" ? 60 : 1) : todayTime
            }
        }

        return nil
    }

    func matches(_ entry: ScreenHistoryEntry) -> Bool {
        if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if let app {
            let needle = app.lowercased()
            let candidates = ([entry.app, entry.bundleID] + entry.appAliases).map { $0.lowercased() }
            guard candidates.contains(where: { $0.contains(needle) || needle.contains($0) }) else { return false }
        }
        if let query {
            let haystack = "\(entry.app)\n\(entry.title)\n\(entry.text)".lowercased()
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard !terms.isEmpty, terms.allSatisfy({ haystack.contains($0) }) else { return false }
        }
        return true
    }
}

enum ScreenHistoryLimits {
    static let defaultEntries = 20
    static let maxEntries = 50
    static let maxEntryCharacters = 600
    static let maxTotalCharacters = 4000
}

private struct ScreenHistoryResponseEntry: Codable, Equatable {
    var app: String
    var at: String
    var endAt: String?
    var text: String
    var title: String?
}

private struct ScreenHistoryResponse: Codable, Equatable {
    var entries: [ScreenHistoryResponseEntry]
    var matched: Int
    var returned: Int
    var truncated: Bool
}

extension PokiCore {
    public static let screenHistoryOffMessage = "Screen History is not turned on."
    public static let screenHistoryRevokedMessage = "Screen History access changed while this query was running. The old result was discarded."

    public static let screenHistoryInstructions = "When the user asks about something they saw, read, or wrote earlier on this iPhone (such as what they looked at before, the thing just now, or something from this morning), query screen_history first instead of launching apps with look or do; finish with finish_task using answer.kind field or list and leave answer.items empty."

    static let screenHistoryTool: JSON = [
        "name": "screen_history",
        "description": "Read text captured earlier on this iPhone by Screen History as JSON: entries with when it was seen (at and optional endAt), the app display name (app), optional screen title (title), and cleaned screen text (text), plus matched, returned, and truncated. Filter by period (last_hour, morning, afternoon, evening, night, today, yesterday, week), by start and end ISO-8601 timestamps, by app name or bundle id, or by keyword query. Results are capped in entry count and character length; narrow the time range or add app or query when truncated.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "period": [
                    "type": "string",
                    "enum": ["last_hour", "morning", "afternoon", "evening", "night", "today", "yesterday", "week"],
                    "description": "Preset time span in the phone's local time zone. Ignored when start or end is given.",
                ],
                "start": [
                    "type": "string",
                    "description": "Start time in ISO-8601 format, YYYY-MM-DD HH:mm, or HH:mm today.",
                ],
                "end": [
                    "type": "string",
                    "description": "End time in ISO-8601 format, YYYY-MM-DD HH:mm, or HH:mm today.",
                ],
                "app": [
                    "type": "string",
                    "description": "App display name or bundle identifier, such as Notes or com.apple.mobilenotes.",
                ],
                "query": [
                    "type": "string",
                    "description": "Keyword or phrase to match in the screen text, title, or app name.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "description": "Maximum number of reads to return (default 20, max 50).",
                ],
            ],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": true],
    ]

    public static let screenHistoryNotShared = "The owner did not allow sharing this Screen History. Do not ask for it again in this task. Go on without it, or ask the owner in plain words for what you need."

    func screenHistoryCall(_ args: JSON, answerBy: Double? = nil) async -> ToolResult {
        guard let source = config.screenHistory, source.isEnabled() else {
            return ToolResult(text: Self.screenHistoryOffMessage, jpeg: nil, isError: true)
        }
        // Capture a lease before the first await. Checking only isEnabled after an await
        // would let an off -> on transition incorrectly authorize an older request.
        let revision = source.accessRevision()
        guard source.isEnabled(), source.accessRevision() == revision else {
            return ToolResult(text: source.unavailableMessage(), jpeg: nil, isError: true)
        }
        func accessStillValid() -> Bool {
            !Task.isCancelled && source.isEnabled() && source.accessRevision() == revision
        }

        let now = source.now()
        let parsed: ScreenHistoryQuery
        switch ScreenHistoryQuery.parse(args, now: now) {
        case .failure(let error):
            return ToolResult(text: error.message, jpeg: nil, isError: true)
        case .success(let value):
            parsed = value
        }

        let raw = await source.entries(parsed.start, parsed.end)
        guard accessStillValid() else {
            return ToolResult(text: Self.screenHistoryRevokedMessage, jpeg: nil, isError: true)
        }
        let matched = ScreenHistoryCoalescer.prepare(raw)
            .filter { parsed.matches($0) }
        let text = Self.formatScreenHistory(matched, query: parsed)
        // Filtering/formatting can also take time for long histories. Do not hand out a
        // result if the owner changed access while it was being prepared.
        guard accessStillValid() else {
            return ToolResult(text: Self.screenHistoryRevokedMessage, jpeg: nil, isError: true)
        }
        guard !matched.isEmpty, let check = source.check else { return ToolResult(text: text, jpeg: nil, isError: false) }
        switch await check(text, args.serialized()) {
        case .share:
            return ToolResult(text: text, jpeg: nil, isError: false)
        case .refuse(let why):
            return ToolResult(text: why, jpeg: nil, isError: true)
        case .ask(let reason):
            // The owner decides, on the same card as a sensitive step. A relay stops waiting for its
            // caller at its deadline, so the hold ends a little before it.
            let hold = answerBy.map { max(0, min(config.approvalWait, $0 - monotonicNow() - config.readTimeout - 3)) } ?? config.approvalWait
            if let pending = approvals.pending { approvals.withdraw(id: pending.id) }
            let approval = approvals.request(app: "Screen History", summary: "Share Screen History", reason: reason.isEmpty ? "reading Screen History" : reason,
                                             scope: ApprovalScope(actions: "history:\(UUID().uuidString)"))
            switch await approvals.wait(id: approval.id, seconds: hold) {
            case .approved?:
                _ = approvals.consumeGrant(scope: approval.scope)
                return ToolResult(text: text, jpeg: nil, isError: false)
            case .declined?, .expired?:
                return ToolResult(text: Self.screenHistoryNotShared, jpeg: nil, isError: true)
            case nil:
                approvals.withdraw(id: approval.id)
                return ToolResult(text: Self.screenHistoryNotShared, jpeg: nil, isError: true)
            }
        }
    }

    private static let screenHistoryEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func encodeScreenHistory(_ entries: [ScreenHistoryResponseEntry], matched: Int, truncated: Bool) -> String {
        let payload = ScreenHistoryResponse(
            entries: entries,
            matched: matched,
            returned: entries.count,
            truncated: truncated
        )
        guard let data = try? screenHistoryEncoder.encode(payload) else {
            return #"{"entries":[],"matched":0,"returned":0,"truncated":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func formatScreenHistory(_ matched: [ScreenHistoryEntry], query: ScreenHistoryQuery) -> String {
        guard !matched.isEmpty else {
            return encodeScreenHistory([], matched: 0, truncated: false)
        }

        let iso = ISO8601DateFormatter()
        iso.timeZone = Calendar.current.timeZone
        iso.formatOptions = [.withInternetDateTime]

        let entryCap = min(ScreenHistoryLimits.maxEntries, max(1, query.limit ?? ScreenHistoryLimits.defaultEntries))
        let terms = query.query?.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) ?? []

        var selectedNewestFirst: [ScreenHistoryResponseEntry] = []
        var shortenedBody = false

        func makeItem(_ entry: ScreenHistoryEntry, textLimit: Int) -> (ScreenHistoryResponseEntry, Bool) {
            let cleanTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var bodyLines = entry.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let keepTitle = !cleanTitle.isEmpty && cleanTitle.caseInsensitiveCompare(entry.app) != .orderedSame
            if keepTitle, bodyLines.count > 1, bodyLines.first?.caseInsensitiveCompare(cleanTitle) == .orderedSame {
                bodyLines.removeFirst()
            }
            let rawText = bodyLines.joined(separator: "\n")
            let (excerpt, wasShortened) = excerptScreenText(rawText, terms: terms, limit: textLimit)
            let mergedSpan = Int(entry.at.timeIntervalSince(entry.startAt)) >= 1
            let item = ScreenHistoryResponseEntry(
                app: entry.app,
                at: iso.string(from: mergedSpan ? entry.startAt : entry.at),
                endAt: mergedSpan ? iso.string(from: entry.at) : nil,
                text: excerpt,
                title: keepTitle ? cleanTitle : nil
            )
            return (item, wasShortened)
        }

        for entry in matched.reversed() {
            if selectedNewestFirst.count >= entryCap { break }
            let (candidate, wasShortened) = makeItem(entry, textLimit: ScreenHistoryLimits.maxEntryCharacters)
            let nextList = Array((selectedNewestFirst + [candidate]).reversed())
            let nextTruncated = nextList.count < matched.count || shortenedBody || wasShortened
            let encoded = encodeScreenHistory(nextList, matched: matched.count, truncated: nextTruncated)
            if encoded.count <= ScreenHistoryLimits.maxTotalCharacters {
                selectedNewestFirst.append(candidate)
                if wasShortened { shortenedBody = true }
                continue
            }
            if selectedNewestFirst.isEmpty {
                var cap = ScreenHistoryLimits.maxEntryCharacters / 2
                var fallback = candidate
                while cap >= 32 {
                    let (smaller, _) = makeItem(entry, textLimit: cap)
                    fallback = smaller
                    if encodeScreenHistory([smaller], matched: matched.count, truncated: true).count <= ScreenHistoryLimits.maxTotalCharacters {
                        break
                    }
                    cap /= 2
                }
                selectedNewestFirst.append(fallback)
                shortenedBody = true
            }
            break
        }

        let ordered = Array(selectedNewestFirst.reversed())
        let truncated = ordered.count < matched.count || shortenedBody
        return encodeScreenHistory(ordered, matched: matched.count, truncated: truncated)
    }

    private static func excerptScreenText(_ text: String, terms: [String], limit: Int) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let lowered = text.lowercased()
        var earliestMatch: String.Index?
        for term in terms where !term.isEmpty {
            if let found = lowered.range(of: term)?.lowerBound {
                if let current = earliestMatch {
                    if found < current { earliestMatch = found }
                } else {
                    earliestMatch = found
                }
            }
        }
        guard let anchor = earliestMatch else {
            return (String(text.prefix(max(1, limit - 1))) + "…", true)
        }
        let matchOffset = lowered.distance(from: lowered.startIndex, to: anchor)
        let windowRoom = max(1, limit - 2)
        let startOffset = min(max(0, matchOffset - windowRoom / 4), max(0, text.count - windowRoom))
        let sliceStart = text.index(text.startIndex, offsetBy: startOffset)
        let sliceEnd = text.index(sliceStart, offsetBy: min(windowRoom, text.distance(from: sliceStart, to: text.endIndex)))
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = sliceEnd < text.endIndex ? "…" : ""
        return (prefix + String(text[sliceStart..<sliceEnd]) + suffix, true)
    }
}

/// The relay's clock (`now()` in Deadline.swift), under a name screenHistoryCall's own `now` does not hide.
private func monotonicNow() -> Double { now() }
