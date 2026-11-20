import SwiftUI
import UIKit

/// Allo (SIL OFL 1.1, Shared/Fonts), Poki's typeface, in two faces cut by scripts/make-allo-fonts.py:
/// Allo Text for body text and Allo Rounded, a little rounder at a display optical size, for the Poki
/// name, titles and prominent text. Both have SF Pro's cap height and line height at every size, so
/// letters Allo does not have (Chinese, Japanese, Korean, Cyrillic, Greek) come from PingFang and the
/// system fonts as they would beside SF, on the same lines and at the same size. Every font here
/// scales with Dynamic Type from the text style it stands in for.
enum Typeface {
    enum Face: String {
        case text = "AlloText"
        case rounded = "AlloRounded"
    }

    #if POKI_APP
    static var usesAllo: Bool { true }
    #else
    /// The widget extension keeps the system font for Chinese: with a custom font the Lock Screen and
    /// the island laid Chinese lines out narrower than they drew them, cutting off their ends.
    static var usesAllo: Bool { AppLocalization.language.hasPrefix("en") }
    #endif

    /// The cut nearest to a weight. Allo Rounded starts at Medium, as prominent text is never lighter.
    static func name(_ face: Face, _ weight: Font.Weight) -> String {
        let style: String = switch weight {
        case .black: face == .rounded ? "Black" : "ExtraBold"
        case .heavy: "ExtraBold"
        case .bold: "Bold"
        case .semibold: "SemiBold"
        case .medium: "Medium"
        default: face == .rounded ? "Medium" : "Regular"
        }
        return "\(face.rawValue)-\(style)"
    }

    /// The weight the system font gives a text style.
    static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// A text style's size at the default text size. The preferred font's own size is already scaled
    /// for the text size in use; scaling from it grew text twice at the larger sizes and took it past
    /// a view's Dynamic Type limit.
    static func baseSize(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    /// Allo at a text style's size, scaling with Dynamic Type.
    static func font(_ style: Font.TextStyle, _ weight: Font.Weight? = nil, face: Face = .text) -> Font {
        let weight = weight ?? defaultWeight(style)
        guard usesAllo else { return .system(style, weight: weight) }
        return .custom(name(face, weight), size: baseSize(style.uiKit), relativeTo: style)
    }

    /// Allo at a size of its own, growing with `style` under Dynamic Type.
    static func font(size: CGFloat, relativeTo style: Font.TextStyle, _ weight: Font.Weight = .regular, face: Face = .text) -> Font {
        guard usesAllo else { return .system(size: size, weight: weight) }
        return .custom(name(face, weight), size: size, relativeTo: style)
    }

    /// The UIKit font for a text style, scaled for `traits`, with Chinese, Japanese and Korean
    /// falling back in the reader's order of languages.
    static func uiFont(_ style: UIFont.TextStyle, _ weight: Font.Weight? = nil, face: Face = .text, compatibleWith traits: UITraitCollection? = nil) -> UIFont? {
        let weight = weight ?? (style == .headline ? .semibold : .regular)
        guard let base = uiFont(size: baseSize(style), weight, face: face) else { return nil }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }

    /// The UIKit font at a fixed size, with the same fallback.
    static func uiFont(size: CGFloat, _ weight: Font.Weight, face: Face = .text) -> UIFont? {
        guard usesAllo, let base = UIFont(name: name(face, weight), size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade(weight)])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Fonts for the letters Allo has none of: the CJK font of each language the reader uses, Poki's
    /// own language first, then the system font for everything else.
    static func cascade(_ weight: Font.Weight) -> [UIFontDescriptor] {
        let languages = [AppLocalization.language] + Locale.preferredLanguages
        var names: [String] = []
        for language in languages + ["zh-Hans"] {
            let family = cjkFamily(language)
            guard let family, !names.contains(family) else { continue }
            names.append(family)
        }
        let heavy = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
        let fonts = names.map { family -> UIFontDescriptor in
            let face: String = switch family {
            case "HiraginoSans": heavy ? "W6" : "W3"
            case "AppleSDGothicNeo": heavy ? "Bold" : (weight == .medium ? "Medium" : "Regular")
            default: heavy ? "Semibold" : (weight == .medium ? "Medium" : "Regular")
            }
            return UIFontDescriptor(name: "\(family)-\(face)", size: 0)
        }
        return fonts + [UIFont.systemFont(ofSize: 17, weight: weight.uiKit).fontDescriptor]
    }

    private static func cjkFamily(_ language: String) -> String? {
        let locale = Locale(identifier: language)
        switch locale.language.languageCode?.identifier {
        case "zh":
            if locale.language.script?.identifier == "Hant" || ["HK", "MO", "TW"].contains(locale.region?.identifier ?? "") {
                return locale.region?.identifier == "HK" || locale.region?.identifier == "MO" ? "PingFangHK" : "PingFangTC"
            }
            return "PingFangSC"
        case "ja": return "HiraginoSans"
        case "ko": return "AppleSDGothicNeo"
        default: return nil
        }
    }
}

extension Font {
    /// Allo Text at a text style, for body text: `.font(.allo(.footnote))`, `.font(.allo(.body, .semibold))`.
    static func allo(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        Typeface.font(style, weight)
    }

    /// Allo Rounded at a text style, for titles and prominent text.
    static func alloRounded(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        Typeface.font(style, weight ?? .semibold, face: .rounded)
    }

    /// Allo Text at a size of its own, growing with `style` under Dynamic Type.
    static func allo(size: CGFloat, relativeTo style: Font.TextStyle = .body, _ weight: Font.Weight = .regular) -> Font {
        Typeface.font(size: size, relativeTo: style, weight)
    }
}

/// Prominent text (page titles, session names, the Poki name) in Allo Rounded.
enum Prominent {
    static func font(_ style: Font.TextStyle, _ weight: Font.Weight = .semibold) -> Font {
        Typeface.font(style, weight, face: .rounded)
    }

    /// For a page's one large line, growing with `style` under Dynamic Type.
    static func font(size: CGFloat, relativeTo style: Font.TextStyle, _ weight: Font.Weight = .bold) -> Font {
        Typeface.font(size: size, relativeTo: style, weight, face: .rounded)
    }

    static func uiFont(_ style: UIFont.TextStyle, _ weight: Font.Weight, compatibleWith traits: UITraitCollection? = nil) -> UIFont? {
        Typeface.uiFont(style, weight, face: .rounded, compatibleWith: traits)
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension Font.Weight {
    var uiKit: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
