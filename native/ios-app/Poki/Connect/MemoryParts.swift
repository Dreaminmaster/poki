import SwiftUI

// The Memory page's pieces, after the design "Poki 记忆页设计稿" (Paper, page 第二轮定稿, the
// generator's ui.mjs): an item's row, what opens under it, the editor, a Recent Updates line, the toast
// that undoes a forget, and the empty card. Sizes are the design's (17 / 15 / 13 pt text, 30 pt icons,
// 42 pt pills, 16 pt inner corners) on the system's Dynamic Type styles and Poki's Tint colours.

/// The lines of a list that make up one page of the Memory page: rows open and close in place, one at a
/// time, and one at a time is being edited.
@MainActor @Observable
final class MemoryPageState {
    var open: String?
    /// The item the editor sheet is open on; "" is a new memory.
    var editing: String?
    var draft = ""
    var draftApp: String?
    /// Whether Poki may change the item after it is saved. On by default: the words are now the owner's.
    var draftLocked = true

    /// Opens the editor on `item`, or on a new memory used in `app`.
    func start(_ item: MemoryItem?, app: String? = nil) {
        draft = item?.text ?? ""
        draftApp = item?.app ?? app
        draftLocked = true
        if item == nil { open = nil }
        editing = item?.id ?? ""
    }
}

// MARK: Rows

