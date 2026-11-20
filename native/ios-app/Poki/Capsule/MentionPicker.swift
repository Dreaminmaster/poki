import SwiftUI

/// The apps and connectors that fit what is being written, on glass right over the caret. A tap
/// puts the name in the message, where it becomes its capsule; the keyboard's composition (Pinyin
/// and the like) is matched while it is still pending.
struct MentionPicker: View {
    let matches: [MentionMatch]
    var pick: (MentionMatch) -> Void
    var dismiss: () -> Void
    @ScaledMetric(relativeTo: .body) private var icon = 26.0
    @ScaledMetric(relativeTo: .body) private var width = 250.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { match in
                Button { pick(match) } label: { row(match) }
                    .buttonStyle(MentionRowStyle())
                    .accessibilityIdentifier("mention.\(match.capsule.id)")
            }
        }
        .padding(.vertical, 6)
        .frame(width: min(width, 320))
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .card)
        .glassAppearing()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Apps and Connectors"))
        .accessibilityAction(.escape, dismiss)
    }

    private func row(_ match: MentionMatch) -> some View {
        HStack(spacing: 10) {
            MentionIcon(capsule: match.capsule, size: min(icon, 34))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: match.title).font(.allo(.body)).foregroundStyle(Color(.label)).lineLimit(1)
                if match.isConnector {
                    Text("Connector").font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(minHeight: 44).contentShape(.rect)
    }
}

/// An app's icon, or a connector's symbol on Poki's blue, in the Home Screen's shape.
struct MentionIcon: View {
    let capsule: AppCapsule
    var size: CGFloat = 26
    @State private var store = AppIconStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let symbol = capsule.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(Tint.blue)
            } else if let image = store.icon(capsule.id, dark: false) {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                DefaultAppIcon(size: size).task { await store.load(capsule.id) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct MentionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
    }
}
