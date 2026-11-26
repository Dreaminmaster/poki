import AuthenticationServices
import Foundation
import PiSwiftAI
import SwiftUI

/// New sign-ins share the Codex Keychain account for text and voice. Existing text-only sign-ins
/// continue to work for text until their owner authorizes the shared account.
enum ChatGPTAccount {
    @MainActor private static var renewal: (service: String, stored: String, task: Task<String?, Never>)?

    struct SignInRequired: LocalizedError {
        var errorDescription: String? { ChatGPTAccount.signInAgain }
    }

    struct ResponsesClient: ProviderHTTPClient {
        let transport: DefaultProviderHTTPClient

        func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
            try await send(request, timeoutPolicy: .request)
        }

        func send(_ request: URLRequest, timeoutPolicy: ProviderHTTPTimeoutPolicy) async throws -> ProviderHTTPResponse {
            let response = try await transport.send(request, timeoutPolicy: timeoutPolicy)
            // PiSwift's Codex adapter keeps only the response body in its final error message.
            if response.statusCode == 401 { throw SignInRequired() }
            return response
        }
    }

    static var signInAgain: String {
        AppLocalization.text(LocalizedStringResource("Sign in to ChatGPT again. Open Settings, then Models."))
    }

    static func decode(_ stored: String) -> OAuthCredentials? {
        try? JSONDecoder().decode(OAuthCredentials.self, from: Data(stored.utf8))
    }

    static func save(_ credentials: OAuthCredentials, service: String = ModelKeys.defaultService) throws {
        let data = try JSONEncoder().encode(credentials)
        try ModelKeys.save(String(decoding: data, as: UTF8.self), for: .chatgpt, service: service)
    }

    static var signedIn: Bool {
        isSignedIn()
    }

    static func isSignedIn(storage: PokiStorage) -> Bool {
        isSignedIn(
            codexService: storage.codexService,
            codexHome: storage.codexHome,
            modelKeysService: storage.keychainService
        )
    }

    static func isSignedIn(
        codexService: String = CodexAccount.defaultService,
        codexHome: URL = CodexAccount.home,
        modelKeysService: String = ModelKeys.defaultService
    ) -> Bool {
        CodexAccount.hasStoredCredential(service: codexService, home: codexHome)
            || ModelKeys.key(.chatgpt, service: modelKeysService).flatMap(decode)?.clientId?.isEmpty == false
    }

    @MainActor
    static func codexAccessToken(
        voice: CodexVoice = .shared,
        service: String = CodexAccount.defaultService,
        home: URL = CodexAccount.home
    ) async -> String? {
        guard let token = CodexAccount.readAccessToken(service: service, home: home) else { return nil }
        guard CodexAccount.expiresSoon(token) else { return token }
        do { try await voice.refreshAccount() } catch { return nil }
        guard let fresh = CodexAccount.readAccessToken(service: service, home: home), !CodexAccount.expiresSoon(fresh) else { return nil }
        return fresh
    }

    static func signOut(service: String = ModelKeys.defaultService) throws {
        try ModelKeys.removeChatGPTSignIn(service: service)
    }

    @MainActor
    static func signOutIncludingVoice(
        voice: CodexVoice = .shared,
        codexService: String = CodexAccount.defaultService,
        codexHome: URL = CodexAccount.home,
        modelKeysService: String = ModelKeys.defaultService
    ) async throws {
        CodexAccount.beginSignOut()
        defer { CodexAccount.endSignOut() }

        try CodexAccount.clearLegacyCredentials(service: codexService, home: codexHome)
        try await voice.signOut()
        try CodexAccount.clearStoredCredentials(service: codexService)
        try signOut(service: modelKeysService)
    }

    @MainActor
    static func accessToken(service: String = ModelKeys.defaultService) async -> String? {
        guard let stored = ModelKeys.key(.chatgpt, service: service), let credential = decode(stored),
              credential.clientId?.isEmpty == false else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        if credential.expires > now + 60_000 || credential.refresh.isEmpty && credential.expires > now {
            return credential.access
        }
        guard !credential.refresh.isEmpty else { return nil }

        // A new chat asks for a title and a reply at the same time. Both need the same rotated token.
        let task: Task<String?, Never>
        if let renewal, renewal.service == service, renewal.stored == stored {
            task = renewal.task
        } else {
            task = Task {
                defer { if renewal?.service == service && renewal?.stored == stored { renewal = nil } }
                guard let fresh = try? await refreshOpenAIChatGPTToken(credential),
                      ModelKeys.key(.chatgpt, service: service) == stored else { return nil }
                do { try save(fresh, service: service); return fresh.access }
                catch { return nil }
            }
            renewal = (service, stored, task)
        }
        guard let access = await task.value, ModelKeys.key(.chatgpt, service: service).flatMap(decode)?.access == access else { return nil }
        return access
    }

}

struct ChatGPTSignIn: View {
    @Environment(\.dismiss) private var dismiss
    var onSignedIn: () -> Void = {}
    @State private var working = false
    @State private var problem: String?
    @State private var browser: ChatGPTBrowserSession?