/// An item: a memory's text, a habit's what and when, a skill's name and description; under it where it
/// came from, or a skill's record; a lock at the end when it is locked.
struct MemoryItemRow: View {
    var item: MemoryItem
    /// The app's icon before the text (search results).
    var showsApp = false
    /// Lines of a memory's text before it is cut (About You's own page shows 3).
    var lines = 2
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isOpen: Bool { page.open == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
                .contentShape(.rect)
                .onTapGesture { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.open = isOpen ? nil : item.id } }
            if isOpen {
                MemoryItemDetail(item: item, page: page)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityIdentifier("memory.item.\(item.id)")
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsApp {
                if let app = item.app { AppIconView(app: app, size: 30) } else { AboutTile(size: 30) }
            }
            VStack(alignment: .leading, spacing: 3) {
                main
                // Open, a skill that needs redoing still says so; the rest show it in the facts below.
                if !isOpen || (item.kind == .skill && item.stale) { foot }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if item.locked {
                    Image(systemName: "lock.fill").font(.allo(.subheadline, .semibold)).foregroundStyle(Color(.label))
                        .accessibilityLabel(Text("Locked"))
                }
            }
            .frame(width: 18, alignment: .trailing)
        }
    }

    @ViewBuilder private var main: some View {
        switch item.kind {
        case .memory:
            Text(verbatim: item.text).font(.allo(.body)).foregroundStyle(Color(.label)).lineLimit(isOpen ? nil : lines)
        case .habit:
            Text(verbatim: item.text).font(.allo(.body, .semibold)).foregroundStyle(Color(.label)).lineLimit(1)
            Text(verbatim: item.detail).font(.allo(.subheadline)).foregroundStyle(Color(.label)).lineLimit(1)
        case .skill:
            Text(verbatim: item.text).font(.allo(.body, .semibold)).foregroundStyle(Color(.label)).lineLimit(1)
            if !item.detail.isEmpty {
                Text(verbatim: item.detail).font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var foot: some View {
        switch item.kind {
        case .skill:
            if item.stale {
                Text("Needs redoing: stopped twice in a row, \(item.steps) steps").font(.allo(.footnote)).foregroundStyle(Tint.red)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            } else {
                Text(MemoryFormat.record(item)).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        case .memory, .habit:
            // caption2 is the 11 points of the design at the default size, and grows with the text.
            let source = HStack(spacing: 4) {
                Image(systemName: item.source.symbol).font(.allo(.caption2, .semibold))
                    .foregroundStyle(item.source.isOwners ? Color(.label) : item.source == .unknown ? Color(.secondaryLabel) : Tint.blueText)
                Text(item.source.label).font(.allo(.footnote, .semibold)).foregroundStyle(Color(.secondaryLabel)).fixedSize()
            }
            let when = Text(verbatim: item.kind == .habit ? item.reason ?? "" : MemoryFormat.day(item.updated))
                .font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
            // At the largest text sizes the date goes under the source instead of being cut.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { source; when }
            } else {
                HStack(spacing: 4) { source; when.lineLimit(1).padding(.leading, 4) }
            }
        }
    }
}

/// What opens under an item: its facts as plain lines in the row itself (no card inside the card), then
/// Edit, Lock and Forget.
struct MemoryItemDetail: View {
    var item: MemoryItem
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The labels' column is as wide as its widest label, and a label never breaks ("Used in" did at 44 pt).
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.0).font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel)).fixedSize()
                        fact.1.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 2)
            HStack(spacing: 8) {
                MemoryPill(title: "Edit", symbol: "pencil") { page.start(item) }
                .accessibilityIdentifier("memory.edit")
                MemoryPill(title: item.locked ? "Unlock" : "Lock", symbol: item.locked ? "lock.open" : "lock.fill") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { library.setLocked(item.id, !item.locked) }
                }
                .accessibilityIdentifier("memory.lock")
                MemoryPill(title: "Forget", symbol: "trash", tint: Tint.red) { MemoryForget.run(item.id, library: library) }
                    .accessibilityIdentifier("memory.forget")
            }
        }
    }

    /// The rows of facts. A memory shows where it came from, never a reason (decided 2026-11-18).
    private var facts: [(LocalizedStringKey, AnyView)] {
        let value = { (text: String) in AnyView(Text(verbatim: text).font(.allo(.subheadline)).foregroundStyle(Color(.label))) }
        let source = AnyView(MemorySourceValue(item: item))
        let link = { (text: String) in AnyView(Text(verbatim: text).font(.allo(.subheadline)).foregroundStyle(Tint.blueText)) }
        switch item.kind {
        case .memory:
            return [("Source", source), ("Updated", value(MemoryFormat.moment(item.updated))), ("Used in", AnyView(UsedIn(app: item.app)))]
        case .habit:
            var rows: [(LocalizedStringKey, AnyView)] = [("Source", source)]
            if let reason = item.reason { rows.append(("Reason", value(reason))) }
            if let skill = item.linkedSkill { rows.append(("Skill", link(skill))) }
            if let memory = item.linkedMemory { rows.append(("Memory", link(memory))) }
            rows.append(("Updated", value(MemoryFormat.moment(item.updated))))
            return rows
        case .skill:
            var rows: [(LocalizedStringKey, AnyView)] = []
            if !item.otherApps.isEmpty {
                rows.append(("Also uses", value(item.otherApps.map(MemoryFormat.appName).joined(separator: AppLocalization.text("List separator")))))
            }
            if item.stale, let stop = item.stop { rows.append(("Stopped at", value(stop))) }
            rows.append(("Steps", AnyView(Text("\(item.steps) steps").font(.allo(.subheadline)).foregroundStyle(Color(.label)))))
            if item.runs > 0 {
                rows.append(("Worked", AnyView(Text("\(item.ok) of \(item.runs) times").font(.allo(.subheadline)).foregroundStyle(Color(.label)))))
            }
            if item.fixes > 0 {
                rows.append(("Fixed", AnyView(Text("\(item.fixes) steps").font(.allo(.subheadline)).foregroundStyle(Color(.label)))))
            }
            if let ms = item.lastMs {
                rows.append(("Last", AnyView(Text("\(Int((Double(ms) / 1000).rounded())) s").font(.allo(.subheadline)).foregroundStyle(Color(.label)))))
            }
            if !item.params.isEmpty { rows.append(("Changes", value(item.params.joined(separator: AppLocalization.text("List separator"))))) }
            rows.append(("Source", AnyView(Text("\(Text(item.source.label)), \(MemoryFormat.day(item.updated))").font(.allo(.subheadline)).foregroundStyle(Color(.label)))))
            return rows
        }
    }
}

