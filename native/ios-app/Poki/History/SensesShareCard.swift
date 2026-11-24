import SwiftUI

/// An answer from Screen History in the chat, drawn as a task's result row is (the owner,
/// 2026-11-21: the same top right mark and app icons as the other cards, and structured info): the
/// apps' icons, Screen History and who let it through, and the round mark for how it ended at the
/// top right. Under it, one row for each app with when and how long, the post or page found, and the
/// answer Poki's model was given.
struct SensesShareCard: View {
    var note: ApprovalNote
    var share: SensesShare
    @ScaledMetric(relativeTo: .footnote) private var markSide = 20.0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            header
            if !share.apps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(share.apps, id: \.app) { use in AppRow(use: use) }
                }
            }
            if let item = share.item {
                HStack(alignment: .top, spacing: 8) {
                    AppIconView(app: item.app, size: 18)
                    Text(verbatim: item.title).font(.allo(.subheadline, .medium)).foregroundStyle(Color(.label))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            Text(verbatim: share.answer).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
            if note.state == .asking, !note.reason.isEmpty {
                Text(verbatim: AppLocalization.bundle.localizedString(forKey: note.reason, value: note.reason, table: nil))
                    .font(.allo(.footnote)).foregroundStyle(Tint.amberInk).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: 340, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(shape.strokeBorder(note.state == .asking ? Tint.amberLine : Tint.line, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 12) {
            icons
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen History").font(.allo(.subheadline, .semibold)).foregroundStyle(Color(.label))
                Text(verbatim: subline).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 6)
            mark
        }
        .accessibilityElement(children: .combine)
    }

    /// Up to three of the apps' icons, overlapping, or Screen History's own symbol without one.
    @ViewBuilder private var icons: some View {
        let apps = share.apps.prefix(3).map(\.app)
        if apps.isEmpty {
            Image(systemName: "clock.arrow.circlepath").font(.allo(.body, .semibold)).foregroundStyle(Color(.secondaryLabel))
                .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
        } else {
            HStack(spacing: -12) {
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    AppIconView(app: app, size: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
                        .zIndex(Double(apps.count - index))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Who let it through and when: "You Approved, 10:30 PM".
    private var subline: String {
        let who: LocalizedStringResource = switch (note.state, note.byModel) {
        case (.asking, _): "Waiting for Your Approval"
        case (.allowed, true): "Approved Automatically"
        case (.allowed, false): "You Approved"
        case (.refused, _): "You Did Not Approve"
        case (.expired, _): "Approval Ran Out"
        }
        let text = AppLocalization.text(who)
        guard note.state != .asking, let at = note.answered else { return text }
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale))
        return AppLocalization.text(LocalizedStringResource("\(text), \(time)"))
    }

    /// The task card's end mark: a green tick, a red cross, a grey stop, or a spinner while it waits.
    @ViewBuilder private var mark: some View {
        let side = min(32, markSide)
        switch note.state {
        case .asking:
            ProgressView().controlSize(.small).frame(width: side, height: side)
        case .allowed:
            end("checkmark", Tint.green, side: side).accessibilityLabel(Text("Shared"))
        case .refused:
            end("xmark", Tint.red, side: side).accessibilityLabel(Text("Not Shared"))
        case .expired:
            end("stop.fill", Color(.systemGray), side: side, size: 7).accessibilityLabel(Text("Not Shared"))
        }
    }

    private func end(_ name: String, _ color: Color, side: CGFloat, size: CGFloat = 9) -> some View {
        Image(systemName: name).font(.system(size: size * side / 20, weight: .heavy)).foregroundStyle(.white)
            .frame(width: side, height: side).background(color, in: .circle)
    }

    /// One app: its icon and name, when it was used, and for how long.
    private struct AppRow: View {
        var use: SensesShare.Use

        var body: some View {
            HStack(spacing: 10) {
                AppIconView(app: use.app, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: HistoryNames.app(use.app)).font(.allo(.subheadline)).foregroundStyle(Color(.label)).lineLimit(1)
                    Text(verbatim: when).font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(Duration.seconds(use.minutes * 60), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                    .font(.caption.monospacedDigit()).foregroundStyle(Color(.secondaryLabel))
            }
            .accessibilityElement(children: .combine)
        }

        private var when: String {
            let today = Calendar.current.isDateInToday(use.from)
            let style = Date.IntervalFormatStyle(date: today ? .omitted : .abbreviated, time: .shortened)
                .locale(AppLocalization.locale)
            return use.to.timeIntervalSince(use.from) < 60
                ? use.from.formatted(Date.FormatStyle(date: today ? .omitted : .abbreviated, time: .shortened).locale(AppLocalization.locale))
                : (use.from..<use.to).formatted(style)
        }
    }
}
