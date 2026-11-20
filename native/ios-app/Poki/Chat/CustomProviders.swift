import Foundation
import PiSwiftAI

/// Which OpenAI API a custom address is spoken to in: the Responses API (what the official OpenAI
/// account uses, with reasoning carried between turns), chat completions (what most local servers and
/// gateways speak), or Automatic, which tries Responses first when the connection is tested and uses
/// chat completions where the address has no Responses API.
enum CustomAPIStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, responses, chatCompletions
    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: AppLocalization.text(LocalizedStringResource("Automatic"))
        case .responses: AppLocalization.text(LocalizedStringResource("Responses"))
        case .chatCompletions: AppLocalization.text(LocalizedStringResource("Chat Completions"))
        }
    }

    /// The API a request goes out in. Automatic takes what the last test found, else chat completions,
    /// what every custom address used before Responses was offered.
    func resolved(found: CustomAPIStyle?) -> CustomAPIStyle {
        switch self {
        case .automatic: found == .responses ? .responses : .chatCompletions
        case .responses, .chatCompletions: self
        }
    }

    var piAPI: Api { self == .responses ? .openAIResponses : .openAICompletions }
}

/// One address of a custom provider, with the API it speaks there.
struct CustomEndpoint: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var url: String
    var api: CustomAPIStyle = .automatic
    /// What Automatic found here at the last passing test. Forgotten when the address changes.
    var found: CustomAPIStyle?

    /// The API requests to this address go out in now.
    var sent: CustomAPIStyle { api.resolved(found: found) }
    var normalized: String { ModelCatalog.normalizedAddress(url) }
}

/// An OpenAI-compatible service the owner added (a gateway, a local server, another lab's OpenAI API):
/// its name, one or more addresses, its own key, the model typed in by hand, and whether it thinks and
/// runs live voice. The first address is used first; the others, in order, when it can't be reached.
/// There can be as many as the owner likes, each with its own key in the keychain.
struct CustomProvider: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var endpoints: [CustomEndpoint] = []
    var model = ""
    /// The owner's choice, or nil for Automatic: on for a model pi's catalog lists as reasoning.
    var reasoning: Bool?
    /// Live voice through this service's Realtime API, at its first address.
    var liveVoice = false

    /// The address used first.
    var primary: CustomEndpoint? { endpoints.first { !$0.normalized.isEmpty } }
    /// The addresses after the first that speak the same API, tried in order when the first can't be
    /// reached.
    var backups: [CustomEndpoint] {
        guard let primary else { return [] }
        return endpoints.filter { $0.id != primary.id && !$0.normalized.isEmpty && $0.sent == primary.sent }
    }

    /// The provider name pi sees: the id, so the key, the backups and the log find this service again.
    var piProvider: String { CustomProviders.piPrefix + id.uuidString }

    /// The owner's name for it, else the first address's host.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = primary.flatMap({ URLComponents(string: $0.normalized)?.host }), !host.isEmpty { return host }
        return AppLocalization.text(LocalizedStringResource("Custom Endpoint"))
    }
}

/// The owner's custom providers, in the app's settings (their keys in the keychain, one account each).
/// The chat names a custom model by its provider and model id together (`choiceID`), so two services
/// that serve a model of the same name stay apart.
enum CustomProviders {
    static let storeKey = "custom.providers"
    static let selectedKey = "chat.customProvider"
    static let piPrefix = "poki-custom:"
    private static let choicePrefix = "custom:"
    private static let legacyProviderID = UUID(uuidString: "998487A3-20B9-4A56-AE79-A71F3A5291CB")!

    // MARK: Store

