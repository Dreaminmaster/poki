import Foundation
import PiSwiftAI

/// The models each account offers the text chat: a few fast defaults per type (no-thinking models such
/// as GPT-6.1 Terra and Claude Haiku first), plus whatever the provider's own model list returns for
/// the owner's key, which start switched off. The owner switches models on and off in Accounts ›
/// the account › Text Chat; the chat's model menu offers only the ones switched on.
enum ModelCatalog {
    /// The defaults, switched on until the owner turns them off.
    static func defaults(_ provider: ModelProvider, storage: PokiStorage = .live) -> Set<String> {
        switch provider {
        case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .openai, .chatgpt: ["gpt-6.1-terra", "gpt-6.2-sol"]
        case .deepseek: ["deepseek-flash"]
        case .gemini: ["gemini-3.8-flash"]
        case .openrouter: ["anthropic/claude-sonnet-5.5", "google/gemini-3.8-flash"]
        case .custom: Set(provider.models(in: storage).map(\.id))
        }
    }

    /// The account's models: the built-in ones, fast first, then the listed ones.
    static func all(_ provider: ModelProvider, storage: PokiStorage = .live) -> [ChatModelChoice] {
        let builtIn = provider.models(in: storage).sorted { fast($0.id) && !fast($1.id) }
        let known = Set(builtIn.map(\.id))
        return builtIn + listed(provider, storage: storage).filter { !known.contains($0.id) }
    }

    static func available(_ provider: ModelProvider, storage: PokiStorage = .live) -> [ChatModelChoice] {
        let choices = all(provider, storage: storage)
        let on = enabled(provider, storage: storage)
        return choices.filter { on.contains($0.id) }
    }

    static func enabled(_ provider: ModelProvider, storage: PokiStorage = .live) -> Set<String> {
        guard let saved = storage.defaults.stringArray(forKey: "models.enabled.\(provider.rawValue)") else { return defaults(provider, storage: storage) }
        // A default added in an update (GPT-6.2 Sol) is switched on once for an owner who already chose
        // models; one they switch off afterwards stays off.
        guard provider != .custom else { return Set(saved) }
        let introduced = introduced(provider, storage: storage)
        let new = defaults(provider, storage: storage).subtracting(introduced)
        guard !new.isEmpty else { return Set(saved) }
        let ids = Set(saved).union(new)
        storage.defaults.set(Array(ids), forKey: "models.enabled.\(provider.rawValue)")
        storage.defaults.set(Array(introduced.union(new)), forKey: "models.introduced.\(provider.rawValue)")
        return ids
    }

    /// The defaults an owner's saved choice has already seen: before this list was kept, the defaults of
    /// Poki 0.5.0.
    private static func introduced(_ provider: ModelProvider, storage: PokiStorage) -> Set<String> {
        if let saved = storage.defaults.stringArray(forKey: "models.introduced.\(provider.rawValue)") { return Set(saved) }
        switch provider {
        case .openai, .chatgpt: return ["gpt-6.1-terra"]
        default: return defaults(provider, storage: storage)
        }
    }

    static func set(_ id: String, on: Bool, for provider: ModelProvider, notify: Bool = true, storage: PokiStorage = .live) {
        var ids = enabled(provider, storage: storage)
        if on { ids.insert(id) } else { ids.remove(id) }
        storage.defaults.set(Array(ids), forKey: "models.enabled.\(provider.rawValue)")
        if provider != .custom {
            storage.defaults.set(Array(introduced(provider, storage: storage).union(defaults(provider, storage: storage))), forKey: "models.introduced.\(provider.rawValue)")
        }
        // The chat's model is always one that is switched on.
        if ModelKeys.selectedProvider(in: storage) == provider, !ids.contains(ModelKeys.selectedModel(in: storage)), let first = available(provider, storage: storage).first {
            ModelKeys.setSelectedModel(first.id, in: storage)
        }
        if notify { ModelKeys.saved += 1 }
    }

