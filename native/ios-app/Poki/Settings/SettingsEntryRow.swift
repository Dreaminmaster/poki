import PokiCore
import SwiftUI

// ESP-469: Settings opens from the bottom of the conversations, under the list, as in the board's
// "04 入口 推荐 侧边栏底部". The conversations add it with one line; where it opens is the app's (PokiApp).

extension EnvironmentValues {
    /// Opens Settings (Poki's profile sheet). Nil where nothing has set it: then the entry is not shown.
    @Entry var openPokiSettings: (() -> Void)? = nil
}

/// "Settings" at the bottom of the conversations, with an amber dot while something there needs you
/// (no model yet, setup not finished, an update waiting).
struct SettingsEntryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openPokiSettings) private var open
    @Environment(\.drawerOnGlass) private var onGlass

    private var needsYou: Bool {
        !ModelKeys.hasUsableKey || !model.setupComplete || model.signer.updateNotReady || model.signer.next?.kind == "update"
    }

    var body: some View {
        if let open {
            VStack(spacing: 0) {
                Divider().padding(.horizontal, 16)
                Button(action: open) {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "gearshape", neutral: true, size: 40)
                        Text("Settings").font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                        Spacer(minLength: 8)
                        if needsYou {
                            Circle().fill(Tint.amber).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(PressedDimStyle())
                .accessibilityValue(needsYou ? Text("Needs your attention") : Text(verbatim: ""))
                .accessibilityIdentifier("threads.settings")
            }
            // In the drawer's glass panel the glass is the ground.
            .background(onGlass ? Color.clear : Color(.systemBackground))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
    }
}