/// How an item came to be and, under it, the conversation it was heard in: a link back to it.
struct MemorySourceValue: View {
    var item: MemoryItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.source.label).font(.allo(.subheadline)).foregroundStyle(Color(.label))
            if let heard = item.heard {
                Button {
                    if let session = heard.session, let url = URL(string: "poki://session/\(session)") { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(heard.app.map(MemoryFormat.appName) ?? "Poki"), \(MemoryFormat.moment(heard.at))")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.allo(.subheadline))
                    .foregroundStyle(Tint.blueText)
                }
                .buttonStyle(.plain)
                .disabled(heard.session == nil)
                .accessibilityIdentifier("memory.source.conversation")
            }
        }
    }
}

/// The app a memory is used in: its icon and name, or All Apps.
struct UsedIn: View {
    var app: String?
    var body: some View {
        HStack(spacing: 6) {
            if let app {
                AppIconView(app: app, size: 20)
                Text(verbatim: MemoryFormat.appName(app)).font(.allo(.subheadline)).foregroundStyle(Color(.label))
            } else {
                Text("All Apps").font(.allo(.subheadline)).foregroundStyle(Color(.label))
            }
        }
    }
}

/// A grey capsule (TaskCard's quiet capsule), or Poki's blue one for Save.
struct MemoryPill: View {
    var title: LocalizedStringKey
    var symbol: String? = nil
    var tint: Color = Color(.label)
    var solid = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.allo(.subheadline, .semibold)).lineLimit(1)
            }
            .foregroundStyle(solid ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 42)
            // A solid pill that cannot be pressed pales its ground only, as the design draws it: faded
            // whole, its white words all but vanished into the pale blue.
            .background(solid ? Tint.blue.opacity(isEnabled ? 1 : 0.25) : Color(.tertiarySystemFill), in: .capsule)
            .opacity(solid || isEnabled ? 1 : 0.3)
        }
        // Not `.plain`: that halves a disabled button whole, words and all.
        .buttonStyle(PressedDimStyle())
    }
}

/// Writing or changing a memory (or renaming a skill), in a sheet: one Form, its own sections, nothing
/// boxed inside another box. The words, where they are used, and whether Poki may change them later:
/// the three things that make a memory useful to Poki (what it knows, when it applies, who owns it).
struct MemoryEditor: View {
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library
    @FocusState private var focused: Bool

    private var item: MemoryItem? { page.editing.flatMap { $0.isEmpty ? nil : library.item($0) } }
    /// A skill's app is where it was recorded, so it is shown, not picked.
    private var picksApp: Bool { item.map { $0.kind == .memory } ?? true }

    var body: some View {
        @Bindable var page = page
        let count = page.draft.count
        let limit = MemoryLibrary.noteLimit
        let over = count > limit
        let empty = page.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        NavigationStack {
            Form {
                Section {
                    TextField(item == nil ? LocalizedStringKey("e.g., Mom is “Mama” in Contacts") : LocalizedStringKey(""), text: $page.draft, axis: .vertical)
                        .lineLimit(3...12)
                        .focused($focused)
                        .accessibilityIdentifier("memory.editor")
                } footer: {
                    Group {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if over {
                                Text("Up to \(limit) characters. Remove \(count - limit) to save.").foregroundStyle(Tint.red)
                            }
                            Spacer(minLength: 0)
                            Text(verbatim: "\(count)/\(limit)").monospacedDigit().foregroundStyle(over ? Tint.red : Color(.secondaryLabel))
                        }
                    }
                    .settingsFooter()
                }
                Section {
                    if picksApp {
                        NavigationLink {
                            MemoryAppPicker(selection: $page.draftApp)
                        } label: {
                            LabeledContent { UsedIn(app: page.draftApp) } label: { Text("Used in").lineLimit(1) }
                        }
                        .accessibilityIdentifier("memory.usedIn")
                    } else {
                        LabeledContent { UsedIn(app: page.draftApp) } label: { Text("Used in").lineLimit(1) }
                    }
                    Toggle("Locked", isOn: $page.draftLocked)
                        .accessibilityIdentifier("memory.editor.lock")
                } footer: {
                    Group {
                        // Two Texts, not one with a ternary: a ternary's words are a String and skip the catalog.
                        if page.draftLocked {
                            Text("Poki won’t change or forget it while it is locked.")
                        } else {
                            Text("Poki can update it when it learns something new.")
                        }
                    }
                    .settingsFooter()
                }
            }
            .navigationTitle(AppLocalization.text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { page.editing = nil } }
                // Plain, not the prominent confirmation style: no blue ground under white words.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(over || empty)
                        .accessibilityIdentifier("memory.save")
                }
            }
        }
        .onAppear { focused = true }
    }

    private var title: LocalizedStringResource {
        switch item?.kind {
        case nil: "New Memory"
        case .skill: "Edit Skill"
        case .habit: "Edit Habit"
        case .memory: "Edit Memory"
        }
    }

    private func save() {
        if let id = page.editing, !id.isEmpty {
            library.edit(id, text: page.draft, app: page.draftApp, locked: page.draftLocked)
        } else {
            library.add(page.draft, app: page.draftApp, locked: page.draftLocked)
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = nil; page.open = nil }
    }
}

