import PokiCore
import SwiftUI
import UniformTypeIdentifiers

// Settings › Memory, by app (the design "Poki 记忆页设计稿", page 第二轮定稿): About You on top with the
// global memories, then a row for each app Poki knows something about; an app's page lists its
// memories, habits and skills. Recent Updates (top right, and `poki://memory/recent`) lists what was
// learned and changed. Export, Import and Clear are in the More menu. Everything here is shared by
// Poki's own chat and every connected agent; Poki Setup on the computer keeps the same file as a backup.

/// A page under Memory.
enum MemoryPage: Hashable {
    /// About You: every global memory. `open`: the item to open.
    case about(open: String? = nil)
    /// An app's memories, habits and skills; nil is Other, the skills with no app.
    case app(String?, open: String? = nil)
    /// Every item of one kind in an app, past the four its page shows.
    case all(String?, MemoryKind)
    /// Recent Updates; `highlight` is the change a conversation's "Memory updated" points at.
    case recent(highlight: String? = nil)
}

/// The page for a Memory route.
struct MemoryDestination: View {
    var page: MemoryPage
    var body: some View {
        switch page {
        case .about(let open): MemoryScopeView(scope: .about, open: open)
        case .app(let app, let open): MemoryScopeView(scope: .app(app), open: open)
        case .all(let app, let kind): MemoryScopeView(scope: .all(app, kind))
        case .recent(let highlight): MemoryRecentView(highlight: highlight)
        }
    }
}

/// Memory's first page.
struct MemoryView: View {
    var back: () -> Void
    private let library = MemoryLibrary.shared
    @State private var page = MemoryPageState()
    @State private var query = ""
    @State private var importing = false
    @State private var confirmClear = false
    @State private var exportURL: URL?
    /// About You shows this many on the first page.
    static let preview = 3

    var body: some View {
        let about = library.about
        let apps = library.apps
        List {
            if library.items.isEmpty, page.editing != "" {
                Section { MemoryEmptyCard(title: "No memories yet", message: "The preferences and habits Poki notes will appear here.", bear: true, add: startAdding) }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                MemorySearchResults(query: query, page: page)
            } else {
                Section {
                    ForEach(about.prefix(Self.preview)) { item in
                        MemoryItemRow(item: item, page: page).memorySwipes(item, page: page, library: library)
                    }
                    if about.count > Self.preview {
                        NavigationLink(value: SettingsRoute.memoryPage(.about())) { Text("All \(about.count)") }
                            .accessibilityIdentifier("memory.about.all")
                    }
                    adding
                } header: {
                    MemoryHeader("About You")
                }
                if !apps.isEmpty || !library.other.isEmpty {
                    Section {
                        ForEach(apps, id: \.self) { app in
                            NavigationLink(value: SettingsRoute.memoryPage(.app(app))) { MemoryAppRow(app: app) }
                                .accessibilityIdentifier("memory.app.\(app)")
                        }
                        if !library.other.isEmpty {
                            NavigationLink(value: SettingsRoute.memoryPage(.app(nil))) { MemoryAppRow(app: nil) }
                                .accessibilityIdentifier("memory.app.other")
                        }
                    } header: {
                        MemoryHeader("Apps")
                    }
                }
                if let message = library.message {
                    Section { Text(verbatim: message).font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
                }
            }
        }
        .navigationTitle(AppLocalization.text("Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(MemorySearch(query: $query, shown: apps.count > 8))
        .headerlessTop(library.items.isEmpty && page.editing != "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: SettingsRoute.memoryPage(.recent())) {
                    // No padding of its own: with the dot, a wider pill pushed the title off the centre.
                    // In English the page's whole name is too wide for that too, so the pill is "Recent".
                    HStack(spacing: 5) {
                        Text("Recent Updates button", comment: "The Memory page's button to Recent Updates: short, so the title stays centred")
                            .font(.subheadline.weight(.semibold)).fixedSize()
                        if library.unread { Circle().fill(Tint.blueText).frame(width: 7, height: 7) }
                    }
                }
                .accessibilityLabel(Text("Recent Updates"))
                .accessibilityIdentifier("memory.recent")
            }
            // Two shapes, as the design draws them: the Recent Updates capsule and the More circle.
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) { more }
        }
        .safeAreaInset(edge: .bottom) { MemoryUndoToast() }
        .environment(library)
        .onAppear { library.reload(); exportURL = library.exportFile() }
        .onChange(of: library.items) { exportURL = library.exportFile() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): library.importFile(url)
            case .failure(let error): library.message = error.localizedDescription
            }
        }
        .confirmationDialog("Clear all routines and notes on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Memory", role: .destructive) { library.clearAll() }
        }
    }

    /// Add Memory, or the editor while a memory is being written.
    @ViewBuilder private var adding: some View {
        if page.editing == "" {
            MemoryEditor(page: page, placeholder: "e.g., Mom is “Mama” in Contacts", onSave: {
                library.add(page.draft, app: page.draftApp)
                page.editing = nil
            }, onCancel: { page.editing = nil })
        } else {
            MemoryAddRow(action: startAdding)
        }
    }

    private func startAdding() {
        page.draft = ""
        page.draftApp = nil
        page.open = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = "" }
    }

    /// Export, Import and Clear: the earlier page's own section, now one menu.
    private var more: some View {
        Menu {
            if let exportURL {
                ShareLink(item: exportURL) { Label("Export Memory", systemImage: "square.and.arrow.up") }
            }
            Button { importing = true } label: { Label("Import Memory", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear Memory", systemImage: "trash") }
                .accessibilityIdentifier("memory.clear")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("memory.more")
    }
}

/// A group's heading on the Memory page: 17 pt semibold grey, in the words' own case.
struct MemoryHeader: View {
    var title: Text
    var trailing: Text? = nil
    init(_ title: LocalizedStringKey, trailing: Text? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }
    init(verbatim title: String) { self.title = Text(verbatim: title) }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.font(.body.weight(.semibold))
            Spacer()
            trailing?.font(.footnote)
        }
        .foregroundStyle(Color(.secondaryLabel))
        .textCase(nil)
    }
}

