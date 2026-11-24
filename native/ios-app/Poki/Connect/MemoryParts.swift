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
    var editing: String?
    /// "": a new memory is being written.
    var draft = ""
    var draftApp: String?
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
        if page.editing == item.id {
            MemoryEditor(page: page, picksApp: item.kind == .memory, onSave: { library.edit(item.id, text: page.draft, app: page.draftApp); close() }, onCancel: close)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                summary
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.open = isOpen ? nil : item.id } }
                    // Keep the row's identifier on its tappable summary only.
                    // An identifier on the enclosing VStack is inherited by
                    // descendant SwiftUI buttons and masks Memory Source.
                    .accessibilityIdentifier("memory.item.\(item.id)")
                if isOpen {
                    MemoryItemDetail(item: item, page: page)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = nil; page.open = nil }
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
                    Image(systemName: "lock.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label))
                        .accessibilityLabel(Text("Locked"))
                }
            }
            .frame(width: 18, alignment: .trailing)
        }
    }

    @ViewBuilder private var main: some View {
        switch item.kind {
        case .memory:
            Text(verbatim: item.text).font(.body).foregroundStyle(Color(.label)).lineLimit(isOpen ? nil : lines)
        case .habit:
            Text(verbatim: item.text).font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
            Text(verbatim: item.detail).font(.subheadline).foregroundStyle(Color(.label)).lineLimit(1)
        case .skill:
            Text(verbatim: item.text).font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
            if !item.detail.isEmpty {
                Text(verbatim: item.detail).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var foot: some View {
        switch item.kind {
        case .skill:
            if item.stale {
                Text("Needs redoing: stopped twice in a row, \(item.steps) steps").font(.footnote).foregroundStyle(Tint.red)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            } else {
                Text(MemoryFormat.record(item)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        case .memory, .habit:
            // caption2 is the 11 points of the design at the default size, and grows with the text.
            let source = HStack(spacing: 4) {
                Image(systemName: item.source.symbol).font(.caption2.weight(.semibold))
                    .foregroundStyle(item.source.isOwners ? Color(.label) : item.source == .unknown ? Color(.secondaryLabel) : Tint.blueText)
                Text(item.source.label).font(.footnote.weight(.semibold)).foregroundStyle(Color(.secondaryLabel)).fixedSize()
            }
            let when = Text(verbatim: item.kind == .habit ? item.reason ?? "" : MemoryFormat.day(item.updated))
                .font(.footnote).foregroundStyle(Color(.secondaryLabel))
            // At the largest text sizes the date goes under the source instead of being cut.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { source; when }
            } else {
                HStack(spacing: 4) { source; when.lineLimit(1).padding(.leading, 4) }
            }
        }
    }
}

/// What opens under an item: its facts on a grey ground, then Edit, Lock and Forget.
struct MemoryItemDetail: View {
    var item: MemoryItem
    var page: MemoryPageState
    @Environment(MemoryLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(fact.0).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).frame(width: 64, alignment: .leading)
                        fact.1.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
            HStack(spacing: 8) {
                MemoryPill(title: "Edit", symbol: "pencil") {
                    page.draft = item.text
                    page.draftApp = item.app
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page.editing = item.id }
                }
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
        let value = { (text: String) in AnyView(Text(verbatim: text).font(.subheadline).foregroundStyle(Color(.label))) }
        let source = AnyView(MemorySourceValue(item: item))
        let link = { (text: String) in AnyView(Text(verbatim: text).font(.subheadline).foregroundStyle(Tint.blueText)) }
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
            rows.append(("Steps", AnyView(Text("\(item.steps) steps").font(.subheadline).foregroundStyle(Color(.label)))))
            if item.runs > 0 {
                rows.append(("Worked", AnyView(Text("\(item.ok) of \(item.runs) times").font(.subheadline).foregroundStyle(Color(.label)))))
            }
            if let ms = item.lastMs {
                rows.append(("Last", AnyView(Text("\(Int((Double(ms) / 1000).rounded())) s").font(.subheadline).foregroundStyle(Color(.label)))))
            }
            if !item.params.isEmpty { rows.append(("Changes", value(item.params.joined(separator: AppLocalization.text("List separator"))))) }
            rows.append(("Source", AnyView(Text("\(Text(item.source.label)), \(MemoryFormat.day(item.updated))").font(.subheadline).foregroundStyle(Color(.label)))))
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
            Text(item.source.label).font(.subheadline).foregroundStyle(Color(.label))
            if let heard = item.heard {
                Button {
                    if let session = heard.session, let url = URL(string: "poki://session/\(session)") { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(heard.app.map(MemoryFormat.appName) ?? "Poki"), \(MemoryFormat.moment(heard.at))")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.subheadline)
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
                Text(verbatim: MemoryFormat.appName(app)).font(.subheadline).foregroundStyle(Color(.label))
            } else {
                Text("All Apps").font(.subheadline).foregroundStyle(Color(.label))
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
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
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

/// Writing or changing a memory: the text with its count, where it is used, Cancel and Save.
struct MemoryEditor: View {
    var page: MemoryPageState
    var placeholder: LocalizedStringKey? = nil
    var picksApp = true
    var onSave: () -> Void
    var onCancel: () -> Void
    @Environment(MemoryLibrary.self) private var library
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var page = page
        let count = page.draft.count
        let over = count > MemoryLibrary.noteLimit
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .trailing, spacing: 6) {
                TextField(placeholder ?? "", text: $page.draft, axis: .vertical)
                    .font(.body).lineLimit(1...12)
                    .focused($focused)
                    .accessibilityIdentifier("memory.editor")
                Text(verbatim: "\(count)/\(MemoryLibrary.noteLimit)")
                    .font(.caption.weight(over ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(over ? Tint.red : Color(.secondaryLabel))
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(over ? Tint.red : Tint.blueText, lineWidth: 1.5))
            scope
            HStack(spacing: 8) {
                MemoryPill(title: "Cancel", action: onCancel)
                MemoryPill(title: "Save", solid: true, action: onSave)
                    .disabled(over || page.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("memory.save")
            }
            Group {
                if over {
                    Text("Up to \(MemoryLibrary.noteLimit) characters. Remove \(count - MemoryLibrary.noteLimit) to save.").foregroundStyle(Tint.red)
                } else {
                    Text("Saving locks it: Poki won’t change this memory again.").foregroundStyle(Color(.secondaryLabel))
                }
            }
            .font(.footnote).padding(.horizontal, 2)
        }
        .onAppear { focused = true }
    }

    /// Where the memory is used: a menu of All Apps and the apps on the page. A skill's app is where it
    /// was recorded, so it is shown, not picked.
    @ViewBuilder private var scope: some View {
        let row = HStack(spacing: 12) {
            Text("Used in").font(.subheadline).foregroundStyle(Color(.secondaryLabel)).frame(width: 44, alignment: .leading)
            UsedIn(app: page.draftApp).frame(maxWidth: .infinity, alignment: .leading)
            if picksApp {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
        if picksApp {
            Menu {
                Picker(selection: Binding(get: { page.draftApp }, set: { page.draftApp = $0 })) {
                    Text("All Apps").tag(String?.none)
                    ForEach(library.apps, id: \.self) { app in
                        Label { Text(verbatim: MemoryFormat.appName(app)) } icon: { Image(uiImage: AppIconStore.shared.icon(app) ?? UIImage()) }
                            .tag(String?.some(app))
                    }
                } label: { EmptyView() }
            } label: { row }
            .buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// The Add Memory line at the end of a group.
struct MemoryAddRow: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("Add Memory").font(.body)
            }
            .foregroundStyle(Tint.blueText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("memory.add")
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
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(ink).lineLimit(1)
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
        let kind = Text(kindName).font(.footnote.weight(.semibold)).foregroundStyle(Color(.secondaryLabel))
        let who = Text("\(Text(actor)) \(MemoryFormat.time(change.at))").font(.footnote).foregroundStyle(Color(.secondaryLabel))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chip; kind; who.padding(.leading, 2) }.lineLimit(1)
            VStack(alignment: .leading, spacing: 4) { chip; Text("\(kind) \(who)") }
        }
    }

    @ViewBuilder private var words: some View {
        let full = typeSize.isAccessibilitySize
        Text(verbatim: text).font(.body)
            .foregroundStyle(change.action == .forgot && !change.undone ? Color(.secondaryLabel) : Color(.label))
            .lineLimit(full ? nil : 2)
        if let previous = change.previous {
            Text("Before: \(previous)").font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(full ? nil : 1)
        }
    }

    @ViewBuilder private var undo: some View {
        if change.undone {
            Text("Undone").font(.subheadline).foregroundStyle(Color(.secondaryLabel))
        } else if change.canUndo {
            Button("Undo") { withAnimation { library.undo(change) } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Tint.blueText).buttonStyle(.borderless)
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
                    Text("Forgot “\(change.item.text)”").font(.subheadline).foregroundStyle(Color(.label)).lineLimit(1)
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
                            Text("Undo").font(.subheadline.weight(.semibold)).foregroundStyle(Tint.blueText)
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
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
            Text(message).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).multilineTextAlignment(.center)
            if let add {
                Button(action: add) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Add Memory").font(.subheadline.weight(.semibold))
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
