import UIKit

/// An app that shows as a capsule wherever one of its names is written (ESP-377). The names are the
/// words that turn into the capsule; the plain text keeps exactly what was written.
struct AppCapsule: Hashable, Identifiable {
    let id: String
    /// The icon's image in the asset catalog (Poki/AppIcons, see make-assets.sh).
    let asset: String
    let names: [String]
    /// The capsule's colour where the icon's own colour does not work (ESP-376 board, section 8).
    var brandColor: UInt32? = nil

    var name: String { names[0] }

    /// How the capsule spells the name, whatever case it was typed in.
    func label(for typed: String) -> String {
        names.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
    }

    /// The prototype's apps, with their icons in the bundle. Messages has no Chinese name here: its
    /// Chinese name 信息 is an everyday word and would turn into a capsule in ordinary sentences.
    static let catalog: [AppCapsule] = [
        AppCapsule(id: "com.apple.MobileSMS", asset: "App-messages", names: ["Messages"]),
        AppCapsule(id: "com.ubercab.UberClient", asset: "App-uber", names: ["Uber"]),
        AppCapsule(id: "com.tinyspeck.chatlyio", asset: "App-slack", names: ["Slack"], brandColor: 0xE31E5D),
        AppCapsule(id: "com.tencent.xin", asset: "App-wechat", names: ["微信", "WeChat"]),
        AppCapsule(id: "com.apple.mobilenotes", asset: "App-notes", names: ["Notes", "备忘录"]),
        AppCapsule(id: "com.burbn.instagram", asset: "App-instagram", names: ["Instagram"], brandColor: 0xEA005E),
        AppCapsule(id: "com.starbucks.mystarbucks", asset: "App-starbucks", names: ["Starbucks"]),
    ]

    /// App names that are also everyday English words. These turn into a capsule only when written
    /// with a capital first letter, as a name; every other Latin name turns into one in any case,
    /// because people typing fast often write "uber" or "slack".
    static let everydayWords: Set<String> = [
        "Messages", "Notes", "Mail", "Maps", "Phone", "Photos", "Music", "Clock", "Calendar",
        "Camera", "Weather", "Reminders", "Contacts", "Files", "Health", "Wallet", "News", "Books",
        "Podcasts", "Calculator", "Compass", "Measure", "Shortcuts", "Settings", "Translate",
        "Freeform", "Journal", "Passwords", "Games", "Home", "Fitness", "Stocks", "Tips", "Find My",
    ]
}

/// The plain text, cut where the apps' names are. Plain text is the only source: the field's capsules
/// are this function's output, and reading the capsules back gives the same text.
enum CapsuleText {
    enum Segment: Equatable {
        case text(String)
        /// The app and the words exactly as written.
        case app(AppCapsule, String)
    }

    /// The longest name wins where one name starts another. A Latin name counts only as a whole word,
    /// so "Slacker" stays text; an everyday word must also start with its capital ("Messages", not
    /// "messages"); a Chinese name counts anywhere.
    static func segments(_ plain: String, catalog: [AppCapsule] = AppCapsule.catalog) -> [Segment] {
        let text = plain as NSString
        let names = catalog.flatMap { app in
            app.names.map { (app, $0 as NSString, AppCapsule.everydayWords.contains($0) ? NSString.CompareOptions.literal : .caseInsensitive) }
        }
        .sorted { $0.1.length > $1.1.length }
        var out: [Segment] = []
        var run = 0
        var i = 0
        while i < text.length {
            let hit = names.first { _, name, options in
                i + name.length <= text.length
                    && text.compare(name as String, options: options, range: NSRange(location: i, length: name.length)) == .orderedSame
                    && wholeWord(name, at: i, in: text)
            }
            if let (app, name, _) = hit {
                if run < i { out.append(.text(text.substring(with: NSRange(location: run, length: i - run)))) }
                out.append(.app(app, text.substring(with: NSRange(location: i, length: name.length))))
                i += name.length
                run = i
            } else {
                i += 1
            }
        }
        if run < text.length { out.append(.text(text.substring(from: run))) }
        return out
    }

    /// The text a recommendation puts in the field: the app, then the sentence.
    static func prefill(app: AppCapsule, sentence: String) -> String {
        "\(app.name) \(sentence)"
    }

