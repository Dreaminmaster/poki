import PokiCore
import SwiftUI

/// Settings › Models › Local Models: the models on this iPhone, listed like the accounts above them.
/// Each opens to what it is and what it is used for. Nothing a local model is asked leaves the phone.
struct LocalModelsSection: View {
    /// The page's count of changes: a new pick redraws the rows.
    var version: Int

    let model = BacktapeModel.shared

    var body: some View {
        if OnDeviceDecisions.appleAvailable || BacktapeModel.supported {
            Section {
                if OnDeviceDecisions.appleAvailable {
                    NavigationLink { AppleIntelligenceDetail() } label: {
                        LocalModelRow(symbol: "apple.intelligence", name: AppLocalization.text("Apple Intelligence"),
                                      uses: QuickFixes.choice == .apple ? AppLocalization.text("Decisions") : AppLocalization.text("On This iPhone"))
                    }
                    .accessibilityIdentifier("models.local.apple")
                }
                // The models that can be downloaded, whether or not the iPhone has Apple Intelligence.
                if BacktapeModel.supported {
                    ForEach(BacktapeModel.choices) { choice in
                        NavigationLink { DownloadedModelDetail(choice: choice) } label: {
                            LocalModelRow(symbol: "arrow.down.circle", name: choice.name, uses: uses(choice))
                        }
                        .accessibilityIdentifier("models.local.\(choice.id)")
                    }
                }
            } header: {
                Text("Local Models").textCase(nil)
            } footer: {
                Text("Models on this iPhone. What they are asked never leaves the phone.")
            }
        }
    }

    /// Under a downloaded model's name: where its download stands, and Decisions when it decides.
    private func uses(_ choice: BacktapeModel.Choice) -> String {
        guard model.choice == choice else { return AppLocalization.text("Not Downloaded") }
        switch model.state {
        case .ready: return QuickFixes.choice == .downloaded ? AppLocalization.text("Decisions") : AppLocalization.text("Downloaded")
        case .downloading(let part): return "\(Int(part * 100)) %"
        case .missing, .failed: return AppLocalization.text("Not Downloaded")
        }
    }
}

/// Local Models › a downloaded model: its download, and what it is used for. Only one downloaded
/// model is kept, so downloading this one removes the one before.
struct DownloadedModelDetail: View {
    var choice: BacktapeModel.Choice
    let model = BacktapeModel.shared

    /// This is the model the phone holds or is fetching.
    private var current: Bool { model.choice == choice }
    private var ready: Bool { current && model.state == .ready }

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: choice.name)
                LabeledContent("Connection", value: AppLocalization.text("On This iPhone"))
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: choice.bytes, countStyle: .file))
                if current, case .downloading(let part) = model.state {
                    LabeledContent {
                        Text(verbatim: "\(Int(part * 100)) %").monospacedDigit()
                    } label: {
                        ProgressView(value: part)
                    }
                    Button("Cancel Download") { model.cancel() }
                } else if !ready {
                    Button("Download Model") {
                        if !current {
                            // The one before goes with its files, and it no longer decides.
                            if QuickFixes.choice == .downloaded { QuickFixes.choice = .none }
                            model.choice = choice
                        }
                        model.download()
                    }
                    .accessibilityIdentifier("models.local.download")
                }
            } footer: {
                Text(footer)
            }

            Section {
                LocalDecisionToggle(choice: .downloaded, disabled: !ready)
                    .accessibilityIdentifier("models.local.downloaded.decisions")
            } header: {
                Text("Use This Model For")
            } footer: {
                Text("As the decision model it helps a routine go on when a prompt is in the way or a button was renamed. It acts only when the answer is clear and never taps anything that needs your approval. Only one decision model is in use at a time.")
            }

            if ready {
                Section {
                    Button("Remove Model", role: .destructive) {
                        if QuickFixes.choice == .downloaded { QuickFixes.choice = .none }
                        model.remove()
                    }
                    .accessibilityIdentifier("models.local.remove")
                }
            }
        }
        .settingsPage()
        .navigationTitle(Text(verbatim: choice.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: LocalizedStringKey {
        if current, model.state == .failed { return "The download did not finish. Try again on Wi-Fi, and it goes on where it stopped." }
        if ready { return "This model is on this iPhone and runs here. Screen History uses it for its notes where the iPhone has no Apple Intelligence." }
        return "Only one downloaded model is kept, and downloading this one removes the one before. Screen History uses it for its notes where the iPhone has no Apple Intelligence."
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
                Text("As the decision model it helps a routine go on when a prompt is in the way or a button was renamed. It acts only when the answer is clear and never taps anything that needs your approval. Only one decision model is in use at a time.")
            }
        }
        .settingsPage()
        .navigationTitle(AppLocalization.text("Apple Intelligence"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
