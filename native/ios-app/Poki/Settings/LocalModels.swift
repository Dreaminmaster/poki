import PokiCore
import SwiftUI

/// Settings › Models › Local Models: the models on this iPhone, listed like the accounts above them.
/// Each opens to what it is and what it is used for. Nothing a local model is asked leaves the phone.
struct LocalModelsSection: View {
    /// The page's count of changes: a new pick redraws the rows.
    var version: Int

    var body: some View {
        if OnDeviceDecisions.appleAvailable {
            Section {
                NavigationLink { AppleIntelligenceDetail() } label: {
                    LocalModelRow(symbol: "apple.intelligence", name: AppLocalization.text("Apple Intelligence"),
                                  uses: QuickFixes.choice == .apple ? AppLocalization.text("Decisions") : AppLocalization.text("On This iPhone"))
                }
                .accessibilityIdentifier("models.local.apple")
            } header: {
                Text("Local Models").textCase(nil)
            } footer: {
                Text("Models on this iPhone. What they are asked never leaves the phone.")
            }
        }
    }
}

/// A local model's row: its tile, its name and what it is used for, as an account's row.
struct LocalModelRow: View {
    var symbol: String
    var name: String
    var uses: String
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, neutral: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                Text(verbatim: uses).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// The switch that makes a local model the decision model. Only one decision model is in use at a
/// time, so turning this on takes over from whichever was.
struct LocalDecisionToggle: View {
    var choice: QuickFixes.Choice
    var disabled = false
    @State private var on: Bool

    init(choice: QuickFixes.Choice, disabled: Bool = false) {
        self.choice = choice
        self.disabled = disabled
        _on = State(initialValue: QuickFixes.choice == choice)
    }

    var body: some View {
        Toggle(isOn: $on) { SettingsLabel("Decisions", systemImage: "bolt") }
            .disabled(disabled)
            .onChange(of: on) { _, new in
                if new { QuickFixes.choice = choice } else if QuickFixes.choice == choice { QuickFixes.choice = .none }
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in on = QuickFixes.choice == choice }
    }
}

/// Local Models › Apple Intelligence: Apple's own model, where the iPhone has it.
struct AppleIntelligenceDetail: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: AppLocalization.text("Apple Intelligence"))
                LabeledContent("Connection", value: AppLocalization.text("On This iPhone"))
            }
            Section {
                LocalDecisionToggle(choice: .apple)
                    .accessibilityIdentifier("models.local.apple.decisions")
            } header: {
                Text("Use This Model For")
            } footer: {
                Text("As the decision model it helps a skill go on when a prompt is in the way or a button was renamed. It acts only when the answer is clear and never taps anything that needs your approval. Only one decision model is in use at a time.")
            }
        }
        .settingsPage()
        .navigationTitle(AppLocalization.text("Apple Intelligence"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
