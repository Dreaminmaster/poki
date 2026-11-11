import SwiftUI
import UIKit

/// The app's own colours (ESP-326 prototype, theme.ts), each one a light and a dark value. Blue belongs
/// to Poki: the bear, the task card while it has the phone, the links to what it can do. Amber is your
/// turn, green is done, red is a problem. Surfaces, text and separators are the system's own semantic
/// colours, so they follow Increase Contrast and elevated sheets as the system's apps do.
enum Tint {
    /// Poki's blue, the bear images' own background: the same in light and dark, never the system blue.
    static let blue = Color(hex: 0x0177FD)
    /// The asleep image's background.
    static let night = Color(hex: 0x0F2172)
    static let blueSoft = Color(light: 0xE6F1FF, dark: 0x0C2748)
    /// Blue words on the page: the brand blue in light, a lighter one in dark, for contrast.
    static let blueText = Color(light: 0x0177FD, dark: 0x4C9DFF)
    static let blueLine = Color(light: 0xB9D8FF, dark: 0x1D4F8F)

    static let amber = Color(hex: 0xFFB020)
    static let amberSoft = Color(light: 0xFFF4DC, dark: 0x33270A)
    static let amberInk = Color(light: 0x7A4B00, dark: 0xFFD280)
    static let amberLine = Color(light: 0xF6DFAE, dark: 0x5C4410)

    static let green = Color(hex: 0x1FB86A)
    static let greenSoft = Color(light: 0xE4F6EC, dark: 0x0D2E1D)
    static let greenInk = Color(light: 0x0E6B3C, dark: 0x74E3A8)

    static let red = Color(light: 0xE5484D, dark: 0xF2555A)
    static let redSoft = Color(light: 0xFDECEC, dark: 0x3A1517)
    static let redInk = Color(light: 0x8C1D22, dark: 0xFFA3A6)

    /// Your own solid buttons (Hold to Allow, Done): ink in light, white in dark.
    static let solid = Color(.label)
    static let onSolid = Color(.systemBackground)
    /// Your bubble and the quiet fills: grey, never blue.
    static let fill = Color(.secondarySystemBackground)
    /// A hairline around a blue block in dark, where a shadow would read as a glow; nothing in light.
    static let ring = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.18) : .clear })
}

extension Color {
    /// One colour with a light and a dark value.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
