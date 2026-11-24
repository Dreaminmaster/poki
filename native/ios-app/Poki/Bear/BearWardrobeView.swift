import SwiftUI

private enum BearWardrobeTab: Int, CaseIterable {
    case headwear, clothes, outfits

    var slot: BearOutfitSlot? {
        switch self {
        case .headwear: .headwear
        case .clothes: .clothes
        case .outfits: nil
        }
    }

    var name: LocalizedStringResource { slot?.name ?? "Outfits" }
    var identifier: String { slot?.rawValue ?? "set" }
}

private struct WardrobeGrid: View {
    let slot: BearOutfitSlot?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wardrobe = BearWardrobe.shared
        let options: [BearOutfit?] = [nil] + BearOutfit.allCases.map(Optional.some)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 6)], spacing: 12) {
            ForEach(options, id: \.self) { option in
                let piece = slot.flatMap { option?.piece($0) }
                let name = piece?.name ?? option?.name ?? "No Outfit"
                let image = piece.map { "BearOutfit-\($0.asset)" } ?? option?.thumbnail ?? "BearOutfit-bare"
                let selected = slot.map { wardrobe.selection[$0] == option } ?? (wardrobe.selection == BearOutfitSelection(option))
                Button {
                    if let slot { wardrobe.selection[slot] = option }
                    else { wardrobe.selection = BearOutfitSelection(option) }
                } label: {
                    VStack(spacing: 3) {
                        tile(image: image, none: option == nil, selected: selected)
                            .padding(5)
                        Text(name)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(name))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("wardrobe.\(slot?.rawValue ?? "set").\(option?.id ?? 0)")
            }
        }
    }

    private var tileWidth: CGFloat {
        if typeSize >= .accessibility3 { return 132 }
        if typeSize.isAccessibilitySize { return 104 }
        if typeSize >= .xxLarge { return 76 }
        return 62
    }

    private func tile(image: String, none: Bool, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15)
        return ZStack {
            shape.fill(none ? Color(.secondarySystemFill) : Tint.portrait)
            if none {
                Image(systemName: "nosign").foregroundStyle(.secondary)
            } else if let thumbnail = BearWardrobe.shared.thumbnail(image) {
                Image(uiImage: thumbnail).resizable().scaledToFit().padding(.horizontal, 3).offset(y: 3)
            }
        }
        .clipShape(shape)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 60)
        .overlay {
            if selected {
                shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

struct BearCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = BearWardrobeTab.headwear
    @State private var accessibilityScrollPosition = ScrollPosition()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewSize: CGFloat {
        if verticalSizeClass == .compact { return 80 }
        return typeSize.isAccessibilitySize ? 144 : 176
    }

    var body: some View {
        NavigationStack {
            editor
                .navigationTitle(AppLocalization.text("Customize Poki"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("wardrobe.close")
                    }
                    if tab != .outfits {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Remove All", role: .destructive) {
                                BearWardrobe.shared.selection = .bare
                            }
                            .tint(.red)
                            .disabled(BearWardrobe.shared.selection == .bare)
                            .accessibilityIdentifier("wardrobe.removeAll")
                        }
                    }
                }
        }
    }

    private var editor: some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 12) {
                        header
                        BearWardrobeGridCard(tab: tab, isActive: true, scrollPosition: $accessibilityScrollPosition)
                            .padding(.horizontal, 16)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollPosition($accessibilityScrollPosition)
                .accessibilityIdentifier("wardrobe.page.\(tab.identifier)")
            } else {
                VStack(spacing: 12) {
                    header
                    TabView(selection: $tab) {
                        ForEach(BearWardrobeTab.allCases, id: \.self) { category in
                            BearWardrobeGridPage(tab: category, isActive: tab == category).tag(category)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .padding(.top, 8)
            }
        }
        .softTopEdge()
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: BearWardrobe.shared.selection)
        .background {
            LinearGradient(
                stops: [.init(color: Tint.page, location: 0), .init(color: Tint.page, location: 0.56),
                        .init(color: Color(light: 0x82AAF2, dark: 0x2E67DC), location: 1)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
        }
    }

    @ViewBuilder private var header: some View {
        PokiPortrait(mood: .ready, side: previewSize)
            .accessibilityHidden(true)

        if typeSize.isAccessibilitySize {
            equippedItems
        } else {
            // Keep the last capsule's upward exit inside its row, below the portrait.
            equippedItems
                .clipped()
        }

        categoryPicker
    }

    private var categoryPicker: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker("Outfit categories", selection: Binding(
                    get: { tab },
                    set: { next in
                        if reduceMotion { tab = next }
                        else { withAnimation { tab = next } }
                    }
                )) {
                    ForEach(BearWardrobeTab.allCases, id: \.self) { category in
                        Text(category.name).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .font(.body)
                .frame(maxWidth: 520, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("wardrobe.pieces")
            } else {
                BearWardrobeTabs(selection: $tab)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder private var equippedItems: some View {
        let selection = BearWardrobe.shared.selection
        if selection != .bare {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { equippedButtons(selection) }
                VStack(spacing: 8) { equippedButtons(selection) }
            }
            .glassGroup(spacing: 4)
            .padding(.horizontal, 16)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder private func equippedButtons(_ selection: BearOutfitSelection) -> some View {
        ForEach([BearOutfitSlot.headwear, .clothes], id: \.self) { category in
            if let outfit = selection[category] {
                equipped(outfit, slot: category)
                    .transition(.opacity)
            }
        }
    }

    private func equipped(_ outfit: BearOutfit, slot: BearOutfitSlot) -> some View {
        let piece = outfit.piece(slot)
        return Button {
            BearWardrobe.shared.selection[slot] = nil
        } label: {
            HStack(spacing: 8) {
                if let thumbnail = BearWardrobe.shared.thumbnail("BearOutfit-\(piece.asset)") {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(width: 28, height: 28)
                        .background(Tint.portrait, in: .circle)
                        .clipShape(.circle)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(slot.name).font(.caption2).foregroundStyle(.secondary)
                    Text(piece.name).font(.caption.weight(.semibold))
                }
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Capsule(), interactive: true)
        .accessibilityLabel(Text("Remove \(AppLocalization.text(piece.name))"))
        .accessibilityIdentifier("wardrobe.equipped.\(slot.rawValue)")
    }

}

private struct BearWardrobeTabs: View {
    @Binding var selection: BearWardrobeTab
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BearWardrobeTab.allCases, id: \.self) { tab in
                segment(tab)
            }
        }
        .frame(height: height)
        .background {
            GeometryReader { geometry in
                let count = BearWardrobeTab.allCases.count
                let width = geometry.size.width / CGFloat(count)
                let column = layoutDirection == .leftToRight ? selection.rawValue : count - 1 - selection.rawValue
                Color.clear
                    .frame(width: max(0, width - 8), height: max(0, geometry.size.height - 8))
                    .glassSurface(in: Capsule())
                    .position(x: width * (CGFloat(column) + 0.5), y: geometry.size.height / 2)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background(.fill.tertiary, in: Capsule())
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Outfit categories"))
        .accessibilityIdentifier("wardrobe.pieces")
    }

    private func segment(_ tab: BearWardrobeTab) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { selection = tab }
        } label: {
            Text(tab.name)
                .font(.footnote.weight(selection == tab ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier("wardrobe.tab.\(tab.identifier)")
    }
}

private struct BearWardrobeGridPage: View {
    let tab: BearWardrobeTab
    let isActive: Bool
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        ScrollView {
            BearWardrobeGridCard(tab: tab, isActive: isActive, scrollPosition: $scrollPosition)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .scrollPosition($scrollPosition)
        .accessibilityIdentifier("wardrobe.page.\(tab.identifier)")
    }
}

private struct BearWardrobeGridCard: View {
    let tab: BearWardrobeTab
    let isActive: Bool
    @Binding var scrollPosition: ScrollPosition
    @State private var headwearPalette: (outfit: BearOutfit, colors: [BearOutfitColorChannel: UIColor])?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let wardrobe = BearWardrobe.shared
        let outfit = tab.slot.flatMap { wardrobe.selection[$0] }
        VStack(alignment: .leading, spacing: 12) {
            WardrobeGrid(slot: tab.slot)

            if let slot = tab.slot, let outfit, let colors = palette(for: outfit, slot: slot), !colors.isEmpty {
                VStack(spacing: 12) {
                    Divider()
                    BearPieceColors(outfit: outfit, slot: slot, isActive: isActive,
                                    palette: colors, scrollPosition: $scrollPosition)
                }
                .id(outfit)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: outfit)
        .task(id: outfit) {
            guard tab == .headwear, let outfit,
                  let template = await wardrobe.load(outfit, for: .headwear), !Task.isCancelled else { return }
            headwearPalette = (outfit, BearDressing.originalHeadwearColors(in: template))
        }
    }

    private func palette(for outfit: BearOutfit, slot: BearOutfitSlot) -> [BearOutfitColorChannel: UIColor]? {
        if slot == .headwear { return headwearPalette?.outfit == outfit ? headwearPalette?.colors : nil }
        return Dictionary(uniqueKeysWithValues: BearOutfitColorChannel.allCases.compactMap { channel in
            outfit.defaultColors[keyPath: channel.storage].map { (channel, UIColor(hex: $0)) }
        })
    }
}

private struct BearPieceColors: View {
    let outfit: BearOutfit
    let slot: BearOutfitSlot
    let isActive: Bool
    let palette: [BearOutfitColorChannel: UIColor]
    @Binding var scrollPosition: ScrollPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var resetRowHeight: CGFloat = 45
    @State private var pendingColorReveal: UUID?
    @State private var resetRowExtendsBelowViewport = false

    private var wardrobe: BearWardrobe { .shared }
    private var hasOverrides: Bool { wardrobe[colors: slot] != BearOutfitColors() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let primary = palette[.primary] {
                picker(.primary, original: primary)
            }
            if let accent = palette[.accent] {
                if palette[.primary] != nil { Divider().padding(.leading, 12) }
                picker(.accent, original: accent)
            }
            resetRow
        }
        .font(.subheadline)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3), value: hasOverrides)
    }

    private func picker(_ channel: BearOutfitColorChannel, original: UIColor) -> some View {
        let component = channel.storage
        let color = Binding {
            Color(uiColor: wardrobe[colors: slot][keyPath: component].map { UIColor(hex: $0) } ?? original)
        } set: { color in
            guard wardrobe.selection[slot] == outfit else { return }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let rgb = [r, g, b].map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
            let value = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
            guard wardrobe[colors: slot][keyPath: component] != value else { return }
            wardrobe[colors: slot][keyPath: component] = value
            pendingColorReveal = UUID()
        }
        return ColorPicker(selection: color, supportsOpacity: false) { Text(channel.name) }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
    }

    private var resetRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.leading, 12)
            Button {
                wardrobe[colors: slot] = BearOutfitColors()
            } label: {
                Text("Reset Colors")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(.rect)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: hasOverrides ? resetRowHeight : 0, alignment: .top)
        .clipped()
        .opacity(hasOverrides ? 1 : 0)
        .allowsHitTesting(hasOverrides)
        .accessibilityHidden(!hasOverrides)
        .onGeometryChange(for: Bool.self) { geometry in
            guard let bounds = geometry.bounds(of: .scrollView(axis: .vertical)) else { return false }
            return geometry.frame(in: .scrollView(axis: .vertical)).maxY > bounds.height + 0.5
        } action: { extendsBelowViewport in
            resetRowExtendsBelowViewport = extendsBelowViewport
        }
        .task(id: isActive ? pendingColorReveal : nil) {
            guard isActive, let request = pendingColorReveal else { return }
            // Let the reset row finish expanding before determining whether it fits.
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 170 : 320)) }
            catch { return }
            guard pendingColorReveal == request else { return }
            pendingColorReveal = nil
            guard wardrobe.selection[slot] == outfit, hasOverrides, resetRowExtendsBelowViewport else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}