extension View {
    /// The editor's sheet, open while `page.editing` is set.
    func memoryEditorSheet(_ page: MemoryPageState) -> some View {
        sheet(isPresented: Binding(get: { page.editing != nil }, set: { if !$0 { page.editing = nil } })) {
            MemoryEditor(page: page)
                .environment(MemoryLibrary.shared)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Where a memory is used: All Apps, the apps Poki already keeps something for, then every app on this
/// iPhone, A to Z, with search. The earlier menu listed only the apps that already had memories, so a
/// memory could never be put under a new app.
struct MemoryAppPicker: View {
    @Binding var selection: String?
    @Environment(MemoryLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let known = library.apps
        let knownIDs = Set(known.map { $0.lowercased() })
        let rest = Self.everyApp().filter { !knownIDs.contains($0.lowercased()) }
        let q = query.trimmingCharacters(in: .whitespaces)
        List {
            if q.isEmpty {
                Section {
                    row(nil)
                } footer: {
                    Group {
                        Text("Poki keeps it in mind in every app.")
                    }
                    .settingsFooter()
                }
                if !known.isEmpty {
                    Section { ForEach(known, id: \.self) { row($0) } } header: {
                        Group {
     Text("With Memories") 
                        }
                        .settingsHeader()
                    }
                }
                if !rest.isEmpty {
                    Section { ForEach(rest, id: \.self) { row($0) } } header: {
                        Group {
     Text("On This iPhone") 
                        }
                        .settingsHeader()
                    }
                }
            } else {
                let found = (known + rest).filter { MemoryFormat.appName($0).localizedCaseInsensitiveContains(q) || $0.localizedCaseInsensitiveContains(q) }
                if found.isEmpty {
                    Text("No results").foregroundStyle(Color(.secondaryLabel))
                } else {
                    ForEach(found, id: \.self) { row($0) }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(AppLocalization.text("Used in"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ app: String?) -> some View {
        Button {
            selection = app
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if let app { AppIconView(app: app, size: 29) } else { AboutTile(size: 29) }
                Group {
                    if let app { Text(verbatim: MemoryFormat.appName(app)) } else { Text("All Apps") }
                }
                .foregroundStyle(Color(.label))
                .frame(maxWidth: .infinity, alignment: .leading)
                if selection?.lowercased() == app?.lowercased() {
                    Image(systemName: "checkmark").font(.allo(.body, .semibold)).foregroundStyle(Tint.blueText)
                        .accessibilityLabel(Text("Selected"))
                }
            }
        }
        .accessibilityIdentifier("memory.usedIn.\(app ?? "all")")
    }

    /// The apps installed on this iPhone (the phone's own list) and the Apple apps Poki knows, which
    /// that list counts as System apps (Contacts, Messages). Before the list has ever been read, every
    /// app Poki knows by name. Sorted by the name shown.
    static func everyApp() -> [String] {
        let installed = DynamicApps.userApps.map(\.id)
        let known = KnownApps.all.map(\.id).filter { id in
            installed.isEmpty || id.hasPrefix("com.apple.") || DynamicApps.name(forID: id) != nil
        }
        var seen = Set<String>()
        let apps = (installed + known).filter { seen.insert($0.lowercased()).inserted }
        return apps.sorted { MemoryFormat.appName($0).localizedStandardCompare(MemoryFormat.appName($1)) == .orderedAscending }
    }
}

/// The Add Memory line at the end of a group.
struct MemoryAddRow: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("Add Memory").font(.allo(.body))
            }
            .foregroundStyle(Tint.blueText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("memory.add")
    }
}

/// An area's memories as one page (the owner, Nov 20 2026: not a list of rows): its summary, then
/// its lines as the page's text, each line opening where it came from with Edit, Lock and Forget.
struct MemoryPageCard: View {
    var app: String?
    /// Lines shown; the rest are behind All N.
    var limit: Int? = nil
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        let lines = library.pageLines(app)
        VStack(alignment: .leading, spacing: 10) {
            if let summary = library.pageSummary(app) {
                Text(verbatim: summary).font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel))
            }
            ForEach(limit.map { Array(lines.prefix($0)) } ?? lines) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: item.text).font(.allo(.body)).foregroundStyle(Color(.label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.locked {
                            Image(systemName: "lock.fill").font(.allo(.caption, .semibold)).foregroundStyle(Color(.secondaryLabel))
                                .accessibilityLabel(Text("Locked"))
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.open = page.open == item.id ? nil : item.id }
                    }
                    if page.open == item.id {
                        MemoryItemDetail(item: item, page: page)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .accessibilityIdentifier("memory.item.\(item.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("memory.page.\(app ?? "about")")
    }
}

/// Writing a whole page at once, one fact a line, like opening a memory file: the lines kept keep
/// where they came from, the new ones are yours, and a line taken out is forgotten.
struct MemoryPageEditor: View {
    var app: String?
    @Environment(MemoryLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var locked = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("One thing to remember on each line", text: $text, axis: .vertical)
                        .lineLimit(6...30)
                        .focused($focused)
                        .accessibilityIdentifier("memory.pageEditor")
                } footer: {
                    Group {
                        Text("Each line is one memory. Remove a line to forget it.")
                    }
                    .settingsFooter()
                }
                Section {
                    Toggle("Locked", isOn: $locked)
                } footer: {
                    Group {
                        if locked {
                            Text("Poki won’t change this page while it is locked.")
                        } else {
                            Text("Poki can rewrite this page as it learns, but never a line you locked.")
                        }
                    }
                    .settingsFooter()
                }
            }
            .navigationTitle(app.map { Text(verbatim: MemoryFormat.appName($0)) } ?? Text("About You"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        library.writePage(app, text: text, locked: locked)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("memory.pageEditor.save")
                }
            }
        }
        .onAppear {
            text = library.pageLines(app).map(\.text).joined(separator: "\n")
            locked = library.pageLocked(app)
            focused = true
        }
    }
}

/// Edit Page at the end of a page.
struct MemoryPageEditRow: View {
    var app: String?
    @State private var editing = false
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 16, weight: .semibold))
                Text("Edit Page").font(.allo(.body))
            }
            .foregroundStyle(Tint.blueText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("memory.editPage")
        .sheet(isPresented: $editing) {
            MemoryPageEditor(app: app).environment(library).presentationDetents([.large])
        }
    }
}

