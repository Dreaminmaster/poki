import Foundation

/// The apps installed on this iPhone beyond the ones Poki knows by name (KnownApps), by name and by
/// bundle id. The app fills it from the phone's own app list (InstalledApps); icons, app names and
/// the message field's capsules read it, so an app Poki has never listed still shows with its name
/// and its icon (the iPhone's, else the App Store's). Empty in the widgets, which never fill it.
/// Thread-safe: names are read from any thread.
enum DynamicApps {
    struct Entry: Equatable {
        let id: String
        let name: String
        /// A User app (installed from the App Store or signed by its owner), not one of the system's.
        let user: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    nonisolated(unsafe) private static var byName: [String: String] = [:]
    nonisolated(unsafe) private static var byID: [String: Entry] = [:]
    nonisolated(unsafe) private static var stamp = 0

    /// Bumped on each change, so a table built from `uniquelyNamedUserApps` knows to build again.
    static var version: Int { lock.withLock { stamp } }

    /// Replaces the index. A name two apps share counts for neither: a capsule or an icon by that name
    /// would be a guess.
    static func set(_ list: [Entry]) {
        var names: [String: String] = [:], shared: Set<String> = [], ids: [String: Entry] = [:]
        for entry in list {
            ids[entry.id.lowercased()] = entry
            let key = entry.name.lowercased()
            guard !key.isEmpty, !shared.contains(key) else { continue }
            if let other = names[key], other.caseInsensitiveCompare(entry.id) != .orderedSame {
                names[key] = nil; shared.insert(key)
            } else {
                names[key] = entry.id
            }
        }
        lock.withLock {
            guard entries != list else { return }
            entries = list; byName = names; byID = ids; stamp += 1
        }
    }

    /// The bundle id of the installed app with exactly this name (case-insensitive).
    static func id(forName name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : lock.withLock { byName[key] }
    }

    /// The Home Screen name of the installed app with this bundle id.
    static func name(forID id: String) -> String? {
        lock.withLock { byID[id.lowercased()]?.name }
    }

    /// Every installed User app (the Memory page's app list).
    static var userApps: [Entry] { lock.withLock { entries.filter(\.user) } }

    /// The installed User apps whose name no other installed app shares: the ones a name can stand for.
    static var uniquelyNamedUserApps: [Entry] {
        lock.withLock { entries.filter { $0.user && byName[$0.name.lowercased()]?.caseInsensitiveCompare($0.id) == .orderedSame } }
    }
}

extension KnownApps {
    /// Keeps an explicit bundle ID. For a known app with editions, the system's current install
    /// record takes precedence over the cached app list. Other names use the iPhone's Home Screen names.
    static func launchID(_ nameOrID: String, isInstalled: (String) -> Bool = isInstalledOnPhone) -> String? {
        let given = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        if DynamicApps.name(forID: given) != nil { return given }
        if let known = find(given) {
            if known.ids.contains(where: { $0.caseInsensitiveCompare(given) == .orderedSame }) { return given }
            guard !known.otherIDs.isEmpty else { return known.id }
            return known.ids.first(where: isInstalled)
                ?? known.ids.first { DynamicApps.name(forID: $0) != nil }
                ?? known.id
        }
        return DynamicApps.id(forName: given)
    }

    static func installedLaunchID(_ given: String) -> String? {
        let identifier = NSSelectorFromString("bundleIdentifier")
        if let proxy = installedAppProxy(given), proxy.responds(to: identifier),
           let installedID = proxy.perform(identifier)?.takeUnretainedValue() as? String, installedID == given {
            return installedID
        }

        let name = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = byName[name.lowercased()], let app = byID[id.lowercased()],
           let installed = app.ids.first(where: isInstalledOnPhone) {
            return installed
        }
        guard let id = DynamicApps.id(forName: name), isInstalledOnPhone(id) else { return nil }
        return id
    }

    private static func isInstalledOnPhone(_ id: String) -> Bool {
        installedAppProxy(id) != nil
    }

    private static func installedAppProxy(_ id: String) -> NSObject? {
        let lookup = NSSelectorFromString("applicationProxyForIdentifier:")
        let installed = NSSelectorFromString("isInstalled")
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              proxyClass.responds(to: lookup),
              let proxy = proxyClass.perform(lookup, with: id)?.takeUnretainedValue() as? NSObject,
              proxy.responds(to: installed), let getter = proxy.method(for: installed) else { return nil }
        typealias IsInstalled = @convention(c) (NSObject, Selector) -> ObjCBool
        return unsafeBitCast(getter, to: IsInstalled.self)(proxy, installed).boolValue ? proxy : nil
    }
}
