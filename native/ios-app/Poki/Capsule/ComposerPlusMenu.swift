import SwiftUI

/// The composer's `+` menu (Scheme A1): frequent app quick row + 1px divider + Photos / Take Photo / Files.
/// Uses a single smoked Liquid Glass container aligned with `PokiMenu` and strictly zero glass-on-glass inside.
struct ComposerPlusMenu: View {
    var quickApps: [AppPickerEntry]
    var maxAttachments: Int
    var canAddAttachments: Bool
    var canTakePhoto: Bool
    var onPickApp: (AppPickerEntry) -> Void
    var onMoreApps: () -> Void
    var onPhotos: () -> Void
    var onCamera: () -> Void
    var onFiles: () -> Void
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    private let menuWidth: CGFloat = 268
    private let iconSize: CGFloat = 36
    private let actionIconColumnWidth: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            quickAppsSection
            dividerLine
            actionsSection
        }
        .frame(width: menuWidth)
        .clipShape(shape)
        .glassSurface(in: shape, tint: AppPickerGlass.tint(for: scheme), fallback: .card)
        .glassAppearing()
        .contentShape(shape)
        .onTapGesture {}
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.plus.menu")
        .accessibilityAction(.escape) { onDismiss() }
    }

    private var quickAppsSection: some View {
        let iconShape = RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Frequent Apps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label).opacity(0.78))
                Spacer(minLength: 4)
                Text("Tap to insert")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .padding(.horizontal, 16)

            HStack(spacing: 0) {
                ForEach(quickApps) { app in
                    Button { onPickApp(app) } label: {
                        VStack(spacing: 6) {
                            AppIconView(app: app.id, size: iconSize, alwaysLight: true)
                                .overlay {
                                    if scheme == .light {
                                        iconShape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                                    }
                                }
                            Text(verbatim: app.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(.label).opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PlusQuickTileStyle(scheme: scheme))
                    .accessibilityLabel(Text(verbatim: app.displayName))
                    .accessibilityIdentifier("composer.plus.app.\(app.id)")
                }

                Button { onMoreApps() } label: {
                    VStack(spacing: 6) {
                        iconShape
                            .fill(scheme == .dark ? Color.white.opacity(0.14) : Color(.label).opacity(0.10))
                            .overlay {
                                iconShape
                                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 0.5)
                            }
                            .overlay {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color(.label).opacity(0.92))
                            }
                            .frame(width: iconSize, height: iconSize)
                        Text("More")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(.label).opacity(0.92))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(.rect)
                }
                .buttonStyle(PlusQuickTileStyle(scheme: scheme))
                .accessibilityLabel(Text("More Apps"))
                .accessibilityIdentifier("composer.plus.more")
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(scheme == .dark ? Color.white.opacity(0.10) : Color(.separator).opacity(0.55))
            .frame(height: 1 / max(1, displayScale))
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            actionRow(
                title: "Photos",
                symbol: "photo",
                id: "composer.photos",
                hint: AppLocalization.text(LocalizedStringResource("Up to \(maxAttachments)")),
                enabled: canAddAttachments,
                action: onPhotos
            )
            actionRow(
                title: "Take Photo",
                symbol: "camera",
                id: "composer.camera",
                enabled: canAddAttachments && canTakePhoto,
                action: onCamera
            )
            actionRow(
                title: "Files",
                symbol: "folder",
                id: "composer.files",
                enabled: canAddAttachments,
                action: onFiles
            )
        }
        .padding(.vertical, 6)
    }

    private func actionRow(
        title: LocalizedStringKey,
        symbol: String,
        id: String,
        hint: String? = nil,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button { action() } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: actionIconColumnWidth, alignment: .center)
                Text(title)
                    .font(.body)
                Spacer(minLength: 8)
                if let hint {
                    Text(verbatim: hint)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .foregroundStyle(enabled ? Color(.label) : Color(.secondaryLabel).opacity(0.65))
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PlusActionRowStyle(scheme: scheme))
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }
}

private struct PlusQuickTileStyle: ButtonStyle {
    var scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.12 : 0) : Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, 2)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PlusActionRowStyle: ButtonStyle {
    var scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.12 : 0) : Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, 6)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
