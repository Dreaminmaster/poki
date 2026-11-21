import SwiftUI

// Security (the owner, Nov 21 2026): four pages instead of one long one. Approvals (what Poki may do by
// itself, Automatic Unlock with it), Screen History (the same page as the gear on Senses), the Activity
// Log (every step and approval, with the Observing Record folded in) and Face ID & Passcode. A row that
// leads behind the lock asks the system prompt before it opens its page.

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared

    var body: some View {
        List {
            Section {
                NavigationLink(value: DetailsRoute.approvals) {
                    SettingsRow(title: "Approvals", symbol: "checkmark.shield", value: model.approvalMode.title)
                }
                .accessibilityIdentifier("security.approvals")
                UnlockLink(whenOff: true, go: { path.append(DetailsRoute.screenHistorySettings) }) {
                    SettingsRow(title: "Screen History", symbol: "rectangle.stack",
                                value: AppLocalization.text(capture.enabled ? LocalizedStringResource("On") : LocalizedStringResource("Off")))
                }
                .accessibilityIdentifier("security.screenHistory")
                NavigationLink(value: DetailsRoute.history) {
                    SettingsRow(title: "Activity Log", symbol: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("details.activity")
                UnlockLink(go: { path.append(DetailsRoute.lockSettings) }) {
                    SettingsRow(title: LocalizedStringKey(lock.biometricsName == "Touch ID" ? "Touch ID & Passcode" : "Face ID & Passcode"),
                                symbol: lock.biometricsSymbol, warns: !lock.biometricsReady)
                }
                .accessibilityIdentifier("security.lock")
            } footer: {
                Group {
                    Text("Approvals decide what Poki and agents may do without you. Screen History is also on the Senses page. The Activity Log keeps every step, approval and observing change.")
                }
                .settingsFooter()
            }
        }
        .navigationTitle(AppLocalization.text("Security"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
