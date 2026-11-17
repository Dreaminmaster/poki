import PokiCore
import SwiftUI

/// Quick Fixes: the owner's own decision model (Cloudflare's Clef, TypeSafe's Jev, or one they host),
/// which a routine or a path asks how to go on where it would otherwise stop: a prompt in the way, a
/// button renamed or moved. Off until the owner turns it on and enters their own token. The call goes
/// from this iPhone straight to that provider, never through Poki's relay, and holds the task's goal
/// and the screen's elements as text: no screenshot, and nothing a password field holds.
///
/// The settings are in the app's defaults; the token is in the keychain and is never printed or logged.
enum QuickFixes {
    static let enabledKey = "quickFixes.enabled"
    private static let settingsKey = "quickFixes.settings"
    private static let tokenAccount = "quick-fixes.token"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

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

    /// The decider PokiCore asks, read at each run: nil while Quick Fixes is off or not set up.
    static var decider: Decider? {
        guard enabled else { return nil }
        return settings.decider(token: token)
    }

    /// Whether the settings and the token make a decider, whatever the switch says.
    static var isSetUp: Bool { settings.decider(token: token) != nil }
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

/// Settings › Memory › Quick Fixes.
struct QuickFixesView: View {
    @State private var enabled = QuickFixes.enabled
    @State private var settings = QuickFixes.settings
    @State private var token = QuickFixes.token
    @State private var checking = false
    @State private var result: CheckResult?
    @State private var fixed = 0

    private enum CheckResult: Equatable {
        case works(Int)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    SettingsLabel("Fix Steps on the Way", systemImage: "wand.and.sparkles")
                }
                .disabled(!ready && !enabled)
                .accessibilityIdentifier("quickFixes.enabled")
            } footer: {
                Text("When a routine meets something unexpected, such as a prompt in the way or a renamed button, Poki asks a fast decision model how to go on. It acts only when the answer is clear and never taps anything that needs your approval. A fix that worked is remembered, so the next run asks nothing.")
            }

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
                field("Model", text: $settings.model, prompt: DeciderSettings.defaultModel(settings.provider), identifier: "quickFixes.model")
                LabeledContent {
                    SecureField(text: $token, prompt: Text("Required")) { Text("API Token") }
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("quickFixes.token")
                } label: {
                    Text("API Token")
                }
            } header: {
                SettingsHeader("Decision Model")
            } footer: {
                Text("The request goes from this iPhone straight to this provider with your own token. It holds the goal of the task and the names of the elements on screen. No screenshot is sent and password fields are left out. The token stays in this iPhone’s keychain.")
            }

            Section {
                Button(action: check) {
                    HStack {
                        SettingsLabel("Check Connection", systemImage: "bolt.horizontal")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(!ready || checking)
                .accessibilityIdentifier("quickFixes.check")
                if fixed > 0 { LabeledContent("Steps Fixed", value: fixed.formatted()) }
            } footer: {
                switch result {
                case .works(let ms): Text("It answered in \(ms) ms.").foregroundStyle(Tint.green)
                case .failed(let why): Text(verbatim: why).foregroundStyle(.red)
                case nil: EmptyView()
                }
            }
        }
        .navigationTitle(AppLocalization.text("Quick Fixes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fixed = RoutineStore.shared.routines.reduce(0) { $0 + ($1.fixes ?? 0) } }
        .onChange(of: enabled) { _, on in QuickFixes.enabled = on }
        .onChange(of: settings) { _, new in
            QuickFixes.settings = new
            result = nil
            turnOffIfIncomplete()
        }
        .onChange(of: token) { _, new in
            QuickFixes.token = new
            result = nil
            turnOffIfIncomplete()
        }
    }

    private var ready: Bool { settings.decider(token: token) != nil }

    /// The switch never stays on over settings that make no decider.
    private func turnOffIfIncomplete() {
        if enabled, !ready { enabled = false }
    }

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