/// An app on the first page: its icon, its name and how many memories, habits and skills it has.
struct MemoryAppRow: View {
    var app: String?
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            if let app { AppIconView(app: app, size: 38) } else { OtherTile(size: 38) }
            VStack(alignment: .leading, spacing: 2) {
                if let app {
                    Text(verbatim: MemoryFormat.appName(app)).font(.body).foregroundStyle(Color(.label))
                } else {
                    Text("Other").font(.body).foregroundStyle(Color(.label))
                }
                Text(counts).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
            }
        }
    }

    /// "2 条记忆，1 个习惯，2 个技能": only the kinds it has.
    private var counts: String {
        let m = app == nil ? 0 : library.items(in: app, .memory).count
        let h = app == nil ? 0 : library.items(in: app, .habit).count
        let s = library.items(in: app, .skill).count
        return [
            m > 0 ? AppLocalization.text(LocalizedStringResource("\(m) memories")) : nil,
            h > 0 ? AppLocalization.text(LocalizedStringResource("\(h) habits")) : nil,
            s > 0 ? AppLocalization.text(LocalizedStringResource("\(s) skills")) : nil,
        ].compactMap { $0 }.joined(separator: AppLocalization.text(LocalizedStringResource(", ", comment: "Between the counts on an app's row")))
    }
}

/// What a search finds, by kind, each with its app's icon.
struct MemorySearchResults: View {
    var query: String
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        let found = library.search(query)
        if found.isEmpty {
            Section { Text("No results").foregroundStyle(Color(.secondaryLabel)) }
        }
        ForEach(MemoryKind.allCases, id: \.self) { kind in
            if let items = found[kind], !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        MemoryItemRow(item: item, showsApp: true, page: page).memorySwipes(item, page: page, library: library)
                    }
                } header: {
                    MemoryHeader(MemoryScope.title(kind), trailing: Text(MemoryScope.count(items.count, kind)))
                }
            }
        }
    }
}

/// About You, an app, Other, or one kind in an app.
enum MemoryScope: Hashable {
    case about
    case app(String?)
    case all(String?, MemoryKind)