    private static func wholeWord(_ name: NSString, at i: Int, in text: NSString) -> Bool {
        let wordy = CharacterSet.alphanumerics
        func isLatinWordChar(_ unit: unichar) -> Bool {
            unit < 0x80 && UnicodeScalar(unit).map(wordy.contains) == true
        }
        if isLatinWordChar(name.character(at: 0)), i > 0, isLatinWordChar(text.character(at: i - 1)) { return false }
        let end = i + name.length
        if isLatinWordChar(name.character(at: name.length - 1)), end < text.length, isLatinWordChar(text.character(at: end)) { return false }
        return true
    }
}

/// A capsule's colours, by the ESP-376 board's rule (section 8): the icon's largest vivid colour, as
/// it is, behind the name; the name in white or #11191C, whichever contrasts more, and at least 4.5
/// to 1 (a red too light for white text is darkened within its hue); a few apps take a set brand
/// colour; a near-black capsule gets a faint light edge in dark mode.
enum CapsuleColors {
    struct Style {
        let background: UIColor
        let foreground: UIColor
        /// Draw the faint light edge in dark mode.
        let edgeInDark: Bool
    }

    static let darkText = UIColor(red: 0x11 / 255, green: 0x19 / 255, blue: 0x1C / 255, alpha: 1)
    private static var cache: [String: Style] = [:]

    static func of(_ app: AppCapsule) -> Style {
        if let style = cache[app.id] { return style }
        let base = app.brandColor.map(color(hex:)) ?? UIImage(named: app.asset).map(mainColor) ?? .systemGray
        let style = style(for: base)
        cache[app.id] = style
        return style
    }

    /// The rule, for any main colour.
    static func style(for base: UIColor) -> Style {
        var background = base
        var foreground = textColor(on: background)
        // Neither white nor near-black reaches 4.5: darken the colour in its hue until white does.
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        background.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        while contrast(foreground, background) < 4.5, v > 0.05 {
            v -= 0.01
            background = UIColor(hue: h, saturation: s, brightness: v, alpha: 1)
            foreground = textColor(on: background)
        }
        return Style(background: background, foreground: foreground, edgeInDark: luminance(background) < 0.02)
    }

    private static func textColor(on background: UIColor) -> UIColor {
        contrast(.white, background) >= contrast(darkText, background) ? .white : darkText
    }

    /// The icon's largest vivid colour: shrunk to 32 by 32, the hue (in 24 steps) that most vivid
    /// pixels share, averaged over its more saturated half so anti-aliased edges do not wash it out.
    /// An icon with no vivid colour (Uber's black) gives its most common colour.
    static func mainColor(of image: UIImage) -> UIColor {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage,
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .systemGray }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        struct Pixel { let r, g, b, s: CGFloat }
        var hues: [Int: [Pixel]] = [:]
        var common: [Int: [Pixel]] = [:]
        var vivid = 0
        for p in 0..<(side * side) {
            let r8 = pixels[p * 4], g8 = pixels[p * 4 + 1], b8 = pixels[p * 4 + 2]
            let r = CGFloat(r8) / 255, g = CGFloat(g8) / 255, b = CGFloat(b8) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            let pixel = Pixel(r: r, g: g, b: b, s: s)
            common[Int(r8 >> 4) << 8 | Int(g8 >> 4) << 4 | Int(b8 >> 4), default: []].append(pixel)
            guard s > 0.35, v > 0.3 else { continue }
            vivid += 1
            hues[Int(h * 24) % 24, default: []].append(pixel)
        }
        let pool: [Pixel]
        if vivid >= side * side * 8 / 100, let top = hues.values.max(by: { $0.count < $1.count }) {
            let median = top.map(\.s).sorted()[top.count / 2]
            pool = top.filter { $0.s >= median }
        } else {
            pool = common.values.max(by: { $0.count < $1.count }) ?? []
        }
        guard !pool.isEmpty else { return .systemGray }
        let n = CGFloat(pool.count)
        return UIColor(red: pool.map(\.r).reduce(0, +) / n, green: pool.map(\.g).reduce(0, +) / n,
                       blue: pool.map(\.b).reduce(0, +) / n, alpha: 1)
    }

    static func color(hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