/// Changing memory by telling Poki: opens the chat with the start of a message ("Remember that"), so
/// the owner can add, correct or drop a memory in their own words, the way the big assistants take
/// "remember that" and "forget that". Poki's memory tool keeps or forgets the note, and Recent Updates
/// shows it with Undo.
struct MemoryChatRow: View {
    var app: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            var link = URLComponents()
            link.scheme = "poki"
            link.host = "chat"
            link.queryItems = [URLQueryItem(name: "text", value: prompt)]
            if let url = link.url { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left").font(.system(size: 16, weight: .semibold))
                Text("Tell Poki in Chat").font(.allo(.body))
            }
            .foregroundStyle(Tint.blueText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("memory.chat")
    }

    private var prompt: String {
        if let app {
            return AppLocalization.text(LocalizedStringResource("In \(MemoryFormat.appName(app)), remember that ", comment: "The start of a chat message from the Memory page"))
        }
        return AppLocalization.text(LocalizedStringResource("Remember that ", comment: "The start of a chat message from the Memory page"))
    }
}

/// About You's square in place of an app icon.
struct AboutTile: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "person").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(Tint.blueText)
            .frame(width: size, height: size)
            .background(Tint.blueSoft, in: .rect(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Other's square: skills with no app.
struct OtherTile: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "square.grid.2x2").font(.system(size: size * 0.5)).foregroundStyle(Color(.secondaryLabel))
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small coloured tag: New, Edited, Forgotten.
struct MemoryChip: View {
    var title: LocalizedStringKey
    var ground: Color
    var ink: Color
    var body: some View {
        // Its own size: at the largest text sizes a row's line was cutting the ground under the words.
        Text(title).font(.allo(.caption, .semibold)).foregroundStyle(ink).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1).frame(minHeight: 20).fixedSize()
            .background(ground, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

// MARK: Recent Updates

/// A line of Recent Updates: what changed, what kind, who and when, the text, what it was before, Undo.
struct MemoryChangeRow: View {
    var change: MemoryChange
    var highlighted = false
    @Environment(MemoryLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The icon grows with the text, up to half again.
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // The largest sizes: one column, the words in full, Undo under them.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        icon
                        if highlighted { Circle().fill(Tint.blueText).frame(width: 8, height: 8) }
                    }
                    meta
                    words
                    undo
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        icon.padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            meta
                            words
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if highlighted { Circle().fill(Tint.blueText).frame(width: 8, height: 8) }
                    undo
                }
            }
        }
        .accessibilityIdentifier("memory.change.\(change.id)")
    }

    @ViewBuilder private var icon: some View {
        let size = min(iconSize, 45)
        if let app = change.item.app { AppIconView(app: app, size: size) }
        else if change.item.kind == .memory { AboutTile(size: size) }
        else { OtherTile(size: size) }
    }

    /// What happened, to which kind, by whom and when: one line, or the chip above the rest when they
    /// do not fit.
    private var meta: some View {
        let kind = Text(kindName).font(.allo(.footnote, .semibold)).foregroundStyle(Color(.secondaryLabel))
        let who = Text("\(Text(actor)) \(MemoryFormat.time(change.at))").font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chip; kind; who.padding(.leading, 2) }.lineLimit(1)
            VStack(alignment: .leading, spacing: 4) { chip; Text("\(kind) \(who)") }
        }
    }

    @ViewBuilder private var words: some View {
        let full = typeSize.isAccessibilitySize
        Text(verbatim: text).font(.allo(.body))
            .foregroundStyle(change.action == .forgot && !change.undone ? Color(.secondaryLabel) : Color(.label))
            .lineLimit(full ? nil : 2)
        if let previous = change.previous {
            Text("Before: \(previous)").font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(full ? nil : 1)
        }
    }

    @ViewBuilder private var undo: some View {
        if change.undone {
            Text("Undone").font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel))
        } else if change.canUndo {
            Button("Undo") { withAnimation { library.undo(change) } }
                .font(.allo(.subheadline, .semibold)).foregroundStyle(Tint.blueText).buttonStyle(.borderless)
                .accessibilityIdentifier("memory.change.undo")
        }
    }

    private var text: String {
        change.item.kind == .habit ? AppLocalization.text(LocalizedStringResource("\(change.item.text), \(change.item.detail)", comment: "A habit's what and when")) : change.item.text
    }

    @ViewBuilder private var chip: some View {
        switch change.action {
        case .added: MemoryChip(title: "New", ground: Tint.blueSoft, ink: Tint.blueText)
        case .edited: MemoryChip(title: "Edited", ground: Tint.amberSoft, ink: Tint.amberInk)
        case .forgot: MemoryChip(title: "Forgotten", ground: Tint.redSoft, ink: Tint.redInk)
        }
    }

    private var kindName: LocalizedStringKey {
        switch change.item.kind {
        case .memory: "Memory"
        case .habit: "Habit"
        case .skill: "Skill"
        }
    }

    private var actor: LocalizedStringKey {
        switch change.actor {
        case .poki: "Poki"
        case .dream: "Dream"
        case .owner: "You"
        }
    }
}

