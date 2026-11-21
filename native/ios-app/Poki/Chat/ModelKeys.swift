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

    var models: [ChatModelChoice] {
        switch self {
        case .anthropic: [
            ChatModelChoice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
            ChatModelChoice(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
            ChatModelChoice(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        ]
        // GPT-6.1 Terra first, the owner's choice for the chat (ESP-174); Sol stays selectable.
        case .openai: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
            ChatModelChoice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        ]
        // The ChatGPT plan's models on the OpenAI API; gpt-6.1-terra is also Poki
        // Agent's default on the Mac (agent/model-config.mjs).
        case .chatgpt: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "ChatGPT GPT-6.1 Terra"),
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
            ChatModelChoice(id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol (OpenRouter)"),
            ChatModelChoice(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash (OpenRouter)"),
        ]
        // Whatever model each of the owner's services serves (a local server, a company gateway), named
        // with its service once there is more than one.
        case .custom:
            Self.customChoices(CustomProviders.all)
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
        providers.compactMap { provider in
            let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, provider.primary != nil else { return nil }
            return ChatModelChoice(id: CustomProviders.choiceID(provider.id, model),
                                   name: CustomProviders.choiceName(provider, model, among: providers.count))
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
        // GPT-6.1 Terra is missing from PiSwift's catalog; it has Sol's setup (see `piModel`).
        func lookupID(_ id: String) -> String { id == "gpt-6.1-terra" ? "gpt-6.1-sol" : id }
        if let vendor = parts.dropLast().last,
           let model = getModel(provider: vendor.lowercased(), modelId: lookupID(unqualified)) { return model }
        let ids = unqualified == trimmed ? [trimmed] : [trimmed, unqualified]
        for candidate in ids {
            for provider in providers {
                if let model = getModel(provider: provider, modelId: lookupID(candidate)) { return model }
            }
        }
        return nil
    }

    /// pi's model for one of `models`. For a custom provider `id` is the chat's id (provider and model,
    /// `CustomProviders.choiceID`) and the model goes to the provider's first address in its API. With
    /// `customURL`, an address not saved yet (the connection test on the editing page), `id` is the bare
    /// model id and `customAPI` and `customReasoning` are the page's choices.
    func piModel(_ id: String, customURL: String? = nil, customAPI: CustomAPIStyle = .chatCompletions, customReasoning: Bool? = nil) -> Model? {
        guard let piProvider else { return nil }
        if self == .custom {
            if let customURL {
                let base = customURL.trimmingCharacters(in: .whitespaces)
                guard !base.isEmpty, !id.isEmpty else { return nil }
                return Self.customModel(id, baseUrl: base, api: customAPI.piAPI, reasoning: customReasoning, piProvider: piProvider)
            }
            guard let chosen = CustomProviders.parse(id), let provider = CustomProviders.provider(chosen.provider),
                  let endpoint = provider.primary else { return nil }
            return Self.customModel(chosen.model, baseUrl: endpoint.normalized, api: endpoint.sent.piAPI,
                                    reasoning: provider.reasoning, piProvider: provider.piProvider)
        }
        if let model = getModel(provider: piProvider, modelId: id) { return model }
        // OpenRouter serves thousands of models its catalog lacks, and a built-in model's setup (Anthropic
        // thinking on the Messages API) is rejected by many of them. Take the plain chat setup, and add
        // reasoning only for a model OpenRouter's own list says supports it.
        if self == .openrouter {
            return unlistedModel(id, provider: piProvider, baseUrl: Self.openRouterBaseURL,
                                 reasoning: ModelCatalog.supportsReasoning(id, for: self))
        }
        // PiSwift's catalog (pi-mono, October 2026) lacks gpt-6.1-terra, which pi-ai 1.5.0 lists with the
        // same API and inputs as gpt-6.1-sol.
        // A model from the provider's own list that pi's catalog lacks takes the shape of a built-in one of
        // the same provider (same API and inputs), with its own id.
        let template = (self == .openai || self == .chatgpt) && id == "gpt-6.1-terra" ? "gpt-6.1-sol" : models.lazy.compactMap { getModel(provider: piProvider, modelId: $0.id) }.first?.id
        guard let template, let base = getModel(provider: piProvider, modelId: template),
              var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any] else { return nil }
        json["id"] = id
        json["name"] = id == "gpt-6.1-terra" ? "GPT-6.1 Terra" : id
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(Model.self, from: $0) }
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
    private static func account(_ provider: ModelProvider) -> String { "model-key.\(provider.rawValue)" }

    /// For a custom provider, the key of the one the chat uses now (`CustomProviders.current`).
    static func key(_ provider: ModelProvider) -> String? {
        if provider == .custom { return CustomProviders.current.flatMap { CustomProviders.key($0.id) } }
        guard let data = try? Keychain.read(account(provider)), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(_ provider: ModelProvider) -> Bool { key(provider) != nil }

    static func save(_ key: String, for provider: ModelProvider) throws {
        if provider == .custom {
            let current = CustomProviders.current ?? CustomProviders.upsert(CustomProvider())
            return try CustomProviders.saveKey(key, for: current.id)
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.write(Data(trimmed.utf8), account: account(provider))
        saved += 1
    }

    static func remove(_ provider: ModelProvider) {
        if provider == .custom {
            if let current = CustomProviders.current { CustomProviders.removeKey(current.id) }
            return
        }
        Keychain.delete(account(provider))
        saved += 1
    }

    static func removeChatGPTSignIn() throws {
        try Keychain.remove(account(.chatgpt))
        saved += 1
    }

    /// The first address of the custom provider the chat uses now (not a secret: kept in the app's
    /// settings). Setting it changes that address, or adds a provider when there is none.
    static var customURL: String {
        get { CustomProviders.current?.primary?.url ?? "" }
        set { editCurrentCustom { provider in
            if provider.endpoints.isEmpty { provider.endpoints = [CustomEndpoint(url: newValue)] }
            else { provider.endpoints[0].url = newValue }
        } }
    }

    /// The model id of the custom provider the chat uses now.
    static var customModel: String {
        get { CustomProviders.current?.model ?? "" }
        set { editCurrentCustom { $0.model = newValue } }
    }

    private static func editCurrentCustom(_ change: (inout CustomProvider) -> Void) {
        var provider = CustomProviders.current ?? CustomProvider()
        change(&provider)
        CustomProviders.upsert(provider)
        UserDefaults.standard.set(provider.id.uuidString, forKey: CustomProviders.selectedKey)
    }

    /// A different address never inherits the previous service's secret.
    static func customDraftKey(address: String, typedKey: String) -> String? {
        let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return ModelCatalog.normalizedAddress(address) == ModelCatalog.normalizedAddress(customURL) ? key(.custom) : nil
    }

    /// Saves the custom provider the chat uses now with one address and model (a new one when there is
    /// none) and makes its model the chat's.
    @MainActor
    static func saveCustom(address: String, model: String, typedKey: String) throws {
        let address = ModelCatalog.normalizedAddress(address)
        let credential = customDraftKey(address: address, typedKey: typedKey)
        var provider = CustomProviders.current ?? CustomProvider()
        provider.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.endpoints.isEmpty { provider.endpoints = [CustomEndpoint(url: address)] } else { provider.endpoints[0].url = address }
        try saveCustom(provider, typedKey: credential ?? "", keepKey: false)
    }

    /// Saves a custom provider from its editing page: the key typed (else, with `keepKey`, the saved
    /// one stays; without it none), its addresses and model, and makes its model the chat's.
    @MainActor
    static func saveCustom(_ provider: CustomProvider, typedKey: String, keepKey: Bool) throws {
        let typed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Save the secret first: a keychain failure must not change the addresses or the model.
        if !typed.isEmpty { try CustomProviders.saveKey(typed, for: provider.id) }
        else if !keepKey, CustomProviders.key(provider.id) != nil { CustomProviders.removeKey(provider.id) }
        let saved = CustomProviders.upsert(provider)
        UserDefaults.standard.set(saved.id.uuidString, forKey: CustomProviders.selectedKey)
        guard !saved.model.isEmpty, saved.primary != nil else { return }
        selectedProvider = .custom
        selectedModel = CustomProviders.choiceID(saved.id, saved.model)
    }

    /// The chat can run: the chosen provider is wired and has a key (a custom endpoint: an address and a
    /// model; its key is optional).
    static var hasUsableKey: Bool {
        if selectedProvider == .custom {
            guard let chosen = CustomProviders.parse(selectedModel), let provider = CustomProviders.provider(chosen.provider) else { return false }
            return provider.primary != nil
        }
        if selectedProvider == .chatgpt { return ChatGPTAccount.signedIn }
        return selectedProvider.wired && hasKey(selectedProvider)
    }

    static var selectedProvider: ModelProvider {
        get { UserDefaults.standard.string(forKey: "chat.provider").flatMap(ModelProvider.init(rawValue:)) ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chat.provider"); saved += 1 }
    }

    /// Each provider's model: its first (Claude Sonnet 5.5, GPT-6.1 Terra) unless the owner picks another.
    static func model(for provider: ModelProvider) -> String {
        let available = ModelCatalog.available(provider)
        let saved = UserDefaults.standard.string(forKey: "chat.model.\(provider.rawValue)")
        return saved.flatMap { id in available.contains { $0.id == id } ? id : nil } ?? available.first?.id ?? provider.models.first?.id ?? ""
    }

    static var selectedModel: String {
        get { model(for: selectedProvider) }
        set {
            UserDefaults.standard.set(newValue, forKey: "chat.model.\(selectedProvider.rawValue)")
            if selectedProvider == .custom, let chosen = CustomProviders.parse(newValue) {
                UserDefaults.standard.set(chosen.provider.uuidString, forKey: CustomProviders.selectedKey)
            }
        }
    }

    /// The account the chat uses, as the owner reads it: the provider's name, or the custom service's.
    static var selectedAccountName: String {
        selectedProvider == .custom ? (CustomProviders.current?.displayName ?? selectedProvider.name) : selectedProvider.name
    }

    static var selectedModelName: String {
        ModelCatalog.all(selectedProvider).first { $0.id == selectedModel }?.name ?? selectedModel
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
    static func apiKey(for provider: ModelProvider, piProvider: String? = nil) async -> String? {
        // A custom endpoint may need no key; the request still carries one.
        if provider == .custom {
            let custom = piProvider.flatMap { CustomProviders.provider(piProvider: $0) } ?? CustomProviders.current
            return custom.flatMap { CustomProviders.key($0.id) } ?? "none"
        }
        if provider.signsIn { return await ChatGPTAccount.accessToken() }
        return ModelKeys.key(provider)
    }
}