    static func listed(_ provider: ModelProvider, storage: PokiStorage = .live) -> [ChatModelChoice] {
        if provider == .custom {
            let providers = CustomProviders.all(in: storage)
            return providers.flatMap { custom in listedCustom(custom.id, storage: storage).map {
                ChatModelChoice(id: CustomProviders.choiceID(custom.id, $0), name: CustomProviders.choiceName(custom, $0, among: providers.count))
            } }
        }
        return (storage.defaults.stringArray(forKey: "models.listed.\(provider.rawValue)") ?? []).map { ChatModelChoice(id: $0, name: $0) }
    }

    /// The model ids one custom provider's list returned.
    static func listedCustom(_ id: UUID, storage: PokiStorage = .live) -> [String] {
        storage.defaults.stringArray(forKey: "models.listed.custom.\(id.uuidString)") ?? []
    }

    /// One custom provider's models: its own model and its list's, as the chat names them.
    static func all(custom id: UUID, storage: PokiStorage = .live) -> [ChatModelChoice] {
        all(.custom, storage: storage).filter { CustomProviders.parse($0.id)?.provider == id }
    }

    static func supportsReasoning(_ id: String, for provider: ModelProvider, storage: PokiStorage = .live) -> Bool {
        guard provider == .openrouter else { return false }
        return (storage.defaults.stringArray(forKey: "models.reasoning.openrouter") ?? []).contains(id)
    }

    /// No-thinking, fast models first: Terra, Haiku, Flash.
    static func fast(_ id: String) -> Bool {
        ["terra", "haiku", "flash", "mini"].contains { id.lowercased().contains($0) }
    }

    /// Reads the provider's model list with the owner's key (sent only to that provider).
    @MainActor
    static func refresh(_ provider: ModelProvider, storage: PokiStorage = .live) async throws -> Int {
        if provider == .custom {
            // Every custom provider; the first failure is passed on once the others are read.
            var count = 0
            var failure: Error?
            for custom in CustomProviders.all(in: storage) {
                do { count += try await refresh(custom: custom.id, storage: storage) }
                catch is CancellationError { throw CancellationError() }
                catch { failure = failure ?? error }
            }
            if let failure, count == 0 { throw failure }
            return count
        }
        let request: URLRequest?
        if provider == .chatgpt {
            request = await ChatGPTAccount.codexAccessToken(service: storage.codexService, home: storage.codexHome).flatMap(codexModelsRequest)
        } else {
            request = self.request(provider, storage: storage)
        }
        guard let request else { throw provider == .chatgpt ? DiscoveryError.signIn : DiscoveryError.authentication }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if provider == .chatgpt, status == 401 || status == 403 { throw DiscoveryError.signIn }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try store(data, for: provider, storage: storage)
    }

    /// Keeps a provider's model list. A body that is not a list (a captive portal's page, an error
    /// object) or a list with no chat models throws and keeps the last list and its age, so it is read
    /// again soon rather than in a day.
    @MainActor
    static func store(_ data: Data, for provider: ModelProvider, storage: PokiStorage = .live) throws -> Int {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = (json["data"] ?? json["models"]) as? [[String: Any]] else { throw DiscoveryError.malformed }
        var ids = listedIDs(items, provider)
        guard !ids.isEmpty else { throw DiscoveryError.malformed }
        if provider == .openai {
            let voice = items.compactMap { $0["id"] as? String }.filter { $0.contains("realtime") && !$0.contains("transcribe") }.sorted()
            storage.defaults.set(voice, forKey: "models.listed.voice")
        }
        if provider == .openrouter {
            let reasoning = items.compactMap { item -> String? in
                guard let id = item["id"] as? String, usable(id, provider),
                      let parameters = item["supported_parameters"] as? [String],
                      parameters.contains("reasoning") || parameters.contains("reasoning_effort") else { return nil }
                return id
            }
            storage.defaults.set(Array(Set(reasoning)).sorted(), forKey: "models.reasoning.openrouter")
        }
        ids = Array(Set(ids)).sorted { fast($0) == fast($1) ? $0 < $1 : fast($0) }
        storage.defaults.set(ids, forKey: "models.listed.\(provider.rawValue)")
        storage.defaults.set(Date().timeIntervalSince1970, forKey: "models.listedAt.\(provider.rawValue)")
        storage.defaults.removeObject(forKey: "models.failures.\(provider.rawValue)")
        storage.defaults.removeObject(forKey: "models.failedAt.\(provider.rawValue)")
        ModelKeys.saved += 1
        return ids.count
    }

