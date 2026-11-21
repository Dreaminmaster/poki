import SwiftUI

// Security (the owner, 2026-11-16): what Poki may do by itself and what was read off the screen, on
// one page. Approvals come first, as they are on their own page. Then Screen History's settings and
// lock, and the two records, the Activity Log and the Observing Record.

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var showsAutoUnlockPasscode = false

    var body: some View {
        List {
            SecurityApprovalSections()

            // Automatic Unlock (#555) belongs with what Poki may do by itself (the owner, Nov 21
            // 2026): its only place, with the passcode and its explanation.
            if model.supportsAutoUnlock || model.autoUnlock.enabled {
                AutoUnlockSection(setting: model.autoUnlock, canEnable: model.supportsAutoUnlock,
                                  showsPasscode: $showsAutoUnlockPasscode)
            }

            Section {
                NavigationLink(value: DetailsRoute.screenHistory) {
                    SettingsRow(title: "Screen History", symbol: "rectangle.stack",
                                value: AppLocalization.text(capture.enabled ? LocalizedStringResource("On") : LocalizedStringResource("Off")))
                }
                .accessibilityIdentifier("details.screenHistory")
                NavigationLink { HistoryGate { HistoryLockSettings().settingsPage() } } label: {
                    SettingsRow(title: "Screen History Lock", symbol: "lock")
                }
                .accessibilityIdentifier("security.lock")
            } header: {
                Group {
                    SettingsHeader("Screen History")
                }
                .settingsHeader()
            }

            Section {
                NavigationLink(value: DetailsRoute.history) {
                    SettingsRow(title: "Activity Log", symbol: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("details.activity")
                NavigationLink { HistoryGate { HistoryRecordPage().settingsPage() } } label: {
                    SettingsRow(title: "Observing Record", symbol: "eye")
                }
                .accessibilityIdentifier("security.record")
            } header: {
                Group {
                    SettingsHeader("Records")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("The Activity Log lists every step Poki took and every approval. The Observing Record lists when Screen History was reading, stopped or left an app out.")
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Security"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsAutoUnlockPasscode) {
            AutoUnlockPasscodeForm(setting: model.autoUnlock)
        }
    }
}
