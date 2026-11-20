import SwiftUI

struct BearWardrobeOverlay: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openPokiSettings) private var openSettings
    @State private var mixing = false

    var body: some View {
        GeometryReader { proxy in
            let safeBottom = proxy.safeAreaInsets.bottom
            ZStack(alignment: .bottom) {
                if isPresented {
                    (scheme == .dark ? Color.black.opacity(0.5) : Color(hex: 0x23302C).opacity(0.25))
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture(perform: close)
                        .accessibilityHidden(true)
                        .transition(.opacity.animation(.linear(duration: reduceMotion ? 0.15 : 0.2)))

                    ViewThatFits(in: .vertical) {
                        panel(safeBottom: safeBottom).fixedSize(horizontal: false, vertical: true)
                        ScrollView { panel(safeBottom: safeBottom) }
                            .background(WardrobeTheme.panel, in: WardrobeTheme.sheet)
                    }
                    .frame(maxWidth: 520)
                    .transition(panelTransition)
                    .accessibilityHidden(mixing)
                    .zIndex(1)

                    if mixing {
                        BearMixView { mixing = false }
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                            .zIndex(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .accessibilityAction(.escape) { if mixing { mixing = false } else { close() } }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.27), value: mixing)
    }

    private var panelTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.linear(duration: 0.15)) }
        let slide = AnyTransition.move(edge: .bottom)
        return .asymmetric(insertion: slide.animation(.spring(duration: 0.38, bounce: 0.14)),
                           removal: slide.animation(.easeIn(duration: 0.24)))
    }

    private func close() {
        isPresented = false
        mixing = false
    }

    private func panel(safeBottom: CGFloat) -> some View {
        let wardrobe = BearWardrobe.shared
        return VStack(spacing: 0) {
            Capsule().fill(.tertiary).frame(width: 34, height: 4).padding(.top, 10)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outfits").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Current outfit: \(wardrobe.selection.displayName)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.26), value: wardrobe.selection)
                        .accessibilityIdentifier("wardrobe.current")
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                .accessibilityIdentifier("wardrobe.close")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            WardrobeGrid(slot: nil)
                .padding(16)
            VStack(spacing: 0) {
                let mixed = wardrobe.selection != .bare && wardrobe.selection.matchingSet == nil
                WardrobeLink(title: "Mix and Match", icon: "hanger",
                             detail: mixed ? "Wearing" : "Choose headwear and clothes", active: mixed) {
                    mixing = true
                }
                .accessibilityIdentifier("wardrobe.mix")
                Divider()
                WardrobeLink(title: "Settings", icon: "gearshape") {
                    close()
                    openSettings?()
                }
                .accessibilityIdentifier("wardrobe.settings")
            }
            .background(WardrobeTheme.inner, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16)
            .padding(.bottom, max(26, safeBottom))
        }
        .background(WardrobeTheme.panel, in: WardrobeTheme.sheet)
        .overlay { WardrobeTheme.sheet.strokeBorder(.quaternary, lineWidth: 0.5).allowsHitTesting(false) }
    }
}

private enum WardrobeTheme {
    static let panel = Color(light: 0xFFFFFF, dark: 0x1E1E21)
    static let inner = Color(light: 0xF3F5F9, dark: 0x2A2A2D)
    static let blue = Color(light: 0x0177FD, dark: 0x4C9DFF)
    static let sheet = UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
}

private struct WardrobeLink: View {
    let title: LocalizedStringResource
    let icon: String
    var detail: LocalizedStringResource?
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WardrobeTheme.blue)
                    .frame(width: 30, height: 30)
                    .background(Tint.portrait, in: .circle)
                Text(title)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail).font(.subheadline)
                        .foregroundStyle(active ? WardrobeTheme.blue : Color.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct WardrobeGrid: View {
    let slot: BearOutfitSlot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let wardrobe = BearWardrobe.shared
        let options: [BearOutfit?] = [nil] + BearOutfit.allCases.map(Optional.some)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 5), spacing: 12) {
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
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? WardrobeTheme.blue : Color.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .frame(minHeight: 16, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .contentShape(.rect)
                }
                .buttonStyle(WardrobePressStyle())
                .accessibilityLabel(Text(name))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("wardrobe.\(slot?.rawValue ?? "set").\(option?.id ?? 0)")
            }
        }
    }

    private func tile(image: String, none: Bool, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: slot == nil ? 99 : 15)
        return ZStack {
            shape.fill(none && slot != nil ? WardrobeTheme.inner : Tint.portrait)
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
                shape.strokeBorder(WardrobeTheme.blue, lineWidth: 2.5)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.14).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(WardrobeTheme.blue, in: .circle)
                    .overlay { Circle().strokeBorder(WardrobeTheme.panel, lineWidth: 1.5) }
                    .offset(x: 2, y: -2)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    .animation(reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.30, bounce: 0.45).delay(0.06), value: selected)
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.26, bounce: 0.35), value: selected)
        .accessibilityHidden(true)
    }
}

