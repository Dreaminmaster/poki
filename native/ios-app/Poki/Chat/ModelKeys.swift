import Foundation
import PiSwiftAI

/// The model providers the chat can use with the owner's own key or account (ESP-171 board "M Model").
/// The wired ones run through pi (PiLoop); the others store their key and address for a later step.
enum ModelProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai, chatgpt, deepseek, gemini, openrouter, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .chatgpt: "ChatGPT"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini"
        case .openrouter: "OpenRouter"
        case .custom: AppLocalization.text(LocalizedStringResource("Custom Endpoint"))
        }
    }

    /// The letter on the coloured tile, and the tile's colour (from the board).
    var mark: String {
        switch self {
        case .anthropic: "A"
        case .openai: "O"
        case .chatgpt: "C"
        case .deepseek: "D"
        case .gemini: "G"
        case .openrouter: "R"
        case .custom: "{ }"
        }
    }

    var tile: UInt32 {
        switch self {
        case .anthropic: 0xD97757
        case .openai: 0x111111
        case .chatgpt: 0x10A37F
        case .deepseek: 0x4D6BFE
        case .gemini: 0x4285F4
        case .openrouter: 0x6566F1
        case .custom: 0x8E8E93
        }
    }

    /// pi's provider id (PiSwiftAI's catalog).
    var piProvider: String? {
        switch self {
        case .anthropic: "anthropic"
        case .openai: "openai"
        // Sign in with ChatGPT (OpenAI's open-source flow) runs on the OpenAI API with the plan's token.
        case .chatgpt: "openai"
        case .deepseek: "deepseek"
        case .gemini: "google"
        case .openrouter: "openrouter"
        case .custom: "poki-custom"
        }
    }

    /// The chat runs on this provider today (all of them, through pi).
    var wired: Bool { piProvider != nil }

    /// ChatGPT is an account the owner signs in to; the others take a key.
    var signsIn: Bool { self == .chatgpt }

    /// What a key looks like, for the field's placeholder.
    var keyPrompt: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai, .deepseek: "sk-…"
        case .chatgpt: ""
        case .gemini: "AIza…"
        case .openrouter: "sk-or-…"
        case .custom: AppLocalization.text(LocalizedStringResource("API key, if it needs one"))
        }
    }

    var models: [ChatModelChoice] { models(in: .live) }

    func models(in storage: PokiStorage = .live) -> [ChatModelChoice] {
        switch self {
        case .anthropic: [
            ChatModelChoice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
            ChatModelChoice(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
            ChatModelChoice(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        ]
        // GPT-6.1 Terra first, the owner's choice for the chat (ESP-174); GPT-6.2 Sol and Astra
        // (developers.openai.com/api/docs/models, November 2026) and GPT-6.1 Sol stay selectable. This is
        // only the fallback: the key's own model list adds newer models without a release.
        case .openai: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
            ChatModelChoice(id: "gpt-6.2-sol", name: "GPT-6.2 Sol"),
            ChatModelChoice(id: "gpt-6.2-astra", name: "GPT-6.2 Astra"),
            ChatModelChoice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        ]
        // The ChatGPT plan's models (GPT-6.2 is in Plus, Pro, Enterprise and Edu plans); gpt-6.1-terra is
        // also Poki Agent's default on the Mac (agent/model-config.mjs). A Codex sign-in adds the plan's
        // current list (`ModelCatalog.codexModelsRequest`).
        case .chatgpt: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "ChatGPT GPT-6.1 Terra"),
            ChatModelChoice(id: "gpt-6.2-sol", name: "ChatGPT GPT-6.2 Sol"),
            ChatModelChoice(id: "gpt-6.2-astra", name: "ChatGPT GPT-6.2 Astra"),
            ChatModelChoice(id: "gpt-6.1-sol", name: "ChatGPT GPT-6.1 Sol"),
        ]
        // DeepSeek's current names (api-docs.deepseek.com, 2026-11-07); deepseek-chat is retired. V4 Pro
        // reads text only, so it does not see the screenshots.
        case .deepseek: [
            ChatModelChoice(id: "deepseek-flash", name: "DeepSeek V4.1 Flash"),
            ChatModelChoice(id: "deepseek-v4-pro", name: AppLocalization.text(LocalizedStringResource("DeepSeek V4 Pro (no screenshots)"))),
        ]
        // pi's google provider (Gemini API), both reading screenshots.
        case .gemini: [
            ChatModelChoice(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
            ChatModelChoice(id: "gemini-4-argon", name: "Gemini 4 Argon"),
        ]
        // One OpenRouter key, the main labs' models (PiSwift's openrouter catalog).
        case .openrouter: [
            ChatModelChoice(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5 (OpenRouter)"),
            ChatModelChoice(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5 (OpenRouter)"),
            ChatModelChoice(id: "openai/gpt-6.2-sol", name: "GPT-6.2 Sol (OpenRouter)"),
            ChatModelChoice(id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol (OpenRouter)"),
            ChatModelChoice(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash (OpenRouter)"),
        ]
        // Whatever model each of the owner's services serves (a local server, a company gateway), named
        // with its service once there is more than one.
        case .custom:
            Self.customChoices(CustomProviders.all(in: storage))
        }
    }

    /// Where the owner creates a key.
    var keyHelp: String {
        switch self {
        // Claude.ai sign-in is for Anthropic's own apps only; Max and Team plans include monthly API credits.
        case .anthropic: AppLocalization.text(LocalizedStringResource("Create a key at console.anthropic.com, then paste it here. On a Claude Max or Team plan, first claim your plan’s monthly API credits in claude.ai › Settings › Billing, so the key uses them."))
        case .openai: AppLocalization.text(LocalizedStringResource("Create a key at platform.openai.com, then paste it here."))
        case .deepseek: AppLocalization.text(LocalizedStringResource("Create a key at platform.deepseek.com, then paste it here."))
        case .gemini: AppLocalization.text(LocalizedStringResource("Create a key at aistudio.google.com, then paste it here."))
        case .openrouter: AppLocalization.text(LocalizedStringResource("Create a key at openrouter.ai/keys, then paste it here."))
        case .custom: AppLocalization.text(LocalizedStringResource("Any server that speaks the OpenAI Responses API or chat completions API. Poki sends the key, if any, only to this service’s addresses."))
        default: ""
        }
    }

    /// Each custom provider's own model, as the chat names it.
    static func customChoices(_ providers: [CustomProvider]) -> [ChatModelChoice] {
        providers.flatMap { provider -> [ChatModelChoice] in
            guard provider.primary != nil else { return [] }
            let models = ([provider.model] + (provider.added ?? [])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return models.map {
                ChatModelChoice(id: CustomProviders.choiceID(provider.id, $0), name: CustomProviders.choiceName(provider, $0, among: providers.count))
            }
        }
    }

    /// The setup of a model pi's catalog does not list: plain text and image input, no cost, a modest window.
    private static let unlistedContextWindow = 128_000
    private static let unlistedMaxTokens = 8_192
    private static let openRouterBaseURL = "https://openrouter.ai/api/v1"

    private func unlistedModel(_ id: String, provider: String, baseUrl: String, reasoning: Bool = false) -> Model {
        Model(id: id, name: id, api: .openAICompletions, provider: provider, baseUrl: baseUrl, reasoning: reasoning,
              input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
              contextWindow: Self.unlistedContextWindow, maxTokens: Self.unlistedMaxTokens,
              thinkingLevelMap: reasoning ? [.off: nil] : nil)
    }

    /// A custom address's model, set up like the official provider's where Poki can tell: the address's
    /// API (Responses or chat completions), and for a model id pi's catalog knows (`gpt-6.1-sol`, or
    /// `openai/gpt-6.1-sol` behind a gateway) that model's reasoning, inputs, window and output size, so
    /// a third party serving an official model gets what the official account gets. `reasoning` is the
    /// owner's choice and wins over the catalog; without either the model does not reason. The
    /// catalog's prices and provider quirks are not taken: they are the original provider's.
    static func customModel(_ id: String, baseUrl: String, api: Api, reasoning: Bool?, piProvider: String = "poki-custom") -> Model {
        let known = catalogMatch(id)
        let thinks = reasoning ?? known?.reasoning ?? false
        let map: ThinkingLevelMap? = thinks ? ((known?.reasoning == true ? known?.thinkingLevelMap : nil) ?? [.off: nil]) : nil
        return Model(id: id, name: id, api: api, provider: piProvider, baseUrl: baseUrl,
                     reasoning: thinks, input: known?.input ?? [.text, .image],
                     cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                     contextWindow: known?.contextWindow ?? unlistedContextWindow,
                     maxTokens: known?.maxTokens ?? (thinks ? unlistedReasoningMaxTokens : unlistedMaxTokens),
                     thinkingLevelMap: map)
    }

    /// Room for a reasoning model's thinking and its answer when the catalog does not say.
    private static let unlistedReasoningMaxTokens = 32_768

    /// Prefer a named model vendor's catalog over a gateway entry for the qualified model ID.
    static func catalogMatch(_ id: String) -> Model? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let providers = ["openai", "anthropic", "google", "deepseek"] + getProviders().map(\.rawValue).sorted()
        let parts = trimmed.split(separator: "/").map(String.init)
        let unqualified = parts.last ?? trimmed
        // A model the catalog lacks under this id takes its bundled setup (see `knownModel`).
        if let vendor = parts.dropLast().last,
           let model = knownModel(provider: vendor.lowercased(), id: unqualified) { return model }
        let ids = unqualified == trimmed ? [trimmed] : [trimmed, unqualified]
        for candidate in ids {
            for provider in providers {
                if let model = knownModel(provider: provider, id: candidate) { return model }
            }
        }
        return nil
    }

    /// pi's catalog model, or for an id the catalog lacks its bundled setup: a copy of the model it is set
    /// up like, with its own id, name, prices and window (`BundledModelSetups`). The catalog's entry wins.
    static func knownModel(provider: String, id: String) -> Model? {
        if let model = getModel(provider: provider, modelId: id) { return model }
        // A gateway names a vendor's model with the vendor first (OpenRouter's `openai/gpt-6.2-sol`); its
        // template is the gateway's entry for the template model (`openai/gpt-6.1-sol`).
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let vendor = parts.count == 2 ? parts[0] + "/" : ""
        guard let setup = BundledModelSetups.all[parts.last ?? id], vendor.isEmpty || setup.onGateways,
              let base = getModel(provider: provider, modelId: vendor + setup.template) else { return nil }
        return BundledModelSetups.apply(setup, id: id, provider: provider, to: base)
    }

    /// pi's model for one of `models`. For a custom provider `id` is the chat's id (provider and model,
    /// `CustomProviders.choiceID`) and the model goes to the provider's first address in its API. With
    /// `customURL`, an address not saved yet (the connection test on the editing page), `id` is the bare
    /// model id and `customAPI` and `customReasoning` are the page's choices.
    func piModel(_ id: String, customURL: String? = nil, customAPI: CustomAPIStyle = .chatCompletions, customReasoning: Bool? = nil,
                 codexService: String? = nil, codexHome: URL? = nil,
                 storage: PokiStorage? = nil) -> Model? {
        let resolvedStorage = storage ?? .live
        let resolvedCodexService = codexService ?? storage?.codexService ?? CodexAccount.defaultService
        let resolvedCodexHome = codexHome ?? storage?.codexHome ?? CodexAccount.home
        let provider = self == .chatgpt && CodexAccount.readAccessToken(service: resolvedCodexService, home: resolvedCodexHome) != nil ? "openai-codex" : piProvider
        guard let piProvider = provider else { return nil }
        if self == .custom {
            if let customURL {
                let base = customURL.trimmingCharacters(in: .whitespaces)
                guard !base.isEmpty, !id.isEmpty else { return nil }
                return Self.customModel(id, baseUrl: base, api: customAPI.piAPI, reasoning: customReasoning, piProvider: piProvider)
            }
            guard let chosen = CustomProviders.parse(id), let provider = CustomProviders.provider(chosen.provider, storage: resolvedStorage),
                  let endpoint = provider.primary else { return nil }
            return Self.customModel(chosen.model, baseUrl: endpoint.normalized, api: endpoint.sent.piAPI,
                                    reasoning: provider.reasoning, piProvider: provider.piProvider)
        }
        if let model = Self.knownModel(provider: piProvider, id: id) { return model }
        // OpenRouter serves thousands of models its catalog lacks, and a built-in model's setup (Anthropic
        // thinking on the Messages API) is rejected by many of them. Take the plain chat setup, and add
        // reasoning only for a model OpenRouter's own list says supports it.
        if self == .openrouter {
            return unlistedModel(id, provider: piProvider, baseUrl: Self.openRouterBaseURL,
                                 reasoning: ModelCatalog.supportsReasoning(id, for: self, storage: resolvedStorage))
        }
        // A model from the provider's own list that pi's catalog lacks takes the shape of a built-in one of
        // the same provider (same API and inputs), with its own id.
        guard let base = models(in: resolvedStorage).lazy.compactMap({ getModel(provider: piProvider, modelId: $0.id) }).first else { return nil }
        return BundledModelSetups.copy(base, id: id, name: id)
    }
}

struct ChatModelChoice: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// The owner's keys and the ChatGPT sign-in, in this iPhone's keychain (the relay key's service, one
/// account per provider). A key is only ever sent to its own provider. Nothing here prints or logs a key
/// or a token.
enum ModelKeys {
    @TaskLocal static var defaultService = "nz.zheha.poki"

    private static func account(_ provider: ModelProvider) -> String { "model-key.\(provider.rawValue)" }

    /// For a custom provider, the key of the one the chat uses now (`CustomProviders.current`).
    static func key(_ provider: ModelProvider, storage: PokiStorage) -> String? {
        if provider == .custom { return CustomProviders.current(in: storage).flatMap { CustomProviders.key($0.id, storage: storage) } }
        return key(provider, service: storage.keychainService)
    }

    static func key(_ provider: ModelProvider, service: String = defaultService) -> String? {
        if provider == .custom { return CustomProviders.current.flatMap { CustomProviders.key($0.id) } }
        guard let data = try? Keychain.read(account(provider), service: service), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(_ provider: ModelProvider, storage: PokiStorage) -> Bool {
        key(provider, storage: storage) != nil
    }

    static func hasKey(_ provider: ModelProvider, service: String = defaultService) -> Bool { key(provider, service: service) != nil }

    static func save(_ key: String, for provider: ModelProvider, storage: PokiStorage) throws {
        if provider == .custom {
            let current = CustomProviders.current(in: storage) ?? CustomProviders.upsert(CustomProvider(), storage: storage)
            return try CustomProviders.saveKey(key, for: current.id, storage: storage)
        }
        try save(key, for: provider, service: storage.keychainService)
    }

    static func save(_ key: String, for provider: ModelProvider, service: String = defaultService) throws {
        if provider == .custom {
            let current = CustomProviders.current ?? CustomProviders.upsert(CustomProvider())
            return try CustomProviders.saveKey(key, for: current.id)
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.write(Data(trimmed.utf8), account: account(provider), service: service)
        saved += 1
    }

    static func remove(_ provider: ModelProvider, storage: PokiStorage) {
        if provider == .custom {
            if let current = CustomProviders.current(in: storage) { CustomProviders.removeKey(current.id, storage: storage) }
            return
        }
        remove(provider, service: storage.keychainService)
    }

    static func remove(_ provider: ModelProvider, service: String = defaultService) {
        if provider == .custom {
            if let current = CustomProviders.current { CustomProviders.removeKey(current.id) }
            return
        }
        try? Keychain.remove(account(provider), service: service)
        saved += 1
    }

    static func removeChatGPTSignIn(storage: PokiStorage) throws {
        try removeChatGPTSignIn(service: storage.keychainService)
    }

    static func removeChatGPTSignIn(service: String = defaultService) throws {
        try Keychain.remove(account(.chatgpt), service: service)
        saved += 1
    }

    /// The first address of the custom provider the chat uses now (not a secret: kept in the app's
    /// settings). Setting it changes that address, or adds a provider when there is none.
    static var customURL: String {
        get { customURL(in: .live) }
        set { setCustomURL(newValue, in: .live) }
    }

    static func customURL(in storage: PokiStorage = .live) -> String {
        CustomProviders.current(in: storage)?.primary?.url ?? ""
    }

    static func setCustomURL(_ value: String, in storage: PokiStorage = .live) {
        editCurrentCustom(in: storage) { provider in
            if provider.endpoints.isEmpty { provider.endpoints = [CustomEndpoint(url: value)] }
            else { provider.endpoints[0].url = value }
        }
    }

    /// The model id of the custom provider the chat uses now.
    static var customModel: String {
        get { customModel(in: .live) }
        set { setCustomModel(newValue, in: .live) }
    }

    static func customModel(in storage: PokiStorage = .live) -> String {
        CustomProviders.current(in: storage)?.model ?? ""
    }

    static func setCustomModel(_ value: String, in storage: PokiStorage = .live) {
        editCurrentCustom(in: storage) { $0.model = value }
    }

    private static func editCurrentCustom(in storage: PokiStorage = .live, _ change: (inout CustomProvider) -> Void) {
        var provider = CustomProviders.current(in: storage) ?? CustomProvider()
        change(&provider)
        CustomProviders.upsert(provider, storage: storage)
        storage.defaults.set(provider.id.uuidString, forKey: CustomProviders.selectedKey)
    }

    /// A different address never inherits the previous service's secret.
    static func customDraftKey(address: String, typedKey: String, storage: PokiStorage = .live) -> String? {
        let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return ModelCatalog.normalizedAddress(address) == ModelCatalog.normalizedAddress(customURL(in: storage)) ? key(.custom, storage: storage) : nil
    }

    /// Saves the custom provider the chat uses now with one address and model (a new one when there is
    /// none) and makes its model the chat's.
    @MainActor
    static func saveCustom(address: String, model: String, typedKey: String, storage: PokiStorage = .live) throws {
        let address = ModelCatalog.normalizedAddress(address)
        let credential = customDraftKey(address: address, typedKey: typedKey, storage: storage)
        var provider = CustomProviders.current(in: storage) ?? CustomProvider()
        provider.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.endpoints.isEmpty { provider.endpoints = [CustomEndpoint(url: address)] } else { provider.endpoints[0].url = address }
        try saveCustom(provider, typedKey: credential ?? "", keepKey: false, storage: storage)
    }

    /// Saves a custom provider from its editing page: the key typed (else, with `keepKey`, the saved
    /// one stays; without it none), its addresses and model, and makes its model the chat's.
    @MainActor
    static func saveCustom(_ provider: CustomProvider, typedKey: String, keepKey: Bool, storage: PokiStorage = .live) throws {
        let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Save the secret first: a keychain failure must not change the addresses or the model.
        if !typed.isEmpty { try CustomProviders.saveKey(typed, for: provider.id, storage: storage) }
        else if !keepKey, CustomProviders.key(provider.id, storage: storage) != nil { CustomProviders.removeKey(provider.id, storage: storage) }
        let saved = CustomProviders.upsert(provider, storage: storage)
        storage.defaults.set(saved.id.uuidString, forKey: CustomProviders.selectedKey)
        guard !saved.model.isEmpty, saved.primary != nil else { return }
        setSelectedProvider(.custom, in: storage)
        setSelectedModel(CustomProviders.choiceID(saved.id, saved.model), in: storage)
    }

    /// The chat can run: the chosen provider is wired and has a key (a custom endpoint: an address and a
    /// model; its key is optional).
    static var hasUsableKey: Bool { hasUsableKey(in: .live) }

    static func hasUsableKey(in storage: PokiStorage = .live) -> Bool {
        let provider = selectedProvider(in: storage)
        if provider == .custom {
            guard let chosen = CustomProviders.parse(selectedModel(in: storage)), let custom = CustomProviders.provider(chosen.provider, storage: storage) else { return false }
            return custom.primary != nil
        }
        if provider == .chatgpt { return ChatGPTAccount.isSignedIn(storage: storage) }
        return provider.wired && hasKey(provider, storage: storage)
    }

    static var selectedProvider: ModelProvider {
        get { selectedProvider(in: .live) }
        set { setSelectedProvider(newValue, in: .live) }
    }

    static func selectedProvider(in storage: PokiStorage = .live) -> ModelProvider {
        storage.defaults.string(forKey: "chat.provider").flatMap(ModelProvider.init(rawValue:)) ?? .anthropic
    }

    static func setSelectedProvider(_ provider: ModelProvider, in storage: PokiStorage = .live) {
        storage.defaults.set(provider.rawValue, forKey: "chat.provider")
        saved += 1
    }

    /// Each provider's model: its first (Claude Sonnet 5.5, GPT-6.1 Terra) unless the owner picks another.
    static func model(for provider: ModelProvider, storage: PokiStorage = .live) -> String {
        let available = ModelCatalog.available(provider, storage: storage)
        let saved = storage.defaults.string(forKey: "chat.model.\(provider.rawValue)")
        return saved.flatMap { id in available.contains { $0.id == id } ? id : nil } ?? available.first?.id ?? provider.models(in: storage).first?.id ?? ""
    }

    static var selectedModel: String {
        get { selectedModel(in: .live) }
        set { setSelectedModel(newValue, in: .live) }
    }

    static func selectedModel(in storage: PokiStorage = .live) -> String {
        model(for: selectedProvider(in: storage), storage: storage)
    }

    static func setSelectedModel(_ value: String, in storage: PokiStorage = .live) {
        saveModel(value, for: selectedProvider(in: storage), in: storage)
    }

    private static func saveModel(_ value: String, for provider: ModelProvider, in storage: PokiStorage) {
        storage.defaults.set(value, forKey: "chat.model.\(provider.rawValue)")
        if provider == .custom, let chosen = CustomProviders.parse(value) {
            storage.defaults.set(chosen.provider.uuidString, forKey: CustomProviders.selectedKey)
        }
    }

    static func choose(_ provider: ModelProvider, model id: String, in storage: PokiStorage) {
        saveModel(id, for: provider, in: storage)
        storage.defaults.set(provider.rawValue, forKey: "chat.provider")
        saved += 1
    }

    /// The account the chat uses, as the owner reads it: the provider's name, or the custom service's.
    static var selectedAccountName: String { selectedAccountName(in: .live) }

    static func selectedAccountName(in storage: PokiStorage = .live) -> String {
        let provider = selectedProvider(in: storage)
        return provider == .custom ? (CustomProviders.current(in: storage)?.displayName ?? provider.name) : provider.name
    }

    static var selectedModelName: String { selectedModelName(in: .live) }

    static func selectedModelName(in storage: PokiStorage = .live) -> String {
        let provider = selectedProvider(in: storage)
        let model = selectedModel(in: storage)
        return ModelCatalog.all(provider, storage: storage).first { $0.id == model }?.name ?? model
    }

    /// Bumped on every change, so views that read keys can redraw; `changed` is posted too (ask_poki is
    /// listed for outside agents only while a model is set up).
    nonisolated(unsafe) static var saved = 0 { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
    static let changed = Notification.Name("PokiModelKeysChanged")
}

/// The credential pi sends for a provider: the key, or for ChatGPT the signed-in access token, refreshed
/// a minute before it runs out (pi's rule; `expires` is in milliseconds).
enum ModelCredential {
    /// `piProvider` is pi's provider name of the model sent: for a custom provider it names which one.
    static func apiKey(for provider: ModelProvider, piProvider: String? = nil,
                       codexService: String = CodexAccount.defaultService,
                       codexHome: URL = CodexAccount.home,
                       modelKeysService: String = ModelKeys.defaultService) async -> String? {
        // A custom endpoint may need no key; the request still carries one.
        if provider == .custom {
            let custom = piProvider.flatMap { CustomProviders.provider(piProvider: $0) } ?? CustomProviders.current
            return custom.flatMap { CustomProviders.key($0.id) } ?? "none"
        }
        if provider.signsIn {
            if piProvider == "openai-codex" { return await ChatGPTAccount.codexAccessToken(service: codexService, home: codexHome) }
            return await ChatGPTAccount.accessToken(service: modelKeysService)
        }
        return ModelKeys.key(provider, service: modelKeysService)
    }
}