// MARK: Forget and undo

/// Forgetting from a row or a swipe: the row closes and the toast offers Undo for 5 seconds.
enum MemoryForget {
    @MainActor static func run(_ id: String, library: MemoryLibrary) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { library.forget(id) }
    }
}

/// The toast under a page after a forget: what was forgotten, and Undo inside a ring that runs out in 5
/// seconds. Its entrance and exit follow Motion+'s "Toast: Notifications list" (a spring up from the
/// bottom); its ground is the menus' white, and Undo is Poki's blue (the design).
struct MemoryUndoToast: View {
    @Environment(MemoryLibrary.self) private var library
    @State private var left: CGFloat = 1
    static let seconds = 5.0

    var body: some View {
        Group {
            if let change = library.lastForgotten {
                HStack(spacing: 10) {
                    Text("Forgot “\(change.item.text)”").font(.allo(.subheadline)).foregroundStyle(Color(.label)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { library.undo(change) }
                    } label: {
                        HStack(spacing: 7) {
                            ZStack {
                                Circle().stroke(Tint.blueText.opacity(0.22), lineWidth: 2.4)
                                Circle().trim(from: 0, to: left).stroke(Tint.blueText, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 17, height: 17)
                            Text("Undo").font(.allo(.subheadline, .semibold)).foregroundStyle(Tint.blueText)
                        }
                        .padding(.leading, 9).padding(.trailing, 12).frame(minHeight: 38)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memory.toast.undo")
                }
                .padding(.leading, 18).padding(.trailing, 8).frame(minHeight: 54)
                .background(Color(.tertiarySystemBackground), in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .id(change.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: change.id) {
                    left = 1
                    withAnimation(.linear(duration: Self.seconds)) { left = 0 }
                    try? await Task.sleep(for: .seconds(Self.seconds))
                    guard !Task.isCancelled, library.lastForgotten?.id == change.id else { return }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { library.settleForgotten() }
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: library.lastForgotten?.id)
    }
}

// MARK: Empty

/// The card in place of an empty list: the bear (on the home page), what will be here, and Add Memory.
struct MemoryEmptyCard: View {
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var bear = false
    var add: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            if bear, let image = UIImage(named: "ActivityBear-ready") {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 60, height: 60)
                    .frame(width: 72, height: 72)
                    .background(RadialGradient(colors: [Tint.blueText.opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: 36), in: .circle)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
            }
            Text(title).font(.allo(.body, .semibold)).foregroundStyle(Color(.label))
            Text(message).font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel)).multilineTextAlignment(.center)
            if let add {
                Button(action: add) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Add Memory").font(.allo(.subheadline, .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 22).frame(minHeight: 44)
                    .background(Tint.blue, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .accessibilityIdentifier("memory.add")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 26)
    }
}

// MARK: Words

@MainActor enum MemoryFormat {
    static func appName(_ app: String) -> String { AppIconStore.name(app) ?? app }

    /// "11月16日", "Nov 16".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(AppLocalization.locale))
    }

    /// "11月18日 上午2:10".
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(AppLocalization.locale))
    }

    /// "下午2:02".
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale))
    }

    /// "8 步，成功 3/3，上次 41 秒", or "6 步，还没运行过".
    static func record(_ item: MemoryItem) -> LocalizedStringKey {
        if item.runs == 0 { return "\(item.steps) steps, not run yet" }
        let seconds = Int((Double(item.lastMs ?? 0) / 1000).rounded())
        return "\(item.steps) steps, worked \(item.ok)/\(item.runs), last \(seconds) s"
    }
}
