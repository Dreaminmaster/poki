import SwiftUI

struct MentionPicker: View {
    var apps: [KnownApp]
    var pick: (KnownApp) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(apps, id: \.id) { app in
                Button { pick(app) } label: {
                    HStack(spacing: 12) {
                        if let icon = AppIconStore.shared.icon(app.id, dark: false) {
                            Image(uiImage: icon).resizable().scaledToFit().frame(width: 29, height: 29)
                                .clipShape(.rect(cornerRadius: 6))
                        } else {
                            DefaultAppIcon(size: 29)
                        }
                        Text(verbatim: app.name(in: AppLanguage.current))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(MentionRowStyle())
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .card)
        .glassAppearing()
        .accessibilityElement(children: .contain)
    }
}

private struct MentionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(.label))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.label).opacity(configuration.isPressed ? 0.1 : 0))
                    .padding(.horizontal, 6)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
