import PokiCore
import SwiftUI
import UIKit

/// Settings › Models › Local: the provider that is always there. It holds the models on this iPhone,
/// Apple Intelligence where the iPhone has it and the models that can be downloaded, and what they
/// are used for. Local models can only decide and write Senses' notes. Nothing they are asked leaves
/// the phone.
struct LocalProviderDetail: View {
    @State private var version = ModelKeys.saved
    let model = BacktapeModel.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: ProviderRef.local.name)
                LabeledContent("Connection", value: AppLocalization.text("On This iPhone"))
            }

            if LocalModels.recommends {
                Section { LocalRecommendation() }
            }

            Section {
                NavigationLink { AppleIntelligenceDetail() } label: {
                    LocalModelRow(symbol: "apple.intelligence", name: LocalModel.apple.name, status: Self.appleStatus)
                }
                .accessibilityIdentifier("models.local.apple")
                // The models that can be downloaded, whether or not the iPhone has Apple Intelligence.
                // Listed on an iPhone that cannot run them too: its page says what they need.
                if BacktapeModel.offered {
                    ForEach(BacktapeModel.choices) { choice in
                        NavigationLink { DownloadedModelDetail(choice: choice) } label: {
                            LocalModelRow(symbol: "arrow.down.circle", name: choice.name, status: status(choice))
                        }
                        .accessibilityIdentifier("models.local.\(choice.id)")
                    }
                }
            } header: {
                Group {
                    Text("Models")
                }
                .settingsHeader()
            } footer: {
                Group {
                    if !BacktapeModel.supported {
                        Text("This iPhone does not have the memory to run a downloaded model.")
                    } else {
                        Text("Only one downloaded model is kept. What a local model is asked never leaves the phone.")
                    }
                }
                .settingsFooter()
            }

            Section {
                ForEach(ProviderRef.local.uses) { use in
                    NavigationLink { ModelTickList(use: use, provider: .local) } label: {
                        LabeledContent {
                            Text(verbatim: ProviderUseValue.text(use, for: .local))
                        } label: { SettingsLabel(use.title, systemImage: use.symbol) }
                    }
                    .accessibilityIdentifier("models.local.use.\(use.rawValue)")
                }
            } header: {
                Group {
                    Text("Use This Provider For")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Local models can be used for decisions and for Senses, which reads the screen and checks privacy on this iPhone.")
                }
                .settingsFooter()
            }
        }
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .settingsPage()
        .navigationTitle(Text(verbatim: ProviderRef.local.name))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
    }

    static var appleStatus: String {
        switch AppleIntelligence.status {
        case .available: AppLocalization.text("On This iPhone")
        case .turnedOff: AppLocalization.text("Turned Off")
        case .notReady: AppLocalization.text("Getting Ready")
        case .unsupported: AppLocalization.text("Not on This iPhone")
        }
    }

    /// Under a downloaded model's name: where its download stands.
    private func status(_ choice: BacktapeModel.Choice) -> String {
        guard model.choice == choice else { return AppLocalization.text("Not Downloaded") }
        switch model.state {
        case .ready: return AppLocalization.text("Downloaded")
        case .downloading(let part): return "\(Int(part * 100)) %"
        case .failed: return AppLocalization.text("Download Stopped")
        case .missing: return AppLocalization.text(model.kept > 0 ? "Download Stopped" : "Not Downloaded")
        }
    }
}

/// Local in the providers list: its tile, its name and what it is used for.
struct LocalProviderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "iphone", neutral: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: ProviderRef.local.name)
                Text(verbatim: ProviderUseValue.summary(.local)).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// Where the iPhone has no Apple Intelligence: the recommendation to download a model for decisions,
/// and the download as it goes.
struct LocalRecommendation: View {
    let model = BacktapeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message).font(.allo(.subheadline))
            } icon: {
                Image(systemName: "apple.intelligence")
            }
            .labelStyle(SettingsLabelStyle())
            if model.choice == LocalModels.recommended, case .downloading(let part) = model.state {
                ProgressView(value: part) {
                    Text(verbatim: "\(Int(part * 100)) %").font(.allo(.footnote)).monospacedDigit()
                }
                Button("Cancel Download") { model.cancel() }
            } else {
                Button {
                    LocalModels.downloadRecommended()
                } label: {
                    Text("Download \(LocalModels.recommended.name)")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("models.local.recommended")
                Text(verbatim: ByteCountFormatter.string(fromByteCount: LocalModels.recommended.bytes, countStyle: .file))
                    .font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.vertical, 4)
    }

    private var message: LocalizedStringKey {
        switch AppleIntelligence.status {
        case .turnedOff:
            "Apple Intelligence is turned off on this iPhone. Turn it on in Settings, or download a model to make decisions and write Senses’ notes on the phone."
        case .notReady:
            "Apple Intelligence is still getting ready on this iPhone. Until then, a downloaded model can make decisions and write Senses’ notes on the phone."
        case .available, .unsupported:
            "This iPhone has no Apple Intelligence. Download a model to make decisions and write Senses’ notes on the phone. It is used for decisions once it is downloaded."
        }
    }
}