    /// The chat model ids of a provider's list. Codex's list names models by `slug` and hides some
    /// (`visibility` "hide"); the others by `id` or, for Gemini, `name`.
    static func listedIDs(_ items: [[String: Any]], _ provider: ModelProvider) -> [String] {
        items.compactMap { item -> String? in
            if let visibility = item["visibility"] as? String, visibility != "list" { return nil }
            return (item["slug"] as? String) ?? (item["id"] as? String) ?? (item["name"] as? String)
        }
        .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        .filter { usable($0, provider) }
    }

    // MARK: Keeping lists current

    /// How old a list may get before Poki reads it again by itself.
    static let listLifetime: TimeInterval = 24 * 60 * 60

    /// The providers whose model list Poki reads for the owner: those with a key, ChatGPT once signed in
    /// to Codex, and custom providers with an address.
    static func listable(storage: PokiStorage = .live) -> [ModelProvider] {
        ModelProvider.allCases.filter { provider in
            switch provider {
            case .chatgpt: CodexAccount.hasStoredCredential(service: storage.codexService, home: storage.codexHome)
            case .custom: !CustomProviders.all(in: storage).isEmpty
            default: ModelKeys.hasKey(provider, storage: storage)
            }
        }
    }

    /// One model list Poki keeps: a provider's, or one custom provider's (each has its own age and its
    /// own wait after a failure, so one unreachable address does not hold back the others).
    enum ModelList: Hashable, Sendable {
        case provider(ModelProvider)
        case custom(UUID)

        var storeSuffix: String {
            switch self {
            case .provider(let provider): provider.rawValue
            case .custom(let id): "custom.\(id.uuidString)"
            }
        }
    }

    /// Every list Poki reads for the owner (`listable`, with each custom provider on its own).
    static func lists(storage: PokiStorage = .live) -> [ModelList] {
        listable(storage: storage).flatMap { provider -> [ModelList] in
            provider == .custom ? CustomProviders.all(in: storage).map { .custom($0.id) } : [.provider(provider)]
        }
    }

    /// The list is missing or older than `listLifetime`.
    static func isStale(_ list: ModelList, now: Date = Date(), storage: PokiStorage = .live) -> Bool {
        let at = storage.defaults.double(forKey: "models.listedAt.\(list.storeSuffix)")
        return at == 0 || now.timeIntervalSince1970 - at > listLifetime
    }

    /// For custom providers, any of them.
    static func isStale(_ provider: ModelProvider, now: Date = Date(), storage: PokiStorage = .live) -> Bool {
        guard provider == .custom else { return isStale(.provider(provider), now: now, storage: storage) }
        return CustomProviders.all(in: storage).contains { isStale(.custom($0.id), now: now, storage: storage) }
    }

