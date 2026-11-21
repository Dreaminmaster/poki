import SwiftUI

struct BearWardrobeSheet: View {
    @Binding var mixing: Bool
    let showSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detent = Self.quick
    @State private var rootDetent = Self.quick
    @State private var navigationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var quick: PresentationDetent { .fraction(0.68) }

    var body: some View {
        NavigationStack {
            quickOutfits
                .navigationTitle(AppLocalization.text("Outfits"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("wardrobe.close")
                    }
                }
                .navigationDestination(isPresented: $mixing) {
                    BearMixView()
                        .navigationTitle(AppLocalization.text("Mix and Match"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
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
        .presentationDetents([Self.quick, .large], selection: $detent)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .onChange(of: mixing) { _, showing in
            guard !showing else { return }
            navigationTask?.cancel()
            navigationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 300))
                guard !Task.isCancelled, !mixing else { return }
                detent = rootDetent
            }
        }
        .onDisappear { navigationTask?.cancel() }
    }

    private var quickOutfits: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Current outfit: \(BearWardrobe.shared.selection.displayName)")
                    .font(.allo(.subheadline))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wardrobe.current")

                WardrobeGrid(slot: nil)

                VStack(spacing: 0) {
                    Button {
                        rootDetent = detent
                        navigationTask?.cancel()
                        if detent == .large {
                            mixing = true
                        } else {
                            detent = .large
                            navigationTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 100))
                                guard !Task.isCancelled, !mixing else { return }
                                mixing = true
                            }
                        }
                    } label: {
                        destinationLabel("Mix and Match", icon: "hanger")
                    }
                    .accessibilityIdentifier("wardrobe.mix")

                    Divider().padding(.leading, 44)

                    Button(action: showSettings) {
                        destinationLabel("Settings", icon: "gearshape")
                    }
                    .accessibilityIdentifier("wardrobe.settings")
                }
                .buttonStyle(.plain)
                .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .softTopEdge()
    }

    private func destinationLabel(_ title: LocalizedStringResource, icon: String) -> some View {
        HStack(spacing: 12) {
            Label { Text(title) } icon: {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.allo(.footnote, .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .contentShape(.rect)
    }
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
                            .font(.allo(.caption, selected ? .semibold : .regular))
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
        let shape = RoundedRectangle(cornerRadius: slot == nil ? 99 : 15)
        return ZStack {
            shape.fill(none && slot != nil ? Color(.secondarySystemFill) : Tint.portrait)
            if none, slot != nil {
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

private struct BearMixView: View {
    @ScaledMetric(relativeTo: .subheadline) private var resetRowHeight: CGFloat = 45
    @State private var slot = BearOutfitSlot.headwear
    @State private var clothingScrollPosition = ScrollPosition()
    @State private var pendingColorReveal: UUID?
    @State private var resetRowExtendsBelowViewport = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewSize: CGFloat {
        if verticalSizeClass == .compact { return 80 }
        return typeSize.isAccessibilitySize ? 96 : 176
    }

    var body: some View {
        VStack(spacing: 12) {
            PokiPortrait(mood: .ready, side: previewSize)
                .accessibilityHidden(true)

            equippedItems
                .clipped()

            Picker("Outfit pieces", selection: Binding(
                get: { slot },
                set: { newSlot in
                    if reduceMotion { slot = newSlot }
                    else { withAnimation { slot = newSlot } }
                }
            )) {
                Text(BearOutfitSlot.headwear.name).tag(BearOutfitSlot.headwear)
                Text(BearOutfitSlot.clothes.name).tag(BearOutfitSlot.clothes)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("wardrobe.pieces")
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)

            TabView(selection: $slot) {
                pieces(.headwear).tag(BearOutfitSlot.headwear)
                pieces(.clothes).tag(BearOutfitSlot.clothes)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .padding(.top, 8)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: BearWardrobe.shared.selection)
        .background {
            LinearGradient(
                stops: [.init(color: Tint.page, location: 0), .init(color: Tint.page, location: 0.56),
                        .init(color: Color(light: 0x82AAF2, dark: 0x2E67DC), location: 1)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
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

    private func pieces(_ category: BearOutfitSlot) -> some View {
        let wardrobe = BearWardrobe.shared
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WardrobeGrid(slot: category)

                if category == .clothes, let outfit = wardrobe.selection.clothes {
                    VStack(spacing: 12) {
                        Divider()
                        colorOptions(outfit)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .frame(maxWidth: 520)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .clipShape(.rect(cornerRadius: 16))
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: wardrobe.selection.clothes)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: BearWardrobe.shared.colors != BearOutfitColors())
        .scrollPosition(category == .clothes ? $clothingScrollPosition : .constant(ScrollPosition()))
        .accessibilityIdentifier("wardrobe.page.\(category.rawValue)")
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
                    Text(slot.name).font(.allo(.caption2)).foregroundStyle(.secondary)
                    Text(piece.name).font(.allo(.caption, .semibold))
                }
                Image(systemName: "xmark")
                    .font(.allo(.caption2, .semibold))
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

    private func colorOptions(_ outfit: BearOutfit) -> some View {
        let wardrobe = BearWardrobe.shared
        return VStack(alignment: .leading, spacing: 0) {
            ColorPicker("Main Color", selection: color(\.primary, outfit: outfit), supportsOpacity: false)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            Divider().padding(.leading, 12)
            ColorPicker("Accent Color", selection: color(\.accent, outfit: outfit), supportsOpacity: false)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.leading, 12)
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3)) {
                        wardrobe.colors = BearOutfitColors()
                    }
                } label: {
                    Text("Reset Colors")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(.rect)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: wardrobe.colors != BearOutfitColors() ? resetRowHeight : 0, alignment: .top)
            .clipped()
            .opacity(wardrobe.colors != BearOutfitColors() ? 1 : 0)
            .allowsHitTesting(wardrobe.colors != BearOutfitColors())
            .accessibilityHidden(wardrobe.colors == BearOutfitColors())
            .onGeometryChange(for: Bool.self) { geometry in
                guard let bounds = geometry.bounds(of: .scrollView(axis: .vertical)) else { return false }
                return geometry.frame(in: .scrollView(axis: .vertical)).maxY > bounds.height + 0.5
            } action: { extendsBelowViewport in
                resetRowExtendsBelowViewport = extendsBelowViewport
            }
            .task(id: pendingColorReveal) {
                guard let request = pendingColorReveal else { return }
                // Let the reset row finish expanding before determining whether it fits.
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 170 : 320)) }
                catch { return }
                guard pendingColorReveal == request else { return }
                pendingColorReveal = nil
                guard slot == .clothes, wardrobe.selection.clothes == outfit,
                      wardrobe.colors != BearOutfitColors(), resetRowExtendsBelowViewport else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    clothingScrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .font(.allo(.subheadline))
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3), value: wardrobe.colors != BearOutfitColors())
    }

    private func color(_ component: WritableKeyPath<BearOutfitColors, UInt32?>, outfit: BearOutfit) -> Binding<Color> {
        let wardrobe = BearWardrobe.shared
        return Binding {
            Color(hex: wardrobe.colors[keyPath: component] ?? outfit.defaultColors[keyPath: component] ?? 0xFFFFFF)
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let rgb = [r, g, b].map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
            let value = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
            guard wardrobe.colors[keyPath: component] != value else { return }
            wardrobe.colors[keyPath: component] = value
            pendingColorReveal = UUID()
        }
    }
}
