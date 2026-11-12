import SwiftUI

// The settings rows adapt element-hq/compound-ios (commit a1db8e1b), copyright 2023-2024 New Vector Ltd.,
// GNU Affero General Public License v3.0 only (Poki's own licence); see THIRD_PARTY_NOTICES.md:
// - Sources/Compound/List/ListRowLabel.swift: the icon on its own subtle ground beside the title, the
//   description 2 pt under the title, 30 pt icons that scale with the text and do not size the row;
// - Sources/Compound/List/ListRowDetails.swift and ListRowAccessory.swift: the value and the chevron trailing.
// The settings home's order (the profile on top, then groups of rows) is element-hq/element-x-ios (commit
// 4447399a), ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift.
// Changed (ESP-469): Poki's round blue-soft ground (amber when the row needs you) instead of Compound's
// rounded square, Poki's Tint colours instead of Compound's tokens, a 34 pt icon on the home page, and the
// rows kept inside the system List, so navigation, swipe actions, search and Dynamic Type stay the system's.

/// A settings icon: the symbol in Poki's blue on its soft round ground; amber while the row needs you.
struct SettingsIcon: View {
    var symbol: String
    var warns = false
    /// Grey instead of blue, for the entry at the bottom of the conversations.
    var neutral = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 13.5

    init(symbol: String, warns: Bool = false, neutral: Bool = false, size: CGFloat = 30) {
        self.symbol = symbol
        self.warns = warns
        self.neutral = neutral
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        _glyph = ScaledMetric(wrappedValue: size * 0.45, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(warns ? Tint.amberInk : neutral ? Color(.label) : Tint.blueText)
            .frame(width: size, height: size)
            .background(warns ? Tint.amberSoft : neutral ? Color(.tertiarySystemFill) : Tint.blueSoft, in: .circle)
            // Compound's: the ground does not make the row taller.
            .padding(.vertical, -4)
            .accessibilityHidden(true)
    }
}

/// A part of Poki as a row on the settings home: its icon, its name with what is in there under it, and
/// where it stands on the right (an amber chip when that needs you).
struct SettingsRow: View {
    var title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    var symbol: String
    var value: String? = nil
    var warns = false
    /// A coloured dot before the value (the relay's state on External Agents).
    var dot: Color? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                if let caption { Text(caption).font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
                // At the accessibility sizes the value goes under the caption, as in Settings.
                if typeSize.isAccessibilitySize, let value { valueView(value) }
            }
            Spacer(minLength: 8)
            // The value keeps its width (a model's name, the way of asking); the caption wraps instead.
            if !typeSize.isAccessibilitySize, let value { valueView(value).lineLimit(1).layoutPriority(1) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func valueView(_ value: String) -> some View {
        if warns {
            Text(verbatim: value).font(.footnote.weight(.semibold)).foregroundStyle(Tint.amberInk)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Tint.amberSoft, in: .capsule)
        } else {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(verbatim: value).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// The subpages' rows: a Label's symbol on the same round ground as the home page's rows, so every
/// page under Settings draws its icons one way.
struct SettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            SettingsLabelIcon { configuration.icon }
            configuration.title
        }
    }
}

/// A label with its symbol on the round ground, for rows where the system's own label style does not
/// reach (inside a Toggle, a LabeledContent or a NavigationLink, a List draws its labels its own way).
struct SettingsLabel<Title: View, Icon: View>: View {
    var title: Title
    var icon: Icon

    init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsLabelIcon { icon }
            title
        }
    }
}

extension SettingsLabel where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, systemImage: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: systemImage) })
    }
}

private struct SettingsLabelIcon<Icon: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var size = 30.0
    @ViewBuilder var icon: Icon
    var body: some View {
        icon
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tint.blueText)
            .frame(width: size, height: size)
            .background(Tint.blueSoft, in: .circle)
            // A row that can't be used yet (Add Agent before the relay) greys its icon too.
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.vertical, -4)
    }
}

extension View {
    /// A page under Settings: Poki's page ground under the system's grouped rows, the round icons on
    /// its labels.
    func settingsPage() -> some View {
        labelStyle(SettingsLabelStyle())
            .scrollContentBackground(.hidden)
            .background(Tint.page.ignoresSafeArea())
    }
}

/// A capsule button: black for the action you reach for most (Pause), outlined for the rest.
struct SettingsPill: View {
    var title: LocalizedStringKey
    var symbol: String? = nil
    var prominent = false
    var chevron = false
    var action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height = 44.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.footnote.weight(.bold))
                        .foregroundStyle(prominent ? Tint.onSolid : Tint.blueText)
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                if chevron {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .foregroundStyle(prominent ? Tint.onSolid : Color(.label))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(prominent ? Tint.solid : Color(.secondarySystemGroupedBackground), in: .capsule)
            .overlay { if !prominent { Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 1) } }
            .contentShape(.capsule)
        }
        .buttonStyle(PressedDimStyle())
    }
}

/// One choice among a few, as a card with a ring around the chosen one (Approvals' ways of asking).
struct SettingsChoiceCard: View {
    var title: String
    var detail: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    if let detail {
                        Text(verbatim: detail).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Tint.blue : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(selected ? Tint.blue : Color(.separator).opacity(0.5), lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressedDimStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
