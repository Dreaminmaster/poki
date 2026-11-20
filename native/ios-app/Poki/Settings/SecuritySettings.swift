import SwiftUI

// Security (the owner, 2026-11-16): what Poki may do by itself and what was read off the screen, on
// one page. Approvals come first, as they are on their own page. Then Screen History's settings and
// lock, and the two records, the Activity Log and the Observing Record.

struct SecuritySettingsView: View {
    @ObservedObject private var capture = HistoryCapture.shared

    var body: some View {
        List {
            SecurityApprovalSections()

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
                SettingsHeader("Screen History")
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
                SettingsHeader("Records")
            } footer: {
                Text("The Activity Log lists every step Poki took and every approval. The Observing Record lists when Screen History was reading, stopped or left an app out.")
            }
        }
        .navigationTitle(AppLocalization.text("Security"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