    static var all: [CustomProvider] {
        get {
            migrateIfNeeded()
            guard let data = UserDefaults.standard.data(forKey: storeKey),
                  let providers = try? JSONDecoder().decode([CustomProvider].self, from: data) else { return [] }
            return providers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: storeKey) }
        }
    }

    static func provider(_ id: UUID) -> CustomProvider? { all.first { $0.id == id } }

    /// The provider behind one of pi's models (`Model.provider`).
    static func provider(piProvider: String) -> CustomProvider? {
        guard piProvider.hasPrefix(piPrefix), let id = UUID(uuidString: String(piProvider.dropFirst(piPrefix.count))) else { return nil }
        return provider(id)
    }

    /// Adds the provider, or replaces the one with its id. An address that changed forgets what
    /// Automatic found there and the model list read from it.
    @discardableResult
    static func upsert(_ provider: CustomProvider) -> CustomProvider {
        var provider = provider
        var list = all
        if let index = list.firstIndex(where: { $0.id == provider.id }) {
            let old = list[index]
            for i in provider.endpoints.indices {
                let before = old.endpoints.first { $0.id == provider.endpoints[i].id }
                if before?.normalized != provider.endpoints[i].normalized || before?.api != provider.endpoints[i].api {
                    provider.endpoints[i].found = nil
                }
            }
            if old.primary?.normalized != provider.primary?.normalized { ModelCatalog.invalidateCustom(provider.id) }
            list[index] = provider
            all = list
            if old.model != provider.model, !old.model.isEmpty, !ModelCatalog.listedCustom(provider.id).contains(old.model) {
                ModelCatalog.set(choiceID(provider.id, old.model), on: false, for: .custom, notify: false)
            }
        } else {
            list.append(provider)
            all = list
        }
        if !provider.model.isEmpty { ModelCatalog.set(choiceID(provider.id, provider.model), on: true, for: .custom, notify: false) }
        ModelKeys.saved += 1
        return provider
    }

    /// Keeps what Automatic found at an address after a passing test.
    static func record(found: CustomAPIStyle, endpoint: CustomEndpoint, provider id: UUID) {
        var list = all
        guard endpoint.api == .automatic, let p = list.firstIndex(where: { $0.id == id }),
              let e = list[p].endpoints.firstIndex(where: {
                  $0.id == endpoint.id && $0.normalized == endpoint.normalized && $0.api == .automatic
              }), list[p].endpoints[e].found != found else { return }
        list[p].endpoints[e].found = found
        all = list
        ModelKeys.saved += 1
    }

    @MainActor
    static func testConnection(to endpoint: CustomEndpoint, key: String, draft: CustomProvider) async -> (result: ConnectionCheck.Result, api: CustomAPIStyle) {
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = await ConnectionCheck.runCustom(url: endpoint.normalized, key: key, modelID: model,
                                                  api: endpoint.api, reasoning: draft.reasoning)
        guard run.result.passed, endpoint.api == .automatic, let saved = provider(draft.id),
              saved.model == model, saved.reasoning == draft.reasoning else { return run }
        let keyData = try? (Keychain.read(keyAccount(saved.id)) ?? Data())
        let savedKey = keyData.flatMap { String(data: $0, encoding: .utf8) }
        guard savedKey?.trimmingCharacters(in: .whitespacesAndNewlines) == key.trimmingCharacters(in: .whitespacesAndNewlines) else { return run }
        record(found: run.api, endpoint: endpoint, provider: saved.id)
        return run
    }

    /// Removes the provider, its key, its model lists and its models from the chat's menu.
    static func remove(_ id: UUID) {
        let wasSelected = ModelKeys.selectedProvider == .custom && parse(ModelKeys.selectedModel)?.provider == id
        removeKey(id)
        ModelCatalog.invalidateCustom(id)
        UserDefaults.standard.removeObject(forKey: "models.listed.voice.custom.\(id.uuidString)")
        all = all.filter { $0.id != id }
        if UserDefaults.standard.string(forKey: selectedKey) == id.uuidString { UserDefaults.standard.removeObject(forKey: selectedKey) }
        if wasSelected, let next = ModelCatalog.available(.custom).first {
            ModelKeys.selectedModel = next.id
        }
        ModelKeys.saved += 1
    }

    /// The provider the chat uses now: the one of the chosen custom model, else the last chosen, else
    /// the first.
    static var current: CustomProvider? {
        let list = all
        if let chosen = parse(ModelKeys.model(for: .custom)), let match = list.first(where: { $0.id == chosen.provider }) { return match }
        if let saved = UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)),
           let match = list.first(where: { $0.id == saved }) { return match }
        return list.first
    }

    // MARK: Keys

    private static func keyAccount(_ id: UUID) -> String { "model-key.custom.\(id.uuidString)" }

    static func key(_ id: UUID) -> String? {
        guard let data = try? Keychain.read(keyAccount(id)), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func saveKey(_ key: String, for id: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = Self.key(id) != trimmed
        try Keychain.write(Data(trimmed.utf8), account: keyAccount(id))
        if changed { ModelCatalog.invalidateCustom(id) }
        ModelKeys.saved += 1
    }

    static func removeKey(_ id: UUID) {
        let had = key(id) != nil
        Keychain.delete(keyAccount(id))
        if had { ModelCatalog.invalidateCustom(id) }
        ModelKeys.saved += 1
    }

    // MARK: The chat's model ids

    /// The chat's id for a provider's model: `custom:<provider id>:<model id>`. The provider id has a
    /// fixed length, so a model id with colons in it (`llama3:8b`) reads back whole.
    static func choiceID(_ provider: UUID, _ model: String) -> String {
        choicePrefix + provider.uuidString + ":" + model
    }

    static func parse(_ choice: String) -> (provider: UUID, model: String)? {
        guard choice.hasPrefix(choicePrefix) else { return nil }
        let rest = choice.dropFirst(choicePrefix.count)
        guard rest.count > 37, let id = UUID(uuidString: String(rest.prefix(36))), rest.dropFirst(36).first == ":" else { return nil }
        let model = String(rest.dropFirst(37))
        return model.isEmpty ? nil : (id, model)
    }

    /// A model's name in the chat's menu: its id, with the service's name once there is more than one.
    static func choiceName(_ provider: CustomProvider, _ model: String, among count: Int) -> String {
        count > 1 ? "\(model) (\(provider.displayName))" : model
    }

    // MARK: Migration

    /// Before custom providers, one address, model and key lived in `chat.customURL`,
    /// `chat.customModel` and the keychain's `model-key.custom`. They become the first provider, with
    /// its model list, its switched-on models and the chat's choice carried over.
    private static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: storeKey)
        let url = defaults.string(forKey: "chat.customURL") ?? ""
        let model = defaults.string(forKey: "chat.customModel") ?? ""
        guard stored == nil || !url.isEmpty || !model.isEmpty else { return }
        let legacyAccount = "model-key.custom"
        let id = legacyProviderID
        do {
            let providers = try stored.map { try JSONDecoder().decode([CustomProvider].self, from: $0) } ?? []
            // Reuse the same ID if the app exits before cleaning up the old settings.
            if !providers.contains(where: { $0.id == id }) {
                let key = try Keychain.read(legacyAccount)
                if let key, String(data: key, encoding: .utf8) == nil { return }
                guard !url.isEmpty || !model.isEmpty || key?.isEmpty == false else { return }
                let provider = CustomProvider(id: id, endpoints: url.isEmpty ? [] : [CustomEndpoint(url: url)], model: model)
                let data = try JSONEncoder().encode([provider] + providers)
                if let key, !key.isEmpty { try Keychain.write(key, account: keyAccount(id)) }

                let wrap = { (model: String) in parse(model) == nil ? choiceID(id, model) : model }
                if let listed = defaults.stringArray(forKey: "models.listed.custom") {
                    defaults.set(listed, forKey: "models.listed.custom.\(id.uuidString)")
                }
                if let enabled = defaults.stringArray(forKey: "models.enabled.custom") {
                    defaults.set(enabled.map(wrap), forKey: "models.enabled.custom")
                }
                if let chosen = defaults.string(forKey: "chat.model.custom") { defaults.set(wrap(chosen), forKey: "chat.model.custom") }
                if defaults.string(forKey: selectedKey) == nil { defaults.set(id.uuidString, forKey: selectedKey) }
                defaults.set(data, forKey: storeKey)
            }
        } catch {
            return
        }
        Keychain.delete(legacyAccount)
        for old in ["chat.customURL", "chat.customModel", "models.listed.custom", "models.revision.custom"] {
            defaults.removeObject(forKey: old)
        }
    }
}
