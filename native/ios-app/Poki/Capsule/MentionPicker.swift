import SwiftUI

/// The `@` app mention overlay shown 8pt above the composer bar.
/// Deep smoked Liquid Glass (26pt continuous radius), 280–340pt adaptive width, `#6CB0FF` matched-prefix highlight,
/// 4.5-row viewport (~252pt max height) with 10pt bottom fade & 3pt scroll indicator, and compact empty state with B1 escape hatch.
struct MentionPicker: View {
    var state: AppMentionState
    var composerWidth: CGFloat
    var caretX: CGFloat?
    var pick: (AppPickerEntry) -> Void
    var browseAll: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private let cornerRadius: CGFloat = 26
    private let rowHeight: CGFloat = 46
    private let headerHeight: CGFloat = 34
    private let maxTotalHeight: CGFloat = 252
    private var maxListHeight: CGFloat { maxTotalHeight - headerHeight - 6 }

    private var pickerWidth: CGFloat {
        MentionPickerLayout.width(for: composerWidth)
    }

    private var leadingOffset: CGFloat {
        MentionPickerLayout.horizontalOffset(caretX: caretX, pickerWidth: pickerWidth, composerWidth: composerWidth)
    }

    private var isScrollable: Bool {
        contentHeight > viewportHeight + 2 || CGFloat(state.matches.count) * rowHeight > maxListHeight
    }

    private var showsBottomFade: Bool {
        guard isScrollable else { return false }
        if contentHeight <= 0 || viewportHeight <= 0 {
            return CGFloat(state.matches.count) * rowHeight > maxListHeight
        }
        return scrollOffset + viewportHeight < contentHeight - 4
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if state.isEmptyResult {
                emptyContent
            } else {
                listContent
            }
        }
        .frame(width: pickerWidth)
        .clipShape(shape)
        .glassSurface(in: shape, tint: AppPickerGlass.tint(for: scheme), fallback: .card)
        .glassAppearing()
        .padding(.leading, leadingOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mention.picker")
    }

    private var listContent: some View {
        let listHeight = min(CGFloat(state.matches.count) * rowHeight, maxListHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("@")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPickerGlass.highlightBlue)
                Text("Mention App")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                Spacer(minLength: 8)
                Text(verbatim: countLabel)
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .frame(height: headerHeight)

            ZStack(alignment: .trailing) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(state.matches) { app in
                            Button { pick(app) } label: {
                                MentionRowContent(app: app, query: state.query, rowHeight: rowHeight)
                            }
                            .buttonStyle(MentionRowStyle(scheme: scheme))
                            .accessibilityIdentifier("mention.row.\(app.id)")
                        }
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: MentionScrollMetrics.self, of: MentionScrollMetrics.init) { _, metrics in
                    scrollOffset = metrics.offset
                    contentHeight = metrics.contentHeight
                    viewportHeight = metrics.viewportHeight
                }
                .mask {
                    if showsBottomFade {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.45), location: 0.55),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 24)
                        }
                    } else {
                        Color.black
                    }
                }

                if isScrollable {
                    MentionScrollIndicator(
                        offset: scrollOffset,
                        contentHeight: max(contentHeight, CGFloat(state.matches.count) * rowHeight + 6),
                        viewportHeight: max(viewportHeight, listHeight),
                        scheme: scheme
                    )
                    .padding(.trailing, 5)
                    .padding(.vertical, 6)
                }
            }
            .frame(height: listHeight)
        }
        .frame(maxHeight: maxTotalHeight)
    }

    private var countLabel: String {
        let count = state.matches.count
        if CGFloat(count) * rowHeight > maxListHeight {
            return AppLocalization.text(LocalizedStringResource("\(count) matches, scroll"))
        }
        return AppLocalization.text(LocalizedStringResource("\(count) matches"))
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 32, height: 32)
                .background(
                    scheme == .dark ? Color.white.opacity(0.10) : Color(.label).opacity(0.06),
                    in: Circle()
                )
            Text(verbatim: AppLocalization.text(LocalizedStringResource("No apps matching “\(state.query)”")))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(.label).opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button { browseAll() } label: {
                HStack(spacing: 4) {
                    Text("Browse All Apps")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(scheme == .dark ? Color(hex: 0x8AC8FF) : Tint.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    scheme == .dark ? Tint.blue.opacity(0.30) : Tint.blueSoft,
                    in: Capsule()
                )
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mention.browseAll")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("mention.empty")
    }
}

private struct MentionRowContent: View {
    var app: AppPickerEntry
    var query: String
    var rowHeight: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app.id, size: 28, alwaysLight: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppPickerCatalog.highlightedText(
                    app.displayName,
                    query: query,
                    baseColor: Color(.label),
                    highlightColor: AppPickerGlass.highlightBlue,
                    baseFont: .subheadline.weight(.medium),
                    highlightFont: .subheadline.weight(.bold)
                ))
                .lineLimit(1)

                if let subtitle = app.subtitle {
                    Text(AppPickerCatalog.highlightedText(
                        subtitle,
                        query: query,
                        baseColor: Color(.secondaryLabel),
                        highlightColor: AppPickerGlass.highlightBlue,
                        baseFont: .caption,
                        highlightFont: .caption.weight(.bold)
                    ))
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct MentionRowStyle: ButtonStyle {
    var scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(.label))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark
                        ? Color.white.opacity(configuration.isPressed ? 0.12 : 0)
                        : Color(.label).opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(.horizontal, 6)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MentionScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        contentHeight = geometry.contentSize.height
        viewportHeight = geometry.containerSize.height
    }
}

private struct MentionScrollIndicator: View {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var scheme: ColorScheme

    var body: some View {
        GeometryReader { proxy in
            let trackHeight = max(1, proxy.size.height)
            let ratio = min(1, viewportHeight / max(1, contentHeight))
            let thumbHeight = min(64, max(24, trackHeight * ratio))
            let maxScroll = max(1, contentHeight - viewportHeight)
            let progress = min(1, max(0, offset / maxScroll))
            let travel = max(0, trackHeight - thumbHeight)

            Capsule()
                .fill(scheme == .dark ? Color.white.opacity(0.26) : Color(.label).opacity(0.22))
                .frame(width: 2.5, height: thumbHeight)
                .offset(y: travel * progress)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 4)
        .allowsHitTesting(false)
    }
}