    /// After a failed background read, how long Poki waits before trying again by itself: an hour, then
    /// twice as long after each further failure, up to a day. Refresh Model List always reads at once.
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60 * 60 * pow(2, Double(min(failures, 16) - 1)), listLifetime)
    }

    /// A background read failed a short while ago (offline, a refused key, a sign-in to renew).
    static func isBackingOff(_ list: ModelList, now: Date = Date(), storage: PokiStorage = .live) -> Bool {
        let failures = storage.defaults.integer(forKey: "models.failures.\(list.storeSuffix)")
        let at = storage.defaults.double(forKey: "models.failedAt.\(list.storeSuffix)")
        return failures > 0 && now.timeIntervalSince1970 - at < backoff(failures: failures)
    }

    /// For custom providers, all of them (none is due by itself).
    static func isBackingOff(_ provider: ModelProvider, now: Date = Date(), storage: PokiStorage = .live) -> Bool {
        guard provider == .custom else { return isBackingOff(.provider(provider), now: now, storage: storage) }
        let all = CustomProviders.all(in: storage)
        return !all.isEmpty && all.allSatisfy { isBackingOff(.custom($0.id), now: now, storage: storage) }
    }

    static func noteFailure(_ list: ModelList, now: Date = Date(), storage: PokiStorage = .live) {
        let key = "models.failures.\(list.storeSuffix)"
        storage.defaults.set(storage.defaults.integer(forKey: key) + 1, forKey: key)
        storage.defaults.set(now.timeIntervalSince1970, forKey: "models.failedAt.\(list.storeSuffix)")
    }

    static func clearFailures(_ list: ModelList, storage: PokiStorage = .live) {
        storage.defaults.removeObject(forKey: "models.failures.\(list.storeSuffix)")
        storage.defaults.removeObject(forKey: "models.failedAt.\(list.storeSuffix)")
    }

    /// A new key or sign-in is worth reading at once: forget the failures of the old one.
    static func clearFailures(_ provider: ModelProvider, storage: PokiStorage = .live) {
        if provider == .custom {
            for custom in CustomProviders.all(in: storage) { clearFailures(.custom(custom.id), storage: storage) }
        } else {
            clearFailures(.provider(provider), storage: storage)
        }
    }

    @MainActor private static var refreshing: Set<ModelList> = []

    /// The lists `refreshStale` reads now: missing or a day old, and not backing off after a failure.
    static func dueForBackgroundRefresh(now: Date = Date(), storage: PokiStorage = .live) -> [ModelList] {
        lists(storage: storage).filter { isDue($0, now: now, storage: storage) }
    }

    static func isDue(_ list: ModelList, now: Date = Date(), storage: PokiStorage = .live) -> Bool {
        isStale(list, now: now, storage: storage) && !isBackingOff(list, now: now, storage: storage)
    }

    /// A read that ended because it was cancelled (the app went away, the account changed), not a failure.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    /// Reads again, side by side, every list that is missing or a day old, so models a provider adds show
    /// up without a Poki release. A failure keeps the last list (the bundled models always stay) and
    /// backs off. Each list is checked again just before it is read, in case another read got there first.
    @MainActor
    static func refreshStale(storage: PokiStorage = .live) async {
        await withTaskGroup(of: Void.self) { group in
            for list in dueForBackgroundRefresh(storage: storage) {
                group.addTask { @MainActor in
                    guard !ModelCatalog.refreshing.contains(list), ModelCatalog.isDue(list, storage: storage) else { return }
                    ModelCatalog.refreshing.insert(list)
                    defer { ModelCatalog.refreshing.remove(list) }
                    do {
                        switch list {
                        case .provider(let provider): _ = try await ModelCatalog.refresh(provider, storage: storage)
                        case .custom(let id): _ = try await ModelCatalog.refresh(custom: id, storage: storage)
                        }
                        ModelCatalog.clearFailures(list, storage: storage)
                    } catch let error where ModelCatalog.isCancellation(error) {
                        // Cancelled, not failed: no wait before the next read.
                    } catch {
                        ModelCatalog.noteFailure(list, storage: storage)
                    }
                }
            }
        }
    }

    /// Reads one custom provider's model list, from its first address that answers, with its key
    /// (sent only to that service). Its Realtime models go to its live voice list.
    @MainActor
    static func refresh(custom id: UUID, storage: PokiStorage = .live) async throws -> Int {
        guard let provider = CustomProviders.provider(id, storage: storage) else { return 0 }
        let key = CustomProviders.key(id, storage: storage)
        let revision = storage.defaults.string(forKey: "models.revision.custom.\(id.uuidString)")
        let addresses = provider.endpoints.map(\.normalized).filter { !$0.isEmpty }
        var raw: [String]?
        var failure: Error = DiscoveryError.invalidAddress
        for address in addresses {
            do { raw = try await fetchCustomIDs(address: address, key: key); break }
            catch is CancellationError { throw CancellationError() }
            catch let error as DiscoveryError where error == .network || error == .server { failure = error }
            catch { failure = error; break }
        }
        guard let raw else { throw failure }
        try Task.checkCancellation()
        guard let now = CustomProviders.provider(id, storage: storage), now.endpoints.map(\.normalized).filter({ !$0.isEmpty }) == addresses,
              key == CustomProviders.key(id, storage: storage),
              revision == storage.defaults.string(forKey: "models.revision.custom.\(id.uuidString)") else {
            throw CancellationError()
        }
        let ids = chatIDs(raw)
        storage.defaults.set(ids, forKey: "models.listed.custom.\(id.uuidString)")
        storage.defaults.set(Date().timeIntervalSince1970, forKey: "models.listedAt.custom.\(id.uuidString)")
        clearFailures(.custom(id), storage: storage)
        storage.defaults.set(voiceIDs(raw), forKey: "models.listed.voice.custom.\(id.uuidString)")
        ModelKeys.saved += 1
        return ids.count
    }

    /// The Realtime models in a list: live voice can use them.
    static func voiceIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.filter { $0.contains("realtime") && !$0.contains("transcribe") })).sorted()
    }

    /// Chat models only: no embeddings, speech, images or moderation.
    private static func usable(_ id: String, _ provider: ModelProvider) -> Bool {
        let lower = id.lowercased()
        let skip = ["embed", "audio", "realtime", "transcribe", "tts", "whisper", "image", "dall-e", "moderation", "search", "aqa", "imagen", "veo"]
        if skip.contains(where: lower.contains) { return false }
        switch provider {
        case .openai, .chatgpt: return lower.hasPrefix("gpt-") || lower.hasPrefix("o")
        case .anthropic: return lower.hasPrefix("claude")
        case .gemini: return lower.hasPrefix("gemini")
        default: return true
        }
    }

    private static func request(_ provider: ModelProvider, storage: PokiStorage = .live) -> URLRequest? {
        let key = ModelKeys.key(provider, storage: storage)
        var request: URLRequest
        switch provider {
        case .openai:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepseek:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            guard let key, var parts = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return nil }
            parts.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "200")]
            request = URLRequest(url: parts.url!)
        case .openrouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .custom:
            return try? customRequest(address: ModelKeys.customURL(in: storage), key: key)
        case .chatgpt:
            // Read with the Codex sign-in's token (`codexModelsRequest`), which needs a refresh first.
            return nil
        }
        request.timeoutInterval = 15
        return request
    }

    /// The Codex client version Poki's list request names; Codex answers with the models that version
    /// can run.
    static let codexClientVersion = "0.164.0"

    /// The ChatGPT plan's model list, as the Codex CLI reads it (sent only to chatgpt.com).
    static func codexModelsRequest(accessToken: String) -> URLRequest? {
        guard let account = CodexAccount.chatGPTAccountID(accessToken),
              var parts = URLComponents(string: "https://chatgpt.com/backend-api/codex/models") else { return nil }
        parts.queryItems = [URLQueryItem(name: "client_version", value: codexClientVersion)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("pi", forHTTPHeaderField: "originator")
        request.timeoutInterval = 15
        return request
    }

    // MARK: Custom endpoint discovery

    enum DiscoveryError: Error, Equatable {
        case invalidAddress, authentication, permission, unsupported, rateLimited, server, malformed, network
        /// The ChatGPT sign-in has expired or was refused: no key to check, a sign-in to do again.
        case signIn

        var message: String {
            switch self {
            case .invalidAddress: AppLocalization.text("Enter a valid HTTP or HTTPS service address.")
            case .authentication: AppLocalization.text("Authentication failed. Check the API key.")
            case .permission: AppLocalization.text("The service refused access to its model list.")
            case .unsupported: AppLocalization.text("This service does not offer a model list. Enter a model ID manually.")
            case .rateLimited: AppLocalization.text("Too many requests. Try again later.")
            case .server: AppLocalization.text("The service could not return its model list. Try again later.")
            case .malformed: AppLocalization.text("The service returned an invalid model list.")
            case .network: AppLocalization.text("Could not reach the service. Check the connection and try again.")
            case .signIn: AppLocalization.text("Sign in to ChatGPT again to read its model list.")
            }
        }
    }

    static func normalizedAddress(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func customRequest(address: String, key: String?) throws -> URLRequest {
        guard let parts = URLComponents(string: normalizedAddress(address)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw DiscoveryError.invalidAddress }
        var request = URLRequest(url: url.appending(path: "models"))
        request.timeoutInterval = 15
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Uses draft credentials without changing the account or its cached models.
    static func fetchCustom(address: String, key: String?, session: URLSession = .shared) async throws -> [String] {
        chatIDs(try await fetchCustomIDs(address: address, key: key, session: session))
    }

    /// The chat models of a list, fast ones first.
    private static func chatIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.filter { usable($0, .custom) })).sorted { fast($0) == fast($1) ? $0 < $1 : fast($0) }
    }

    /// Every model id a custom address lists, chat or not.
    static func fetchCustomIDs(address: String, key: String?, session: URLSession = .shared) async throws -> [String] {
        let request = try customRequest(address: address, key: key)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw DiscoveryError.network }
        try Task.checkCancellation()
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: break
        case 401: throw DiscoveryError.authentication
        case 403: throw DiscoveryError.permission
        case 404, 405: throw DiscoveryError.unsupported
        case 429: throw DiscoveryError.rateLimited
        default: throw DiscoveryError.server
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = (json["data"] ?? json["models"]) as? [[String: Any]] else {
            throw DiscoveryError.malformed
        }
        return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Forgets one custom provider's model list. Also invalidates in-flight refreshes, including an
    /// address changed away and back again.
    static func invalidateCustom(_ id: UUID, storage: PokiStorage = .live) {
        storage.defaults.removeObject(forKey: "models.listed.custom.\(id.uuidString)")
        storage.defaults.removeObject(forKey: "models.listedAt.custom.\(id.uuidString)")
        clearFailures(.custom(id), storage: storage)
        storage.defaults.set(UUID().uuidString, forKey: "models.revision.custom.\(id.uuidString)")
    }

    /// Every custom provider's.
    static func invalidateCustom(storage: PokiStorage = .live) {
        for provider in CustomProviders.all(in: storage) { invalidateCustom(provider.id, storage: storage) }
    }

    // MARK: Voice

    /// Live voice models (Realtime): for OpenAI the built-in one and any the key's list adds, off at
    /// first; for a custom provider the Realtime models its list names (the built-in one's name until it
    /// has been read).
    static let voiceDefault = "gpt-live-1.1"
    static let voiceRealtime = "gpt-realtime-2.1"

    static func voiceChoices(for account: VoiceAccount, storage: PokiStorage = .live) -> [ChatModelChoice] {
        switch account {
        case .openai:
            let listed = (storage.defaults.stringArray(forKey: "models.listed.voice") ?? []).filter { $0 != voiceDefault && $0 != voiceRealtime }
            return [ChatModelChoice(id: voiceDefault, name: "GPT-Live 1.1"), ChatModelChoice(id: voiceRealtime, name: "GPT Realtime 2.1")]
                + listed.map { ChatModelChoice(id: $0, name: $0) }
        case .custom(let id):
            let listed = storage.defaults.stringArray(forKey: "models.listed.voice.custom.\(id.uuidString)") ?? []
            return (listed.isEmpty ? [voiceRealtime] : listed).map { ChatModelChoice(id: $0, name: $0) }
        }
    }

    static func voiceOn(for account: VoiceAccount, storage: PokiStorage = .live) -> Set<String> {
        if let saved = storage.defaults.stringArray(forKey: "models.enabled.voice" + account.storeSuffix) { return Set(saved) }
        switch account {
        case .openai: return [voiceDefault]
        case .custom: return Set(voiceChoices(for: account, storage: storage).prefix(1).map(\.id))
        }
    }

    static func setVoice(_ id: String, on: Bool, for account: VoiceAccount? = nil, storage: PokiStorage = .live) {
        let account = account ?? VoiceDirect.settingsAccount(in: storage)
        var ids = voiceOn(for: account, storage: storage)
        if on { ids.insert(id) } else { ids.remove(id) }
        storage.defaults.set(Array(ids), forKey: "models.enabled.voice" + account.storeSuffix)
        if !ids.contains(voiceModelID(for: account, storage: storage)) {
            setVoiceModelID(voiceModelID(for: account, storage: storage), for: account, storage: storage)
        }
        ModelKeys.saved += 1
    }

    static func voiceOffered(for account: VoiceAccount, storage: PokiStorage = .live) -> [ChatModelChoice] {
        let on = voiceOn(for: account, storage: storage)
        return voiceChoices(for: account, storage: storage).filter { on.contains($0.id) }
    }

    /// An account's live voice model.
    static func voiceModelID(for account: VoiceAccount, storage: PokiStorage = .live) -> String {
        let fallback = voiceOffered(for: account, storage: storage).first?.id ?? voiceChoices(for: account, storage: storage).first?.id ?? voiceDefault
        let saved = storage.defaults.string(forKey: "voice.model" + account.storeSuffix) ?? fallback
        return voiceOn(for: account, storage: storage).contains(saved) ? saved : fallback
    }

    static func setVoiceModelID(_ id: String, for account: VoiceAccount, storage: PokiStorage = .live) {
        storage.defaults.set(id, forKey: "voice.model" + account.storeSuffix)
        ModelKeys.saved += 1
    }

    // The account live voice runs on (OpenAI until a custom provider has live voice on).
    static var voiceAll: [ChatModelChoice] { voiceChoices(for: VoiceDirect.settingsAccount) }
    static var voiceEnabled: Set<String> { voiceOn(for: VoiceDirect.settingsAccount) }
    static var voiceAvailable: [ChatModelChoice] { voiceOffered(for: VoiceDirect.settingsAccount) }

    /// The live voice model of the account live voice runs on.
    static var voiceModel: String {
        get { voiceModelID(for: VoiceDirect.settingsAccount) }
        set { setVoiceModelID(newValue, for: VoiceDirect.settingsAccount) }
    }
}

