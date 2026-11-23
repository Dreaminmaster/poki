import AuthenticationServices
import Foundation
import PiSwiftAI
import SwiftUI

/// New sign-ins share the Codex Keychain account for text and voice. Existing text-only sign-ins
/// continue to work for text until their owner authorizes the shared account.
enum ChatGPTAccount {
    @MainActor private static var renewal: (stored: String, task: Task<String?, Never>)?

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

    static func save(_ credentials: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try ModelKeys.save(String(decoding: data, as: UTF8.self), for: .chatgpt)
    }

    static var signedIn: Bool {
        CodexAccount.accessToken != nil || ModelKeys.key(.chatgpt).flatMap(decode)?.clientId?.isEmpty == false
    }

    @MainActor
    static func codexAccessToken() async -> String? {
        guard let token = CodexAccount.accessToken else { return nil }
        guard CodexAccount.expiresSoon(token) else { return token }
        do { try await CodexVoice.shared.refreshAccount() } catch { return nil }
        guard let fresh = CodexAccount.accessToken, !CodexAccount.expiresSoon(fresh) else { return nil }
        return fresh
    }

    static func signOut() throws {
        try ModelKeys.removeChatGPTSignIn()
    }

    @MainActor
    static func signOutIncludingVoice(
        voice: CodexVoice = .shared,
        service: String = CodexAccount.defaultService
    ) async throws {
        CodexAccount.beginSignOut()
        defer { CodexAccount.endSignOut() }

        try CodexAccount.clearStoredCredentials(service: service)
        try await voice.signOut()
        try CodexAccount.clearStoredCredentials(service: service)
        try signOut()
    }

    @MainActor
    static func accessToken() async -> String? {
        guard let stored = ModelKeys.key(.chatgpt), let credential = decode(stored),
              credential.clientId?.isEmpty == false else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        if credential.expires > now + 60_000 || credential.refresh.isEmpty && credential.expires > now {
            return credential.access
        }
        guard !credential.refresh.isEmpty else { return nil }

        // A new chat asks for a title and a reply at the same time. Both need the same rotated token.
        let task: Task<String?, Never>
        if let renewal, renewal.stored == stored {
            task = renewal.task
        } else {
            task = Task {
                defer { if renewal?.stored == stored { renewal = nil } }
                guard let fresh = try? await refreshOpenAIChatGPTToken(credential),
                      ModelKeys.key(.chatgpt) == stored else { return nil }
                do { try save(fresh); return fresh.access }
                catch { return nil }
            }
            renewal = (stored, task)
        }
        guard let access = await task.value, ModelKeys.key(.chatgpt).flatMap(decode)?.access == access else { return nil }
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
                        Button("Continue with ChatGPT") { authorize(.browser(openBrowser)) }
                            .disabled(working)
                            .accessibilityIdentifier("chatgpt.sign-in.browser")
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
        try next.open(url) { cancelled in
            CodexVoice.shared.cancelLogin()
            if !cancelled { problem = AppLocalization.text("Could not sign in to ChatGPT. Try again.") }
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
private final class ChatGPTBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func open(_ url: URL, onClose: @escaping @MainActor (Bool) -> Void) throws {
        // The browser follows the HTTP redirect. Codex's loopback server receives the code
        // and reports completion after saving the account.
        let next = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            Task { @MainActor in
                guard let self, self.session != nil else { return }
                self.session = nil
                onClose(cancelled)
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