    static func title(_ kind: MemoryKind) -> LocalizedStringKey {
        switch kind {
        case .memory: "Memories"
        case .habit: "Habits"
        case .skill: "Skills"
        }
    }

    /// "全部 32 条", "全部 9 个".
    static func all(_ n: Int, _ kind: MemoryKind) -> LocalizedStringKey {
        switch kind {
        case .memory: "All \(n)"
        case .habit: "All \(n) habits"
        case .skill: "All \(n) skills"
        }
    }

    static func count(_ n: Int, _ kind: MemoryKind) -> LocalizedStringKey {
        switch kind {
        case .memory: "\(n) memories"
        case .habit: "\(n) habits"
        case .skill: "\(n) skills"
        }
    }
}

/// About You, or an app's page: its memories, habits and skills, a group only when it has something.
/// Each group shows four, and the rest behind All N.
struct MemoryScopeView: View {
    var scope: MemoryScope
    var open: String? = nil
    private let library = MemoryLibrary.shared
    @State private var page = MemoryPageState()
    static let cap = 4

    var body: some View {
        List {
            switch scope {
            case .about:
                let about = library.about
                Section {
                    ForEach(about) { item in MemoryItemRow(item: item, lines: 3, page: page).memorySwipes(item, page: page, library: library) }
                    adding(app: nil)
                }
            case .app(let app):
                if app != nil { group(app, .memory) }
                group(app, .habit)
                group(app, .skill)
            case .all(let app, let kind):
                Section {
                    ForEach(library.items(in: app, kind)) { item in MemoryItemRow(item: item, page: page).memorySwipes(item, page: page, library: library) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .headerlessTop(scope.isHeaderless)
        .toolbar {
            ToolbarItem(placement: .principal) { title }
        }
        .safeAreaInset(edge: .bottom) { MemoryUndoToast() }
        .environment(library)
        .onAppear { if let open, page.open == nil { page.open = open } }
    }

    @ViewBuilder private var title: some View {
        switch scope {
        case .about:
            Text("About You").font(.headline)
        case .app(let app), .all(let app, _):
            HStack(spacing: 7) {
                if let app {
                    AppIconView(app: app, size: 24)
                    Text(verbatim: MemoryFormat.appName(app)).font(.headline).lineLimit(1)
                } else {
                    Text("Other").font(.headline)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// One kind's group: nothing at all when it is empty (no blank block).
    @ViewBuilder private func group(_ app: String?, _ kind: MemoryKind) -> some View {
        let items = library.items(in: app, kind)
        if !items.isEmpty {
            Section {
                ForEach(items.prefix(Self.cap)) { item in MemoryItemRow(item: item, page: page).memorySwipes(item, page: page, library: library) }
                if items.count > Self.cap {
                    NavigationLink(value: SettingsRoute.memoryPage(.all(app, kind))) { Text(MemoryScope.all(items.count, kind)) }
                }
                if kind == .memory { adding(app: app) }
            } header: {
                MemoryHeader(MemoryScope.title(kind))
            }
            .accessibilityIdentifier("memory.group.\(kind.rawValue)")
        }
    }

    @ViewBuilder private func adding(app: String?) -> some View {
        if page.editing == "" {
            MemoryEditor(page: page, placeholder: "e.g., Mom is “Mama” in Contacts", onSave: {
                library.add(page.draft, app: page.draftApp)
                page.editing = nil
            }, onCancel: { page.editing = nil })
        } else {
            MemoryAddRow {
                page.draft = ""
                page.draftApp = app
                page.open = nil
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = "" }
            }
        }
    }
}

/// Recent Updates: what Poki, Dream and you added, edited and forgot, newest first, by day. A line
/// opens its item; Undo puts a change back.
struct MemoryRecentView: View {
    var highlight: String? = nil
    private let library = MemoryLibrary.shared
    @State private var filter: MemoryChange.Action?
    @State private var seen: String?

    var body: some View {
        let shown = library.changes.filter { filter == nil || $0.action == filter }
        List {
            if library.changes.isEmpty {
                Section { MemoryEmptyCard(title: "No updates yet", message: "What is added, edited and forgotten will appear here.") }
            } else {
                ForEach(days(shown), id: \.0) { day, changes in
                    Section {
                        ForEach(changes) { change in line(change) }
                    } header: {
                        MemoryHeader(verbatim: day)
                    }
                }
            }
        }
        // The filter stays under the bar while the days scroll under it.
        .topBar {
            if !library.changes.isEmpty {
                Picker("Show", selection: $filter) {
                    Text("All").tag(MemoryChange.Action?.none)
                    Text("New").tag(MemoryChange.Action?.some(.added))
                    Text("Edited").tag(MemoryChange.Action?.some(.edited))
                    Text("Forgotten").tag(MemoryChange.Action?.some(.forgot))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(AppLocalization.text("Recent Updates"))
        .navigationBarTitleDisplayMode(.inline)
        .headerlessTop(library.changes.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: filter)
        .environment(library)
        .onAppear { library.markSeen() }
        // Once you have gone on from here, the change you came for is no longer lit.
        .onDisappear { seen = highlight }
    }

    @ViewBuilder private func line(_ change: MemoryChange) -> some View {
        let lit = change.id == highlight && seen != change.id
        if change.action != .forgot || change.undone, library.item(change.item.id) != nil {
            // The whole line opens the item where it lives; no chevron, as the design draws it.
            NavigationLink(value: SettingsRoute.memoryPage(change.item.kind == .memory && change.item.app == nil
                                                           ? .about(open: change.item.id) : .app(change.item.app, open: change.item.id))) {
                MemoryChangeRow(change: change, highlighted: lit)
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .listRowBackground(lit ? Tint.blueSoft : Color(.secondarySystemGroupedBackground))
        } else {
            MemoryChangeRow(change: change, highlighted: lit)
                .listRowBackground(lit ? Tint.blueSoft : Color(.secondarySystemGroupedBackground))
        }
    }

    /// Today, Yesterday, then the date.
    private func days(_ changes: [MemoryChange]) -> [(String, [MemoryChange])] {
        let cal = Calendar.current
        var out: [(String, [MemoryChange])] = []
        for change in changes.sorted(by: { $0.at > $1.at }) {
            let name = cal.isDateInToday(change.at) ? AppLocalization.text("Today")
                : cal.isDateInYesterday(change.at) ? AppLocalization.text("Yesterday") : MemoryFormat.day(change.at)
            if out.last?.0 == name { out[out.count - 1].1.append(change) } else { out.append((name, [change])) }
        }
        return out
    }
}

// MARK: Swipes

extension View {
    /// Swipe left for Edit and Forget (a full swipe forgets), right for Lock or Unlock when locks are kept.
    func memorySwipes(_ item: MemoryItem, page: MemoryPageState, library: MemoryLibrary) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { MemoryForget.run(item.id, library: library) } label: { Label("Forget", systemImage: "trash") }
            Button {
                page.draft = item.text
                page.draftApp = item.app
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = item.id }
            } label: { Label("Edit", systemImage: "pencil") }
                .tint(Color(.systemGray))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { withAnimation { library.setLocked(item.id, !item.locked) } } label: {
                Label(item.locked ? "Unlock" : "Lock", systemImage: item.locked ? "lock.open" : "lock.fill")
            }
            .tint(Tint.blue)
        }
    }
}

/// The search field, only past 8 apps (the design's rule): with fewer, the system's drawer would show
/// it whenever the page comes back into view.
private struct MemorySearch: ViewModifier {
    @Binding var query: String
    var shown: Bool

    func body(content: Content) -> some View {
        Group {
            if shown {
                content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            } else {
                content
            }
        }
        .onChange(of: shown) { _, now in if !now { query = "" } }
    }
}

extension MemoryScope {
    /// About You's page and an "All" page list one card with no heading over it.
    var isHeaderless: Bool {
        switch self {
        case .about, .all: true
        case .app: false
        }
    }
}

extension View {
    /// A list whose first card has no heading starts that card just under the bar, as the design draws it,
    /// instead of under the room a heading would take.
    func headerlessTop(_ headerless: Bool) -> some View {
        contentMargins(.top, headerless ? 4 : nil, for: .scrollContent)
    }
}
