import SwiftUI

/// The Poki Loopback Shortcut where the loopback is set up in Settings and in Screen History's settings:
/// the way to the step by step page, Run, and when it last ran.
struct CellularShortcutSection: View {
    @ObservedObject private var reconnect = LoopbackShortcut.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            NavigationLink {
                LoopbackShortcutPage().settingsPage()
            } label: {
                SettingsRow(title: reconnect.isSetUp ? "How It Is Set Up" : "Set It Up Step by Step", symbol: "list.number",
                            accessory: reconnect.isSetUp ? .done : nil)
            }
            .accessibilityIdentifier("cellularShortcut.guide")
            if reconnect.canRun {
                // It asks Poki first and changes nothing while the connection is fine, so it can
                // be run whenever the loopback is off (the owner, 2026-11-20).
                Button {
                    openURL(LoopbackShortcut.run)
                } label: {
                    SettingsRow(title: "Run the Shortcut", symbol: "play", accessory: .leaves)
                }
                .accessibilityIdentifier("cellularShortcut.run")
            }
            LoopbackShortcutLastRun()
        } header: {
            Group {
                SettingsHeader("Poki Loopback Shortcut")
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("It turns the loopback back on by itself when it stops, on Wi-Fi or cellular. Set it up once.")
            }
            .settingsFooter()
        }
    }
}

/// When the shortcut last asked Poki, one row.
struct LoopbackShortcutLastRun: View {
    @ObservedObject private var reconnect = LoopbackShortcut.shared

    private var lastRun: String {
        guard let at = reconnect.lastAt else { return AppLocalization.text(LocalizedStringResource("Not Yet")) }
        if !reconnect.lastWorked { return AppLocalization.text(LocalizedStringResource("Did Not Connect")) }
        return at.formatted(.relative(presentation: .named))
    }

    var body: some View {
        SettingsRow(title: "Last Run", symbol: "clock", value: lastRun, warns: reconnect.lastAt != nil && !reconnect.lastWorked)
            .accessibilityIdentifier("cellularShortcut.lastRun")
    }
}

/// Setting up the Poki Loopback Shortcut, one small step at a time with the button for it right there
/// (the owner, Nov 21 2026: "step by step, simple and easy"). Sections of a Form: the start flow's page
/// puts its hero on top, Settings' page its title.
struct LoopbackShortcutSteps: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var reconnect = LoopbackShortcut.shared
    @Environment(\.openURL) private var openURL

    /// The app picked on the loopback page, which the shortcut has to turn on.
    private var appName: String? { LoopbackChoice.chosen(model.setup.proxyApp)?.name }

    var body: some View {
        Section {
            GuideLine(number: 1, text: "Tap Get the Shortcut below.")
            GuideLine(number: 2, text: "Tap Add Shortcut.")
            if let appName {
                GuideLine(number: 3, text: "When it asks for a VPN, pick \(appName).")
            } else {
                GuideLine(number: 3, text: "When it asks for a VPN, pick the app from the loopback step.")
            }
            GuideLine(number: 4, text: "When it asks about the automation, turn it on. Leave Ask Before Running off.")
            Button("Get the Shortcut", systemImage: "square.2.layers.3d") { openURL(reconnect.take(model: model)) }
                .accessibilityIdentifier("cellularShortcut.get")
        } header: {
            Group {
                Text("1. Add the Shortcut")
            }
            .settingsHeader()
        }

        Section {
            if reconnect.canRun {
                Button("Run the Shortcut", systemImage: "play") { openURL(LoopbackShortcut.run) }
                    .accessibilityIdentifier("cellularShortcut.runOnce")
            }
            LoopbackShortcutLastRun()
        } header: {
            Group {
                Text("2. Try It Once")
            }
            .settingsHeader()
        } footer: {
            Group {
                if reconnect.isSetUp && reconnect.lastWorked {
                    Text("It works. From now on it fixes the loopback by itself.")
                } else if reconnect.isSetUp {
                    Text("It ran but the loopback did not come on. Check step 2 of the loopback, then run it again.")
                } else {
                    Text("Run it once, then check Last Run.")
                }
            }
            .settingsFooter()
        }

        Section {
            NavigationLink {
                HistoryShortcutGuide().settingsPage().outsideStartFlow()
            } label: {
                Text("No Automation? Add It by Hand")
            }
            .accessibilityIdentifier("cellularShortcut.byHand")
        } footer: {
            Group {
                Text("Only if Shortcuts did not ask about an automation.")
            }
            .settingsFooter()
        }
    }
}

/// Settings' page for the shortcut: the same steps as the start flow.
struct LoopbackShortcutPage: View {
    var body: some View {
        Form { LoopbackShortcutSteps() }
            .navigationTitle(AppLocalization.text("Poki Loopback Shortcut"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A numbered line of a walk-through: the number in a circle, then one short thing to do.
struct GuideLine: View {
    var number: Int
    var text: LocalizedStringKey
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "\(number).circle") }
            .font(.allo(.subheadline))
    }
}

/// The Wi-Fi automation added by hand, for an iPhone where the shared shortcut arrives without it.
/// The shortcut itself comes from the link, so the automation only has to run it.
struct HistoryShortcutGuide: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                GuideLine(number: 1, text: "Open Shortcuts and tap Automation.")
                GuideLine(number: 2, text: "Tap the plus button, then tap Wi-Fi.")
                GuideLine(number: 3, text: "Pick Any Network, and pick the choice for when this iPhone leaves Wi-Fi.")
                GuideLine(number: 4, text: "Pick Run Immediately, then tap Next.")
                GuideLine(number: 5, text: "Pick Poki Loopback, then tap Done.")
                Button("Open Shortcuts", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
                .accessibilityIdentifier("cellularShortcut.openShortcuts")
            } footer: {
                Group {
                    Text("On older iOS, Automation is a tab at the bottom of Shortcuts.")
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Add It by Hand"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
