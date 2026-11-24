import Foundation
import SwiftUI

/// Filter pills shown at the top of the full app browser (B1).
enum AppPickerCategory: String, CaseIterable, Hashable, Identifiable {
    case all
    case social
    case lifestyle
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppLocalization.text(LocalizedStringResource("All"))
        case .social: AppLocalization.text(LocalizedStringResource("Social"))
        case .lifestyle: AppLocalization.text(LocalizedStringResource("Life & Travel"))
        case .system: AppLocalization.text(LocalizedStringResource("System & Tools"))
        }
    }
}

/// Section grouping inside the full app browser list.
enum AppPickerSectionKind: String, CaseIterable, Hashable, Identifiable {
    case lifestyle
    case social
    case system
    case installed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lifestyle: AppLocalization.text(LocalizedStringResource("Life and Travel"))
        case .social: AppLocalization.text(LocalizedStringResource("Social & Media"))
        case .system: AppLocalization.text(LocalizedStringResource("Apple System Apps"))
        case .installed: AppLocalization.text(LocalizedStringResource("Installed on iPhone"))
        }
    }

    init(_ category: KnownAppCategory) {
        switch category {
        case .lifestyle: self = .lifestyle
        case .social: self = .social
        case .system: self = .system
        }
    }
}

/// A single selectable app from `KnownApps` or `DynamicApps`.
struct AppPickerEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String?
    let searchTerms: [String]
    let section: AppPickerSectionKind
    let indexLetter: String
    let isDynamic: Bool

    static func from(_ app: KnownApp, language: AppLanguage) -> AppPickerEntry {
        let primary = app.name(in: language)
        return AppPickerEntry(
            id: app.id,
            displayName: primary,
            subtitle: makeSubtitle(for: app, primary: primary, language: language),
            searchTerms: app.names,
            section: AppPickerSectionKind(app.category),
            indexLetter: AppPickerCatalog.indexLetter(for: primary),
            isDynamic: false
        )
    }

    static func from(_ entry: DynamicApps.Entry) -> AppPickerEntry {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppPickerEntry(
            id: entry.id,
            displayName: name,
            subtitle: nil,
            searchTerms: [name],
            section: .installed,
            indexLetter: AppPickerCatalog.indexLetter(for: name),
            isDynamic: true
        )
    }

    private static func makeSubtitle(for app: KnownApp, primary: String, language: AppLanguage) -> String? {
        var parts: [String] = []
        let primaryLower = primary.lowercased()
        func appendUnique(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lower = trimmed.lowercased()
            guard lower != primaryLower, !parts.contains(where: { $0.lowercased() == lower }) else { return }
            parts.append(trimmed)
        }

        switch language {
        case .simplifiedChinese, .traditionalChinese:
            appendUnique(app.english)
            for alias in app.aliases {
                if parts.count >= 2 { break }
                appendUnique(alias)
            }
        case .english:
            for alias in app.aliases {
                if parts.count >= 2 { break }
                appendUnique(alias)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}

struct AppPickerSection: Identifiable, Equatable {
    let kind: AppPickerSectionKind
    let apps: [AppPickerEntry]

    var id: AppPickerSectionKind { kind }
}

struct AppPickerIndexTarget: Identifiable, Equatable {
    let label: String
    let targetID: String

    var id: String { "\(label)|\(targetID)" }
}

/// Persists recently selected app bundle IDs so `+` quick picks and B1 "Recent" adapt over time.
final class RecentAppsStore {
    static let shared = RecentAppsStore()
    static let defaultsKey = "poki.appPicker.recentIDs"
    private let defaults: UserDefaults
    private let maxCount = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recentIDs: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func record(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = recentIDs.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        if updated.count > maxCount { updated = Array(updated.prefix(maxCount)) }
        defaults.set(updated, forKey: Self.defaultsKey)
    }
}

/// Result of evaluating the composer text for `@` mention or 3+ character prefix completion.
struct AppMentionState: Equatable {
    let triggerLength: Int
    let query: String
    let isExplicit: Bool
    let matches: [AppPickerEntry]

    var isEmptyResult: Bool { isExplicit && !query.isEmpty && matches.isEmpty }
}

/// Pure domain logic for cataloging, filtering, indexing, matching, highlighting, and backfilling apps.
enum AppPickerCatalog {
    /// Combined list of `KnownApps` and uniquely named installed user apps (`DynamicApps`).
    static func allEntries(
        language: AppLanguage = .current,
        dynamicApps: [DynamicApps.Entry] = DynamicApps.uniquelyNamedUserApps
    ) -> [AppPickerEntry] {
        let known = KnownApps.all.map { AppPickerEntry.from($0, language: language) }
        var seenIDs = Set(KnownApps.byID.keys)
        var seenNames = Set(KnownApps.byName.keys)
        var result = known
        for app in dynamicApps {
            let idKey = app.id.lowercased()
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2, !seenIDs.contains(idKey), seenNames.insert(name.lowercased()).inserted else { continue }
            seenIDs.insert(idKey)
            result.append(AppPickerEntry.from(app))
        }
        return result
    }

    /// Top `limit` apps for the A1 `+` quick row, prioritizing recent picks and falling back to language defaults.
    static func quickApps(
        limit: Int = 3,
        recentIDs: [String] = RecentAppsStore.shared.recentIDs,
        language: AppLanguage = .current,
        dynamicApps: [DynamicApps.Entry] = DynamicApps.uniquelyNamedUserApps
    ) -> [AppPickerEntry] {
        pickPrioritized(
            limit: limit,
            recentIDs: recentIDs,
            defaults: KnownApps.defaultQuickAppIDs(for: language),
            language: language,
            dynamicApps: dynamicApps
        )
    }

    /// Top `limit` apps for the B1 "Recent" 5-column strip.
    static func recentApps(
        limit: Int = 5,
        recentIDs: [String] = RecentAppsStore.shared.recentIDs,
        language: AppLanguage = .current,
        dynamicApps: [DynamicApps.Entry] = DynamicApps.uniquelyNamedUserApps
    ) -> [AppPickerEntry] {
        pickPrioritized(
            limit: limit,
            recentIDs: recentIDs,
            defaults: KnownApps.defaultRecentAppIDs(for: language),
            language: language,
            dynamicApps: dynamicApps
        )
    }

    private static func pickPrioritized(
        limit: Int,
        recentIDs: [String],
        defaults: [String],
        language: AppLanguage,
        dynamicApps: [DynamicApps.Entry]
    ) -> [AppPickerEntry] {
        let entries = allEntries(language: language, dynamicApps: dynamicApps)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.lowercased(), $0) })
        var out: [AppPickerEntry] = []
        var used: Set<String> = []

        func appendIfPresent(_ id: String) {
            let key = id.lowercased()
            guard out.count < limit, used.insert(key).inserted, let entry = byID[key] else { return }
            out.append(entry)
        }

        for id in recentIDs { appendIfPresent(id) }
        for id in defaults { appendIfPresent(id) }
        for entry in entries where out.count < limit { appendIfPresent(entry.id) }
        return out
    }

    /// Groups apps by category and applies category + real-time query filtering.
    static func filteredSections(
        query: String,
        category: AppPickerCategory,
        language: AppLanguage = .current,
        dynamicApps: [DynamicApps.Entry] = DynamicApps.uniquelyNamedUserApps
    ) -> [AppPickerSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = allEntries(language: language, dynamicApps: dynamicApps).filter { entry in
            matchesCategory(entry, category: category) && matchesSearch(entry, needle: needle)
        }

        let order: [AppPickerSectionKind] = [.lifestyle, .social, .system, .installed]
        let grouped = Dictionary(grouping: entries, by: \.section)
        return order.compactMap { kind in
            guard let list = grouped[kind], !list.isEmpty else { return nil }
            let sorted = list.sorted { lhs, rhs in
                if !needle.isEmpty {
                    let lp = hasPrefix(lhs, needle: needle)
                    let rp = hasPrefix(rhs, needle: needle)
                    if lp != rp { return lp }
                }
                if lhs.indexLetter != rhs.indexLetter {
                    if lhs.indexLetter == "#" { return false }
                    if rhs.indexLetter == "#" { return true }
                    return lhs.indexLetter < rhs.indexLetter
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return AppPickerSection(kind: kind, apps: sorted)
        }
    }

    /// Builds the trailing quick-jump index targets (`热`/`★` + A-Z) for the visible sections.
    static func indexTargets(
        for sections: [AppPickerSection],
        includesRecent: Bool,
        language: AppLanguage = .current
    ) -> [AppPickerIndexTarget] {
        var targets: [AppPickerIndexTarget] = []
        if includesRecent {
            let recentLabel = language == .english ? "★" : "热"
            targets.append(AppPickerIndexTarget(label: recentLabel, targetID: "section.recent"))
        }
        var firstByLetter: [String: String] = [:]
        for section in sections {
            for app in section.apps where firstByLetter[app.indexLetter] == nil {
                firstByLetter[app.indexLetter] = app.id
            }
        }
        let sortedLetters = firstByLetter.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        for letter in sortedLetters {
            if let id = firstByLetter[letter] {
                targets.append(AppPickerIndexTarget(label: letter, targetID: id))
            }
        }
        return targets
    }

    /// Bundle IDs of apps already referenced as capsules in `draft`.
    static func mentionedBundleIDs(in draft: String) -> Set<String> {
        guard !draft.isEmpty else { return [] }
        var ids: Set<String> = []
        for segment in CapsuleText.segments(draft) {
            if case .app(let capsule, _) = segment {
                ids.insert(capsule.id.lowercased())
            }
        }
        return ids
    }

    /// Evaluates `@` mention and implicit 3+ character prefix completion.
    static func mentionState(
        input: String,
        mentionReady: Bool,
        adding: Bool,
        recentIDs: [String] = RecentAppsStore.shared.recentIDs,
        language: AppLanguage = .current,
        dynamicApps: [DynamicApps.Entry] = DynamicApps.uniquelyNamedUserApps,
        limit: Int = 20
    ) -> AppMentionState? {
        guard mentionReady, !adding else { return nil }
        let trailing = String(input.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !trailing.isEmpty else { return nil }

        let trigger: (length: Int, query: String, explicit: Bool)? = {
            if let atIndex = trailing.lastIndex(of: "@") {
                if atIndex > trailing.startIndex {
                    let before = trailing[trailing.index(before: atIndex)]
                    // Avoid triggering inside email addresses such as `user@me`.
                    if before.isASCII && (before.isLetter || before.isNumber) {
                        return nil
                    }
                }
                let slice = trailing[atIndex...]
                return (slice.count, String(slice.dropFirst()), true)
            }
            guard trailing.count >= 3 else { return nil }
            return (trailing.count, trailing, false)
        }()

        guard let trigger else { return nil }
        let lower = trigger.query.lowercased()
        let entries = allEntries(language: language, dynamicApps: dynamicApps)
        let recentRank = Dictionary(
            uniqueKeysWithValues: recentIDs.enumerated().map { ($0.element.lowercased(), $0.offset) }
        )

        if trigger.explicit, lower.isEmpty {
            let defaults = KnownApps.defaultRecentAppIDs(for: language)
            let prioritized = pickPrioritized(
                limit: min(12, limit),
                recentIDs: recentIDs,
                defaults: defaults,
                language: language,
                dynamicApps: dynamicApps
            )
            return AppMentionState(triggerLength: trigger.length, query: "", isExplicit: true, matches: prioritized)
        }

        let matched = entries.filter { entry in
            entry.searchTerms.contains { term in
                let candidate = term.lowercased()
                return candidate.hasPrefix(lower) && (trigger.explicit || candidate != lower)
            }
        }
        .sorted { lhs, rhs in
            let lPrimary = lhs.displayName.lowercased().hasPrefix(lower)
            let rPrimary = rhs.displayName.lowercased().hasPrefix(lower)
            if lPrimary != rPrimary { return lPrimary }
            let lRecent = recentRank[lhs.id.lowercased()] ?? Int.max
            let rRecent = recentRank[rhs.id.lowercased()] ?? Int.max
            if lRecent != rRecent { return lRecent < rRecent }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        if !trigger.explicit, matched.isEmpty { return nil }
        return AppMentionState(
            triggerLength: trigger.length,
            query: trigger.query,
            isExplicit: trigger.explicit,
            matches: Array(matched.prefix(limit))
        )
    }

    /// Finds the prefix highlight range in `text` for a mention `query` (case-insensitive).
    static func highlightRange(in text: String, query: String) -> Range<String.Index>? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let range = text.range(of: needle, options: [.caseInsensitive, .anchored]) {
            return range
        }
        // Also highlight after `" / "` in multi-alias subtitles (e.g. `"DiDi / 滴滴"` for query `"滴"`).
        var searchStart = text.startIndex
        while let sep = text.range(of: " / ", range: searchStart..<text.endIndex) {
            let partRange = sep.upperBound..<text.endIndex
            if let range = text.range(of: needle, options: [.caseInsensitive, .anchored], range: partRange) {
                return range
            }
            searchStart = sep.upperBound
        }
        return nil
    }

    /// Builds an `AttributedString` highlighting the matched prefix in Poki light blue.
    static func highlightedText(
        _ text: String,
        query: String,
        baseColor: Color,
        highlightColor: Color,
        baseFont: Font,
        highlightFont: Font
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = baseColor
        attributed.font = baseFont
        if let range = highlightRange(in: text, query: query),
           let attrRange = Range(range, in: attributed) {
            attributed[attrRange].foregroundColor = highlightColor
            attributed[attrRange].font = highlightFont
        }
        return attributed
    }

    /// Inserts an app name into `text`, replacing a trailing mention trigger or inserting at `cursorUTF16`,
    /// always appending a trailing space and returning the resulting text and caret UTF-16 offset.
    static func insertApp(
        _ entry: AppPickerEntry,
        into text: String,
        cursorUTF16: Int? = nil,
        replacing triggerLength: Int = 0
    ) -> (text: String, cursorUTF16: Int) {
        if triggerLength > 0 {
            let prefix = String(text.dropLast(min(triggerLength, text.count)))
            let leading = prefix.last.map { !$0.isWhitespace } == true ? " " : ""
            let inserted = prefix + leading + entry.displayName + " "
            return (inserted, inserted.utf16.count)
        }

        let utf16 = text.utf16
        let offset = max(0, min(cursorUTF16 ?? utf16.count, utf16.count))
        let splitUTF16 = utf16.index(utf16.startIndex, offsetBy: offset)
        let splitIndex = splitUTF16.samePosition(in: text) ?? text.endIndex
        let before = String(text[..<splitIndex])
        let after = String(text[splitIndex...])
        let leading = before.last.map { !$0.isWhitespace } == true ? " " : ""
        let needsTrailingSpace = after.first.map { !$0.isWhitespace } ?? true
        let trailing = needsTrailingSpace ? " " : ""
        let head = before + leading + entry.displayName + trailing
        return (head + after, head.utf16.count)
    }

    /// Computes A-Z index letter (using Latin/Pinyin initial for CJK names, `#` otherwise).
    static func indexLetter(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        if first.isASCII, first.isLetter {
            return String(first).uppercased()
        }
        let mutable = NSMutableString(string: String(first)) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if let letter = latin.first, letter.isASCII, letter.isLetter {
            return String(letter).uppercased()
        }
        return "#"
    }

    private static func matchesCategory(_ entry: AppPickerEntry, category: AppPickerCategory) -> Bool {
        switch category {
        case .all: true
        case .social: entry.section == .social
        case .lifestyle: entry.section == .lifestyle
        case .system: entry.section == .system
        }
    }

    private static func matchesSearch(_ entry: AppPickerEntry, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return entry.searchTerms.contains { $0.lowercased().contains(needle) }
            || entry.id.lowercased().contains(needle)
    }

    private static func hasPrefix(_ entry: AppPickerEntry, needle: String) -> Bool {
        entry.searchTerms.contains { $0.lowercased().hasPrefix(needle) }
    }
}

/// Computes horizontal offset for the `@` mention overlay, clamping within the composer bounds on wide screens.
enum MentionPickerLayout {
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 340

    static func width(for composerWidth: CGFloat) -> CGFloat {
        guard composerWidth > 0 else { return minWidth }
        return min(maxWidth, max(min(minWidth, composerWidth), composerWidth))
    }

    static func horizontalOffset(caretX: CGFloat?, pickerWidth: CGFloat, composerWidth: CGFloat) -> CGFloat {
        guard composerWidth > pickerWidth else { return 0 }
        let raw = (caretX ?? 0) - 24
        return min(max(0, raw), composerWidth - pickerWidth)
    }
}

/// Shared smoked Liquid Glass styling aligned with native `PokiMenu`.
enum AppPickerGlass {
    /// Subtle dark smoked tint so the menu/mention surface aligns with native `PokiMenu`
    /// without picking up a muddy blue cast from the bottom glow.
    static func tint(for scheme: ColorScheme) -> Color? {
        scheme == .dark ? Color(hex: 0x151821).opacity(0.68) : nil
    }

    /// Poki light blue highlight for matched `@` prefixes and alphabet index letters.
    static let highlightBlue = Color(light: 0x0177FD, dark: 0x7CC0FF)
}
