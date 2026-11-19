import Foundation
import Observation

enum SetupLanguage: String {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    func resolve(preferred: [String]) -> String {
        guard self == .system else { return rawValue }
        return Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferred).first ?? "en"
    }
}

@Observable final class SetupLocalization {
    static let shared = SetupLocalization()
    // bundle.sh embeds the SwiftPM bundle in Contents/Resources. Some SwiftPM
    // accessors only check the app root and the original build directory.
    private static let resources = Bundle.main.url(forResource: "PokiSetup_PokiSetup", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    private let defaults: UserDefaults
    var language: SetupLanguage {
        didSet { defaults.set(language.rawValue, forKey: "uiLanguage") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = SetupLanguage(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .system
    }

    var locale: Locale {
        var components = Locale.Components(identifier: Locale.current.identifier)
        let selected = language.resolve(preferred: Locale.preferredLanguages)
        components.languageComponents = Locale.Components(identifier: selected).languageComponents
        components.languageComponents.region = Locale.current.region
        return Locale(components: components)
    }

    func text(_ key: String.LocalizationValue, table: String = "Localizable") -> String {
        let resource = LocalizedStringResource(key, table: table, locale: locale, bundle: .atURL(Self.resources.bundleURL))
        return String(localized: resource)
    }
}

func localized(_ key: String.LocalizationValue) -> String {
    SetupLocalization.shared.text(key)
}

// Resolve stored UI messages when a view renders, so an open banner also follows the picker.
enum SetupMessage {
    case copy(String.LocalizationValue)
    case verbatim(String)

    var text: String {
        switch self {
        case .copy(let key): localized(key)
        case .verbatim(let text): text
        }
    }
}
