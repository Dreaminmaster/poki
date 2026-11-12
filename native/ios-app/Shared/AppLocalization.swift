import Foundation
import Observation

/// One language for Poki-owned UI. System UI keeps iOS's per-app language, and stored conversation
/// content stays as written. Resources still live in the existing String Catalogs.
@Observable final class AppLocalization {
    static let shared = AppLocalization()
    static let key = "uiLanguage"
    static let system = "system"

    var preference: String {
        didSet {
            UserDefaults.standard.set(preference, forKey: Self.key)
            Self.publish()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? Self.system
        preference = Self.languages.contains(saved) ? saved : Self.system
    }

    /// Adding a bundled localization makes it available here without another language-specific case.
    static var languages: [String] {
        // Bundle can return the same identifier from CFBundleLocalizations and its .lproj folders.
        Set(Bundle.main.localizations).subtracting(["Base"]).sorted()
    }

    static func resolve(_ preference: String, supported: [String], preferred: [String]) -> String {
        if supported.contains(preference) { return preference }
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }

    static var language: String {
        #if POKI_APP
        let preference = shared.preference
        #else
        let preference = SharedContainer.defaults.string(forKey: "effectiveUILanguage") ?? system
        #endif
        // preferredLocalizations is iOS's effective app language, including its per-app override.
        return resolve(preference, supported: languages, preferred: Bundle.main.preferredLocalizations)
    }

    static var locale: Locale {
        var components = Locale.Components(identifier: Locale.current.identifier)
        components.languageComponents = Locale.Components(identifier: language).languageComponents
        components.languageComponents.region = Locale.current.region
        return Locale(components: components)
    }

    /// String(localized:locale:) only changes interpolation formatting. A resource's locale also
    /// chooses its translation. Keeping the resource at the call site preserves catalog extraction.
    static func text(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// Existing runtime status keys, never arbitrary user/model content.
    static var bundle: Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    static func publish() {
        SharedContainer.defaults.set(language, forKey: "effectiveUILanguage")
    }
}
