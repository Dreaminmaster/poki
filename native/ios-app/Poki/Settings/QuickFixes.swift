import PokiCore
import SwiftUI

/// Fast decisions: the owner's own decision model (Cloudflare's Clef, TypeSafe's Jev, or one they
/// host), which a routine or a path asks how to go on where it would otherwise stop: a prompt in the
/// way, a button renamed or moved. There is no switch: it is in use from the moment a provider is
/// added and a model is picked on Settings › Models › Fast Decisions, and out of use when the model
/// is set back to None or the provider is removed. The call goes from this iPhone straight to that
/// provider, never through Poki's relay, and holds the task's goal and the screen's elements as text:
/// no screenshot, and nothing a password field holds.
///
/// The settings are in the app's defaults; the token is in the keychain and is never printed or logged.
enum QuickFixes {
    private static let settingsKey = "quickFixes.settings"
    private static let tokenAccount = "quick-fixes.token"

    static var settings: DeciderSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsKey), let saved = try? JSONDecoder().decode(DeciderSettings.self, from: data) else { return DeciderSettings() }
            return saved
        }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: settingsKey) } }
    }

    static var token: String {
        get { (try? Keychain.read(tokenAccount)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(tokenAccount) } else { try? Keychain.write(Data(trimmed.utf8), account: tokenAccount) }
        }
    }

    /// The decider PokiCore asks, read at each run: nil until a provider is added and a model picked.
    static var decider: Decider? {
        let settings = settings
        guard settings.hasModel else { return nil }
        return settings.decider(token: token)
    }

    /// The model in use, for the Models page; nil while fast decisions are off.
    static var modelInUse: String? { decider == nil ? nil : settings.modelInUse }

    /// Whether a provider has been added, with or without a model picked.
    static var hasProvider: Bool { settings.decider(token: token) != nil }

    static func remove() {
        token = ""
        settings = DeciderSettings()
    }
}

/// The two speed-ups being tried (General › Testing Options), both on unless turned off there.
enum SpeedOptions {
    static let appNamesKey = "testing.appNames"
    static let quickReadKey = "testing.quickRead"
    static var appNames: Bool { UserDefaults.standard.object(forKey: appNamesKey) as? Bool ?? true }
    static var quickRead: Bool { UserDefaults.standard.object(forKey: quickReadKey) as? Bool ?? true }
}

/// General › Testing Options: the switches for the two speed-ups.
struct SpeedTestingSection: View {
    @AppStorage(SpeedOptions.appNamesKey) private var appNames = true
    @AppStorage(SpeedOptions.quickReadKey) private var quickRead = true
    var body: some View {
        Section {
            Toggle("Apps by Name", isOn: $appNames)
            Toggle("Read When the Screen Settles", isOn: $quickRead)
        } header: {
            Text("Speed")
        } footer: {
            Text("On by default. Apps by Name lets an agent open an app by its name and keep it as the app it works in. Read When the Screen Settles reads the screen as soon as it has changed and holds still after an app opens, a swipe or a button, in place of a fixed pause. Changes count from the next step.")
        }
    }
}

/// The row on Settings › Models: the model in use, read again each time the page comes back.
struct FastDecisionsRow: View {
    @State private var value = ""
    var body: some View {
        NavigationLink { QuickFixesView() } label: {
            LabeledContent {
                Text(verbatim: value)
            } label: { SettingsLabel("Fast Decisions", systemImage: "bolt") }
        }
        .onAppear { value = QuickFixes.modelInUse ?? AppLocalization.text(QuickFixes.hasProvider ? "No Model" : "Not Set Up") }
    }
}

extension DeciderSettings.Provider {
    var title: LocalizedStringKey {
        switch self {
        case .cloudflare: "Cloudflare Workers AI"
        case .typesafe: "TypeSafe"
        case .custom: "Custom Address"
        }
    }
}

/// Settings › Models › Fast Decisions: the provider, its token and the model. Picking a model turns
/// fast decisions on; None turns them off.
struct QuickFixesView: View {
    @State private var settings = QuickFixes.settings
    @State private var token = QuickFixes.token
    @State private var checking = false
    @State private var result: CheckResult?
    @State private var fixed = 0
    @State private var confirmRemove = false