/// Models newer than the pinned PiSwift catalog (f869652), set up as PiSwift's next catalog (17c490d)
/// lists them: each copies a model the catalog has, with the same API, inputs and thinking levels (GPT-6.2
/// rejects reasoning effort `none`, as GPT-6.1 Sol's setup already says), and changes what differs. A
/// catalog that lists the model wins (`ModelProvider.knownModel`), so these fall away with the next bump.
enum BundledModelSetups {
    struct Setup: Sendable {
        var template: String
        var name: String
        var cost: ModelCost?
        /// Per pi provider, where the window differs from the template's.
        var contextWindow: [String: Int] = [:]
        /// Also set up behind a gateway (`openai/<id>` on OpenRouter). GPT-6.1 Terra is not: OpenRouter
        /// rejects the thinking Sol's setup would send it, so it keeps the plain unlisted setup.
        var onGateways = false
    }

    static let all: [String: Setup] = [
        // pi-ai 1.5.0 lists gpt-6.1-terra with the same API and inputs as gpt-6.1-sol.
        "gpt-6.1-terra": Setup(template: "gpt-6.1-sol", name: "GPT-6.1 Terra"),
        // GPT-6.2 Sol keeps GPT-6.1 Sol's prices and windows.
        "gpt-6.2-sol": Setup(template: "gpt-6.1-sol", name: "GPT-6.2 Sol", onGateways: true),
        "gpt-6.2-astra": Setup(
            template: "gpt-6.1-sol", name: "GPT-6.2 Astra",
            cost: ModelCost(input: 8, output: 40, cacheRead: 0.4, cacheWrite: 10,
                            tiers: [ModelCostTier(inputTokensAbove: 272_000, input: 16, output: 60, cacheRead: 0.8, cacheWrite: 20)]),
            contextWindow: ["openai-codex": 272_000], onGateways: true),
    ]

    static func apply(_ setup: Setup, id: String, provider: String, to base: Model) -> Model? {
        copy(base, id: id, name: setup.name, cost: setup.cost, contextWindow: setup.contextWindow[provider])
    }

    /// `base` with another id and name, and the prices and window given.
    static func copy(_ base: Model, id: String, name: String, cost: ModelCost? = nil, contextWindow: Int? = nil) -> Model? {
        guard var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any] else { return nil }
        json["id"] = id
        json["name"] = name
        if let cost, let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(cost)) { json["cost"] = encoded }
        if let contextWindow { json["contextWindow"] = contextWindow }
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(Model.self, from: $0) }
    }
}