/// Local › a downloaded model: its download. Only one downloaded model is kept, so downloading this
/// one removes the one before.
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
                LabeledContent("Requires", value: AppLocalization.text("iPhone with 6 GB of Memory"))
                // A download that stopped: how much of it is already here.
                if stoppedPart {
                    LabeledContent("Downloaded So Far", value: ByteCountFormatter.string(fromByteCount: model.kept, countStyle: .file))
                }
                if current, case .downloading(let part) = model.state {
                    LabeledContent {
                        Text(verbatim: "\(Int(part * 100)) %").monospacedDigit()
                    } label: {
                        ProgressView(value: part)
                    }
                    Button("Cancel Download") { model.cancel() }
                } else if !ready {
                    Button(downloadTitle) {
                        if !current {
                            // The one before goes with its files, and it no longer decides.
                            if QuickFixes.choice == .downloaded { QuickFixes.choice = .none }
                            model.choice = choice
                        }
                        model.download()
                    }
                    .disabled(!BacktapeModel.supported)
                    .accessibilityIdentifier("models.local.download")
                }
            } footer: {
                Group {
                    Text(footer)
                }
                .settingsFooter()
            }

            if ready {
                Section {
                    Button("Remove Model", role: .destructive) {
                        if QuickFixes.choice == .downloaded { QuickFixes.choice = .none }
                        model.remove()
                        ModelKeys.saved += 1
                    }
                    .accessibilityIdentifier("models.local.remove")
                }
            }
        }
        .settingsPage()
        .navigationTitle(Text(verbatim: choice.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The picked model's download stopped partway (it failed, was cancelled, or the app was closed).
    private var stoppedPart: Bool {
        guard current, model.kept > 0 else { return false }
        switch model.state {
        case .failed, .missing: return true
        case .downloading, .ready: return false
        }
    }

    private var downloadTitle: LocalizedStringKey {
        if current, model.state == .failed { return "Try Again" }
        return stoppedPart ? "Resume Download" : "Download Model"
    }

    private var footer: LocalizedStringKey {
        if !BacktapeModel.supported { return "This iPhone does not have enough memory to run this model." }
        if current, model.state == .failed {
            switch model.stopped {
            case .connection: return "The download stopped because the connection was lost. The files already downloaded are kept. Try again, on Wi-Fi if you can."
            case .server: return "The download stopped because the server did not send the file. The files already downloaded are kept. Try again later."
            case .space: return "There is not enough free space on this iPhone for this model. Free up some space and try again."
            case .other, nil: return "The download did not finish. The files already downloaded are kept. Try again."
            }
        }
        if stoppedPart { return "The download was stopped before it finished. The files already downloaded are kept." }
        if ready { return "This model is on this iPhone and runs here. Choose it under Decisions or Senses on the Models page." }
        return "Only one downloaded model is kept, and downloading this one removes the one before. Screen History uses it for its notes where the iPhone has no Apple Intelligence."
    }
}

/// A local model's row: its tile, its name and where it stands.
struct LocalModelRow: View {
    var symbol: String
    var name: String
    var status: String
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, neutral: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                Text(verbatim: status).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// Local › Apple Intelligence: Apple's own model, and whether this iPhone has it.
struct AppleIntelligenceDetail: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: LocalModel.apple.name)
                LabeledContent("Connection", value: AppLocalization.text("On This iPhone"))
                LabeledContent("Status", value: LocalProviderDetail.appleStatus)
            } footer: {
                Group {
                    switch AppleIntelligence.status {
                    case .available: Text("Choose it under Decisions or Senses on the Models page.")
                    case .turnedOff: Text("Turn on Apple Intelligence in the Settings app to use it here.")
                    case .notReady: Text("Apple Intelligence is downloading its model. It can be chosen once it is ready.")
                    case .unsupported: Text("This iPhone has no Apple Intelligence. A downloaded model can make decisions and write Senses’ notes instead.")
                    }
                }
                .settingsFooter()
            }
            if AppleIntelligence.status == .turnedOff {
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .settingsPage()
        .navigationTitle(Text(verbatim: LocalModel.apple.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What a provider's rows say about a use: the model it runs on now when this provider has it, else
/// how many models are ticked.
enum ProviderUseValue {
    @MainActor static func text(_ use: ModelUse, for provider: ProviderRef) -> String {
        let pick = ModelPicks.current(use)
        if let item = ModelPicks.groups(use).first(where: { $0.id == provider.id })?.items.first(where: { $0.pick == pick }) {
            return item.name
        }
        let count = ModelPicks.groups(use).first { $0.id == provider.id }?.items.count ?? 0
        return count == 0 ? AppLocalization.text("Off") : AppLocalization.text(LocalizedStringResource("\(count) Models"))
    }

    /// "Chat, Decisions", "Not in use": the uses a provider runs now.
    @MainActor static func summary(_ provider: ProviderRef) -> String {
        let uses = ModelUse.allCases.filter { use in
            let pick = ModelPicks.current(use)
            return ModelPicks.groups(use).first { $0.id == provider.id }?.items.contains { $0.pick == pick } ?? false
        }
        return uses.isEmpty ? AppLocalization.text(LocalizedStringResource("Not in use")) : uses.map(\.name).joined(separator: ", ")
    }
}