    private enum CheckResult: Equatable {
        case works(Int)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.provider) {
                    ForEach(DeciderSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Provider", systemImage: "cloud")
                }
                switch settings.provider {
                case .cloudflare:
                    field("Account ID", text: $settings.account, prompt: "0123456789abcdef", identifier: "quickFixes.account")
                case .custom:
                    field("Address", text: $settings.address, prompt: "https://example.com/v1/systemone", identifier: "quickFixes.address", url: true)
                case .typesafe:
                    EmptyView()
                }
                LabeledContent {
                    SecureField(text: $token, prompt: Text(settings.provider == .custom ? "Optional" : "Required")) { Text("API Token") }
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("quickFixes.token")
                } label: {
                    Text("API Token")
                }
            } header: {
                SettingsHeader("Provider")
            } footer: {
                Text("The request goes from this iPhone straight to this provider with your own token. It holds the goal of the task and the names of the elements on screen. No screenshot is sent and password fields are left out. The token stays in this iPhone’s keychain.")
            }

            Section {
                if settings.provider == .custom {
                    field("Model", text: $settings.model, prompt: AppLocalization.text("None"), identifier: "quickFixes.model")
                } else {
                    Picker(selection: $settings.model) {
                        Text("None").tag("")
                        ForEach(DeciderSettings.models(settings.provider), id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: {
                        SettingsLabel("Model", systemImage: "bolt")
                    }
                    .disabled(!hasProvider)
                    .accessibilityIdentifier("quickFixes.model")
                }
            } header: {
                SettingsHeader("Fast Decision Model")
            } footer: {
                Text("Poki uses this model from the moment you pick it. When a routine meets something unexpected, such as a prompt in the way or a renamed button, Poki asks it how to go on. It acts only when the answer is clear and never taps anything that needs your approval. A fix that worked is remembered, so the next run asks nothing. Choose None to stop using it.")
            }

            Section {
                Button(action: check) {
                    HStack {
                        SettingsLabel("Check Connection", systemImage: "bolt.horizontal")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(!hasProvider || checking)
                .accessibilityIdentifier("quickFixes.check")
                if fixed > 0 { LabeledContent("Steps Fixed", value: fixed.formatted()) }
            } footer: {
                switch result {
                case .works(let ms): Text("It answered in \(ms) ms.").foregroundStyle(Tint.green)
                case .failed(let why): Text(verbatim: why).foregroundStyle(.red)
                case nil: EmptyView()
                }
            }

            if hasProvider {
                Section {
                    Button("Remove Provider", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("quickFixes.remove")
                }
            }
        }
        .navigationTitle(AppLocalization.text("Fast Decisions"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fixed = RoutineStore.shared.routines.reduce(0) { $0 + ($1.fixes ?? 0) } }
        .onChange(of: settings) { old, new in
            var new = new
            // Another provider's models are its own: the pick starts again at None.
            if old.provider != new.provider, new.provider != .custom, !DeciderSettings.models(new.provider).contains(new.model) {
                new.model = ""
                settings = new
            }
            QuickFixes.settings = new
            result = nil
        }
        .onChange(of: token) { _, new in
            QuickFixes.token = new
            result = nil
        }
        .confirmationDialog("Remove this provider and its token from this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Provider", role: .destructive) {
                QuickFixes.remove()
                settings = QuickFixes.settings
                token = ""
            }
        }
    }

    private var hasProvider: Bool { settings.decider(token: token) != nil }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, identifier: String, url: Bool = false) -> some View {
        LabeledContent {
            TextField(text: text, prompt: Text(verbatim: prompt)) { Text(title) }
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .keyboardType(url ? .URL : .asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
        } label: {
            Text(title)
        }
    }

    private func check() {
        guard let decider = settings.decider(token: token) else { return }
        checking = true
        result = nil
        Task {
            let outcome = await decider.check()
            checking = false
            switch outcome {
            case .success(let ms): result = .works(ms)
            case .failure(let error): result = .failed(AppLocalization.text(LocalizedStringResource("The check failed. \(error.description)")))
            }
        }
    }
}