private struct WardrobePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
    }
}

private struct BearMixView: View {
    let back: () -> Void
    @State private var slot = BearOutfitSlot.headwear
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let wardrobe = BearWardrobe.shared
        ScrollView {
            VStack(spacing: 12) {
                ZStack {
                    Text("Mix and Match").font(.headline).accessibilityAddTraits(.isHeader)
                    HStack {
                        Button(action: back) {
                            Image(systemName: "chevron.backward").font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(WardrobeTheme.panel, in: .circle)
                        }
                        .accessibilityLabel(Text("Back"))
                        .accessibilityIdentifier("wardrobe.mix.back")
                        Spacer()
                        Button { wardrobe.selection = .bare } label: {
                            Label("Remove All", systemImage: "arrow.uturn.backward")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(WardrobeTheme.panel, in: .capsule)
                        }
                        .disabled(wardrobe.selection == .bare)
                        .accessibilityIdentifier("wardrobe.removeAll")
                    }
                    .buttonStyle(.plain)
                }

                PokiPortrait(mood: .ready, side: 196)
                    .shadow(color: WardrobeTheme.blue.opacity(0.18), radius: 6, y: 4)
                    .accessibilityIdentifier("wardrobe.preview")
                HStack(spacing: 8) {
                    ForEach([BearOutfitSlot.headwear, .clothes], id: \.self) { slot in
                        if let outfit = wardrobe.selection[slot] { chip(outfit, slot: slot) }
                    }
                }
                Picker("Outfit pieces", selection: $slot) {
                    Text(BearOutfitSlot.headwear.name).tag(BearOutfitSlot.headwear)
                    Text(BearOutfitSlot.clothes.name).tag(BearOutfitSlot.clothes)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wardrobe.pieces")
                VStack(spacing: 12) {
                    WardrobeGrid(slot: slot)
                    if slot == .clothes, let outfit = wardrobe.selection.clothes {
                        Divider()
                        colorOptions(outfit)
                    }
                }
                .padding(12)
                .background(WardrobeTheme.panel, in: .rect(cornerRadius: 20))
            }
            .frame(maxWidth: 520)
            .padding(16)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                stops: [.init(color: Tint.page, location: 0), .init(color: Tint.page, location: 0.56),
                        .init(color: scheme == .dark ? Color(hex: 0x2E67DC) : Color(hex: 0x82AAF2), location: 1)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
        }
    }

    private func chip(_ outfit: BearOutfit, slot: BearOutfitSlot) -> some View {
        let piece = outfit.piece(slot)
        return Button { BearWardrobe.shared.selection[slot] = nil } label: {
            HStack(spacing: 5) {
                if let thumbnail = BearWardrobe.shared.thumbnail("BearOutfit-\(piece.asset)") {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(width: 28, height: 28).background(Tint.portrait, in: .circle)
                        .clipShape(.circle)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(slot.name).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(piece.name).font(.caption2.weight(.semibold)).lineLimit(1)
                }
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
                    .background(.quaternary, in: .circle)
            }
            .padding(.horizontal, 6).frame(minHeight: 44)
            .background(WardrobeTheme.panel, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove \(AppLocalization.text(piece.name))"))
    }

    private func colorOptions(_ outfit: BearOutfit) -> some View {
        let wardrobe = BearWardrobe.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorPicker("Main Color", selection: color(\.primary, outfit: outfit), supportsOpacity: false)
                ColorPicker("Accent Color", selection: color(\.accent, outfit: outfit), supportsOpacity: false)
            }
            if wardrobe.colors != BearOutfitColors() {
                Button("Reset Colors") { wardrobe.colors = BearOutfitColors() }
                    .font(.footnote)
            }
        }
        .font(.subheadline)
    }

    private func color(_ component: WritableKeyPath<BearOutfitColors, UInt32?>, outfit: BearOutfit) -> Binding<Color> {
        let wardrobe = BearWardrobe.shared
        return Binding {
            Color(hex: wardrobe.colors[keyPath: component] ?? outfit.defaultColors[keyPath: component] ?? 0xFFFFFF)
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let rgb = [r, g, b].map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
            wardrobe.colors[keyPath: component] = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
        }
    }
}
