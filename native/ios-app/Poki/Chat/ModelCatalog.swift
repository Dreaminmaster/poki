import Foundation

/// The models each account offers the text chat: a few fast defaults per type (no-thinking models such
/// as GPT-6.1 Terra and Claude Haiku first), plus whatever the provider's own model list returns for
/// the owner's key, which start switched off. The owner switches models on and off in Accounts ›
/// the account › Text Chat; the chat's model menu offers only the ones switched on.
enum ModelCatalog {
    /// The defaults, switched on until the owner turns them off.
    static func defaults(_ provider: ModelProvider, storage: PokiStorage = .live) -> Set<String> {
        switch provider {
        case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .openai, .chatgpt: ["gpt-6.1-terra"]
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

    /// Until the owner ticks models, the defaults and the recommended ones of the provider's list
    /// (Terra, Haiku, Sonnet, Flash) are ticked.
    static func enabled(_ provider: ModelProvider, storage: PokiStorage = .live) -> Set<String> {
        if let saved = storage.defaults.stringArray(forKey: "models.enabled.\(provider.rawValue)") { return Set(saved) }
        return defaults(provider, storage: storage).union(listed(provider, storage: storage).map(\.id).filter(recommended))
    }

    /// The models ticked for a new provider: the fast ones and the everyday ones, without a dated
    /// snapshot or a preview. A custom model id is read after its provider's prefix.
    static func recommended(_ id: String) -> Bool {
        let model = (CustomProviders.parse(id)?.model ?? id).lowercased()
        let name = model.split(separator: "/").last.map(String.init) ?? model
        guard !name.contains("preview"), !name.contains("exp"), name.range(of: #"\d{4}-?\d{2}-?\d{2}"#, options: .regularExpression) == nil else { return false }
        return ["terra", "haiku", "sonnet", "flash"].contains { name.contains($0) }
    }

    static func set(_ id: String, on: Bool, for provider: ModelProvider, notify: Bool = true, storage: PokiStorage = .live) {
        var ids = enabled(provider, storage: storage)
        if on { ids.insert(id) } else { ids.remove(id) }
        storage.defaults.set(Array(ids), forKey: "models.enabled.\(provider.rawValue)")
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
        guard let request = request(provider, storage: storage) else { return 0 }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        var ids = items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { usable($0, provider) }
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
        ModelKeys.saved += 1
        return ids.count
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
        case .openai: return lower.hasPrefix("gpt-") || lower.hasPrefix("o")
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
            // A ChatGPT sign-in has no model list; its plan's models are the built-in ones.
            return nil
        }
        request.timeoutInterval = 15
        return request
    }

    // MARK: Custom endpoint discovery

    enum DiscoveryError: Error, Equatable {
        case invalidAddress, authentication, permission, unsupported, rateLimited, server, malformed, network

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
