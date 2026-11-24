import SwiftUI

/// Full app browser (Scheme B1): native Liquid Glass half-sheet (85% -> full on phone, centered 520x620 on wide screens)
/// with capsule search bar, category filters, 5-slot Recent card, grouped category cards, and trailing A-Z index bar.
/// Strictly zero glass-on-glass inside the sheet.
struct AllAppsBrowserSheet: View {
    var recentIDs: [String]
    var mentionedIDs: Set<String>
    var initialSearch: String = ""
    var onPick: (AppPickerEntry) -> Void
    var onClose: () -> Void

    @State private var searchText: String
    @State private var selectedCategory: AppPickerCategory = .all
    @State private var activeIndexTarget: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        recentIDs: [String],
        mentionedIDs: Set<String>,
        initialSearch: String = "",
        onPick: @escaping (AppPickerEntry) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.recentIDs = recentIDs
        self.mentionedIDs = mentionedIDs
        self.initialSearch = initialSearch
        self.onPick = onPick
        self.onClose = onClose
        _searchText = State(initialValue: initialSearch)
    }

    private var language: AppLanguage { AppLanguage.current }

    private var recentApps: [AppPickerEntry] {
        AppPickerCatalog.recentApps(limit: 5, recentIDs: recentIDs, language: language)
    }

    private var sections: [AppPickerSection] {
        AppPickerCatalog.filteredSections(query: searchText, category: selectedCategory, language: language)
    }

    private var showsRecent: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory == .all
    }

    private var indexTargets: [AppPickerIndexTarget] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return AppPickerCatalog.indexTargets(for: sections, includesRecent: showsRecent, language: language)
    }

    private var cardFill: Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color(.label).opacity(0.05)
    }

    private var surfaceFill: Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color(.label).opacity(0.06)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
                .padding(.horizontal, 18)
                .padding(.top, 12)
            categoryFilterBar
                .padding(.top, 12)
                .padding(.bottom, 8)
            contentArea
        }
        .frame(
            minWidth: sizeClass == .regular ? 520 : nil,
            idealWidth: sizeClass == .regular ? 520 : nil,
            maxWidth: sizeClass == .regular ? 520 : .infinity,
            minHeight: sizeClass == .regular ? 620 : nil,
            idealHeight: sizeClass == .regular ? 620 : nil,
            maxHeight: sizeClass == .regular ? 620 : .infinity
        )
        .modifier(SheetPresentationModifier(isRegular: sizeClass == .regular, scheme: scheme))
        .onAppear {
            if searchText.isEmpty, !initialSearch.isEmpty {
                searchText = initialSearch
            }
        }
        .onChange(of: initialSearch) { _, value in
            if !value.isEmpty { searchText = value }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appPicker.sheet")
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Choose App")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color(.label))
            Spacer(minLength: 12)
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 34, height: 34)
                    .background(surfaceFill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("appPicker.close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 16)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search apps or aliases (e.g. 12306, Bilibili)")
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.85))
            )
            .font(.subheadline)
            .foregroundStyle(Color(.label))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .accessibilityIdentifier("appPicker.search")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
                .accessibilityIdentifier("appPicker.searchClearIcon")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color(.label).opacity(0.06), lineWidth: 0.5)
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppPickerCategory.allCases) { category in
                    let selected = selectedCategory == category
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { selectedCategory = category }
                    } label: {
                        Text(verbatim: category.title)
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.white : Color(.label).opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected ? Tint.blue : surfaceFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("appPicker.filter.\(category.rawValue)")
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                if sections.isEmpty {
                    emptySearchView
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if showsRecent {
                                recentSection
                                    .id("section.recent")
                            }
                            ForEach(sections) { section in
                                categorySection(section)
                            }
                        }
                        .padding(.leading, 18)
                        .padding(.trailing, indexTargets.isEmpty ? 18 : 30)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }

                if !indexTargets.isEmpty {
                    AlphabetIndexRail(targets: indexTargets, activeID: $activeIndexTarget) { targetID in
                        withAnimation(.snappy(duration: 0.18)) {
                            proxy.scrollTo(targetID, anchor: .top)
                        }
                    }
                    .padding(.trailing, 4)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently Used")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 2)

            HStack(spacing: 4) {
                ForEach(recentApps) { app in
                    Button { onPick(app) } label: {
                        VStack(spacing: 6) {
                            AppIconView(app: app.id, size: 38, alwaysLight: true)
                            Text(verbatim: app.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(.label).opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .contentShape(.rect)
                    }
                    .buttonStyle(BrowserTileStyle(scheme: scheme))
                    .accessibilityLabel(Text(verbatim: app.displayName))
                    .accessibilityIdentifier("appPicker.recent.\(app.id)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func categorySection(_ section: AppPickerSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: section.kind.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(section.apps.enumerated()), id: \.element.id) { index, app in
                    let inserted = mentionedIDs.contains(app.id.lowercased())
                    Button { onPick(app) } label: {
                        BrowserAppRowContent(app: app, inserted: inserted, scheme: scheme)
                    }
                    .buttonStyle(BrowserRowStyle(scheme: scheme, highlighted: inserted))
                    .id(app.id)
                    .accessibilityIdentifier("appPicker.row.\(app.id)")

                    if index < section.apps.count - 1 {
                        Rectangle()
                            .fill(scheme == .dark ? Color.white.opacity(0.08) : Color(.separator).opacity(0.4))
                            .frame(height: 1 / max(1, displayScale))
                            .padding(.leading, 58)
                    }
                }
            }
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var emptySearchView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 48, height: 48)
                .background(surfaceFill, in: Circle())
            Text("No matching apps found")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(.secondaryLabel))
            Button {
                searchText = ""
                selectedCategory = .all
            } label: {
                Text("Clear Search")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPickerGlass.highlightBlue)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        scheme == .dark ? Tint.blue.opacity(0.22) : Tint.blueSoft,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appPicker.clearSearch")
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct BrowserAppRowContent: View {
    var app: AppPickerEntry
    var inserted: Bool
    var scheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app.id, size: 32, alwaysLight: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                if let subtitle = app.subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if inserted {
                Text("Inserted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPickerGlass.highlightBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        scheme == .dark ? Tint.blue.opacity(0.22) : Tint.blueSoft,
                        in: Capsule()
                    )
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.label).opacity(0.78))
                    .frame(width: 28, height: 28)
                    .background(
                        scheme == .dark ? Color.white.opacity(0.08) : Color(.label).opacity(0.06),
                        in: Circle()
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct BrowserTileStyle: ButtonStyle {
    var scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.10 : 0) : Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct BrowserRowStyle: ButtonStyle {
    var scheme: ColorScheme
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let opacity: Double = if configuration.isPressed {
            scheme == .dark ? 0.12 : 0.09
        } else if highlighted {
            scheme == .dark ? 0.05 : 0.04
        } else {
            0
        }
        configuration.label
            .background(scheme == .dark ? Color.white.opacity(opacity) : Color(.label).opacity(opacity))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AlphabetIndexRail: View {
    var targets: [AppPickerIndexTarget]
    @Binding var activeID: String?
    var onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(targets) { target in
                Text(verbatim: target.label)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(AppPickerGlass.highlightBlue)
                    .frame(width: 20, height: 14)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !targets.isEmpty else { return }
                    let slotHeight: CGFloat = 14
                    let rawIndex = Int((value.location.y - 6) / slotHeight)
                    let clamped = max(0, min(targets.count - 1, rawIndex))
                    let target = targets[clamped]
                    if activeID != target.id {
                        activeID = target.id
                        onSelect(target.targetID)
                    }
                }
                .onEnded { _ in activeID = nil }
        )
        .sensoryFeedback(.selection, trigger: activeID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Quick Index"))
        .accessibilityIdentifier("appPicker.indexRail")
    }
}

private struct SheetPresentationModifier: ViewModifier {
    var isRegular: Bool
    var scheme: ColorScheme

    func body(content: Content) -> some View {
        let base = content
            .presentationCornerRadius(34)
            .presentationBackground {
                if scheme == .dark {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Color(hex: 0x12151E).opacity(0.84)
                    }
                } else {
                    Rectangle().fill(.regularMaterial)
                }
            }
        if isRegular {
            base.presentationSizing(.fitted)
        } else {
            base
                .presentationDetents([.fraction(0.85), .large])
                .presentationDragIndicator(.visible)
        }
    }
}
