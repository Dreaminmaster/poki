import SwiftUI

/// One thing the message field has to say: a problem, a warning or a word of information, with an
/// optional action (Add Key, Try Again) and a way to put it away. Notices wait in a queue and show one
/// at a time, in one place: on glass just above the field, where opening one moves nothing.
struct Notice: Identifiable, Equatable {
    enum Style: Equatable { case error, warning, info }

    /// The same id posted again replaces the one waiting, so a problem said twice shows once.
    let id: String
    var style: Style
    var title: String
    var message: String?
    var actionTitle: String?
    /// How long it stays on its own; nil keeps it until it is put away.
    var lasts: Duration?

    static func == (a: Notice, b: Notice) -> Bool {
        a.id == b.id && a.style == b.style && a.title == b.title && a.message == b.message && a.actionTitle == b.actionTitle
    }
}

/// The queue behind the field's notices. Each notice can carry what its action does and what putting
/// it away does; VoiceOver reads a notice out when it shows.
@MainActor
@Observable
final class NoticeQueue {
    private(set) var items: [Notice] = []
    @ObservationIgnored private var actions: [String: () -> Void] = [:]
    @ObservationIgnored private var dismissals: [String: () -> Void] = [:]

    var current: Notice? { items.first }

    func post(_ notice: Notice, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        if let index = items.firstIndex(where: { $0.id == notice.id }) {
            items[index] = notice
        } else {
            items.append(notice)
        }
        actions[notice.id] = action
        dismissals[notice.id] = onDismiss
        if items.first?.id == notice.id { announce(notice) }
    }

    /// Put away by the person: what it does when put away runs.
    func dismiss(_ id: String) {
        let run = dismissals[id]
        remove(id)
        run?()
    }

    /// The notice's action: it runs, and the notice goes.
    func act(_ id: String) {
        let run = actions[id]
        remove(id)
        run?()
    }

    /// Gone because what it said no longer holds: nothing else runs.
    func clear(_ id: String) { remove(id) }

    private func remove(_ id: String) {
        let wasFirst = items.first?.id == id
        items.removeAll { $0.id == id }
        actions[id] = nil
        dismissals[id] = nil
        if wasFirst, let next = items.first { announce(next) }
    }

    private func announce(_ notice: Notice) {
        let words = [notice.title, notice.message].compactMap { $0 }.joined(separator: ". ")
        AccessibilityNotification.Announcement(words).post()
    }
}

/// A notice on glass: its mark, its words on one or two lines each, its action and Close.
struct NoticeView: View {
    let notice: Notice
    var act: () -> Void
    var dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var mark = 30.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: min(mark, 40) * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: min(mark, 40), height: min(mark, 40))
                .background(tint, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: notice.title).font(.allo(.subheadline, .semibold)).foregroundStyle(Color(.label)).lineLimit(2)
                if let message = notice.message {
                    Text(verbatim: message).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let title = notice.actionTitle {
                Button(action: act) {
                    Text(verbatim: title).font(.allo(.subheadline, .semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(Tint.blue, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("notice.action")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.allo(.footnote, .bold)).foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 36, height: 36)
                    .background(Color(.label).opacity(scheme == .dark ? 0.14 : 0.08), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("notice.close")
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 8)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: .card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notice.\(notice.id)")
        .sensoryFeedback(trigger: notice.id) { _, _ in notice.style == .error ? .error : notice.style == .warning ? .warning : nil }
    }

    private var symbol: String {
        switch notice.style {
        case .error: "exclamationmark"
        case .warning: "exclamationmark"
        case .info: "info"
        }
    }

    private var tint: Color {
        switch notice.style {
        case .error: Tint.red
        case .warning: Tint.amber
        case .info: Tint.blue
        }
    }
}