    var body: some View {
        NavigationStack {
            Form {
                if let authorization = CodexVoice.shared.authorization {
                    Section {
                        Text(verbatim: authorization.code)
                            .font(.title2.monospaced())
                            .textSelection(.enabled)
                        Link("Continue to ChatGPT", destination: authorization.url)
                    } header: {
                        Text("Device Code")
                    } footer: {
                        Text("Enter this code on the ChatGPT page to sign in for text chat and live voice.")
                    }
                } else {
                    Section {
                        HStack {
                            Button("Continue with ChatGPT") { authorize(.browser(openBrowser)) }
                                .disabled(working)
                                .accessibilityIdentifier("chatgpt.sign-in.browser")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    } footer: {
                        Text("Use your ChatGPT subscription for text chat and live voice. Your sign-in stays in this iPhone’s Keychain.")
                    }
                    Section {
                        DisclosureGroup("Other Sign-In Methods") {
                            Button("Use a Device Code") { authorize(.deviceCode) }
                                .accessibilityIdentifier("chatgpt.sign-in.device-code")
                        }
                        .disabled(working)
                        .accessibilityIdentifier("chatgpt.sign-in.other")
                    }
                }
                if let problem { Text(verbatim: problem).foregroundStyle(Color(.systemRed)) }
                if ChatGPTAccount.signedIn {
                    Section { Button("Sign Out", role: .destructive, action: signOut).disabled(working) }
                }
            }
            .navigationTitle(Text(verbatim: "ChatGPT"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } } }
            .interactiveDismissDisabled(working)
        }
    }

    private func cancel() {
        closeBrowser()
        CodexVoice.shared.cancelLogin()
        dismiss()
    }

    private func authorize(_ method: CodexVoice.LoginMethod) {
        guard !working else { return }
        problem = nil
        working = true
        Task {
            defer {
                closeBrowser()
                working = false
            }
            do {
                try await CodexVoice.shared.authorize(method)
                guard CodexAccount.accessToken != nil else { throw CodexVoice.Failure.signIn }
                try? ChatGPTAccount.signOut()
                ModelKeys.selectedProvider = .chatgpt
                // The plan's model list is read now, not after a failed read's wait.
                ModelCatalog.clearFailures(.chatgpt)
                Task { await ModelCatalog.refreshStale() }
                closeBrowser()
                onSignedIn()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                problem = AppLocalization.text("Could not sign in to ChatGPT. Try again.")
            }
        }
    }

    private func openBrowser(_ url: URL) throws {
        guard let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { throw CodexVoice.Failure.signIn }
        let next = ChatGPTBrowserSession(anchor: anchor)
        browser = next
        try next.open(url) { outcome in
            // A returned sheet means the sign-in server finished. Its result arrives as login/completed.
            guard outcome != .returned else { return }
            CodexVoice.shared.cancelLogin()
            if outcome == .failed { problem = AppLocalization.text("Could not sign in to ChatGPT. Try again.") }
        }
    }

    private func closeBrowser() {
        browser?.close()
        browser = nil
    }

    private func signOut() {
        working = true
        Task {
            defer { working = false }
            do {
                try await ChatGPTAccount.signOutIncludingVoice()
                dismiss()
            } catch {
                problem = AppLocalization.text("Could not sign out of ChatGPT. Try again.")
            }
        }
    }
}

@MainActor
final class ChatGPTBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The iOS build of the Codex sign-in server sends the browser here once the token exchange ends,
    /// on success and on failure. OpenAI only accepts the http loopback redirect for this client.
    static let callbackScheme = "poki-chatgpt"

    enum Outcome: Equatable { case returned, cancelled, failed }

    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    static func outcome(callbackURL: URL?, error: Error?) -> Outcome {
        if let callbackURL, callbackURL.scheme == callbackScheme { return .returned }
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return .cancelled }
        return .failed
    }

    func open(_ url: URL, onClose: @escaping @MainActor (Outcome) -> Void) throws {
        let next = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.callbackScheme)) { [weak self] callbackURL, error in
            let outcome = Self.outcome(callbackURL: callbackURL, error: error)
            Task { @MainActor in
                guard let self, self.session != nil else { return }
                self.session = nil
                onClose(outcome)
            }
        }
        next.presentationContextProvider = self
        session = next
        guard next.start() else {
            session = nil
            throw CodexVoice.Failure.signIn
        }
    }

    func close() {
        let closing = session
        session = nil
        closing?.cancel()
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

#if DEBUG && targetEnvironment(simulator)
/// Simulator test runs only: `SIMCTL_CHILD_POKI_TEST_CREDENTIAL=<file>` names a JSON file on the Mac,
/// `{"provider": "chatgpt"|"anthropic"|…, "model"?: id, "secret": key or credential JSON}`. It is read
/// once at launch into the keychain and the provider is selected. Nothing is printed.
enum TestCredential {
    static func importIfGiven() {
        guard let path = ProcessInfo.processInfo.environment["POKI_TEST_CREDENTIAL"],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = (json["provider"] as? String).flatMap(ModelProvider.init(rawValue:)),
              let secret = json["secret"] as? String else { return }
        try? ModelKeys.save(secret, for: provider)
        ModelKeys.selectedProvider = provider
        if let model = json["model"] as? String { ModelKeys.selectedModel = model }
    }
}
#endif
