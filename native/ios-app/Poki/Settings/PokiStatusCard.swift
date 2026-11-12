import SwiftUI

// ESP-469: tapping Poki's picture shows where Poki stands, on a card under the picture, with Pause and the
// way into Settings. Settings itself opens from the bottom of the conversations (SettingsEntryRow) and
// from this card.

/// The one place the settings card and the status card take Poki's status words from. They are the
/// bear's own (PokiMood.word), the keys ESP-467 settled with the Live Activity in Poki's voice ("Poki’s
/// asleep", "Poki’s on it"), never a second set.
enum PokiStatusCopy {
    @MainActor static func current(model: AppModel, chat: ChatModel) -> PokiStatus {
        PokiStatus.current(model: model, chat: chat)
    }

    /// The words beside the dot. Beside Poki's name, which the line would repeat, they lose their
    /// "Poki" ("Poki’s asleep" is "Asleep", "Poki 睡着了" is "睡着了").
    static func word(_ status: PokiStatus, besideName: Bool = false) -> String {
        let word = status.word
        guard besideName else { return word }
        for prefix in ["Poki’s ", "Poki's ", "Poki "] where word.hasPrefix(prefix) {
            let rest = word.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { break }
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return word
    }

    /// Poki saying, in the first person, whether it can work now and what starts it.
    /// Read from the status, so it never says otherwise than the words above it.
    @MainActor static func line(_ status: PokiStatus, model: AppModel) -> String {
        if status.mood == .paused, !(model.sessionOn || model.wantsOn) {
            return String(localized: "I’m off right now, so agents can’t connect. Turn me on when you need me.")
        }
        if status.mood == .paused {
            return String(localized: "I’m taking a break. Send a task or an agent request, and I’ll wake right up.")
        }
        return String(localized: "I’m ready to help. Send a task or an agent request, and I’ll get started.")
    }
}

extension PowerTile {
    var title: LocalizedStringKey {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .turnOn: "Turn On"
        }
    }

    var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .turnOn: "power"
        }
    }

    /// The accessibility identifier's last part, as the profile's tiles had them.
    var name: String {
        switch self {
        case .pause: "pause"
        case .resume: "resume"
        case .turnOn: "turnOn"
        }
    }

    @MainActor func act(model: AppModel, chat: ChatModel) {
        switch self {
        case .pause: chat.stop(); model.pauseRunner()
        case .resume: model.wakeRunner()
        case .turnOn: model.startSession()
        }
    }
}

/// The card under Poki's picture: the status, the model, Poki's line, then Pause (or Resume, or Turn On)
/// and Settings.
struct PokiStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.colorScheme) private var scheme
    var openSettings: () -> Void

    var body: some View {
        let status = PokiStatusCopy.current(model: model, chat: chat)
        let power = PowerTile(model: model, running: chat.running)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(status.mood.dot).frame(width: 8, height: 8)
                Text(verbatim: PokiStatusCopy.word(status)).font(.headline).foregroundStyle(Color(.label)).lineLimit(1)
                Spacer(minLength: 8)
                if ModelKeys.hasUsableKey {
                    Text(verbatim: ModelKeys.selectedModelName).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Text(verbatim: PokiStatusCopy.line(status, model: model))
                .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SettingsPill(title: power.title, symbol: power.symbol, prominent: true) { power.act(model: model, chat: chat) }
                    .accessibilityIdentifier("status.\(power.name)")
                SettingsPill(title: "Settings", chevron: true, action: openSettings)
                    .accessibilityIdentifier("status.settings")
            }
        }
        .padding(18)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(shape.strokeBorder(Tint.ring, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.14), radius: 20, y: 12)
        .accessibilityIdentifier("status.card")
    }
}

extension View {
    /// The status card over the page, under the top bar, with the page dimmed behind it; a tap outside
    /// closes it. Settings closes it and opens Settings.
    /// `leading` is where the chat begins: beside the conversations on iPad.
    func pokiStatusCard(isPresented: Binding<Bool>, leading: CGFloat = 16, openSettings: @escaping () -> Void) -> some View {
        modifier(PokiStatusCardOverlay(isPresented: isPresented, leading: leading, openSettings: openSettings))
    }
}

private struct PokiStatusCardOverlay: ViewModifier {
    @Binding var isPresented: Bool
    var leading: CGFloat
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if isPresented {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .accessibilityLabel(Text("Close"))
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                    PokiStatusCard(openSettings: {
                        isPresented = false
                        openSettings()
                    })
                    .padding(.leading, leading).padding(.trailing, 16)
                    .padding(.top, 64)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { isPresented = false }
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.18), value: isPresented)
        }
    }
}
