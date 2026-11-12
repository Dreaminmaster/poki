import SwiftUI

/// Parts of the home page, the drawer and the chat that can be turned off one at a time, to measure
/// on a phone what each costs to draw: `-pokiPerf drawerSolid` or `-pokiPerf pillsStill,chatNoFade`.
/// Debug builds only. A release build reads no argument and has every switch off, so it always draws
/// the app as designed.
enum PerfSwitch: String, CaseIterable {
    /// The drawer's panel is the opaque page colour instead of glass. The blur, scrim and shadow stay.
    case drawerSolid
    /// The chat behind the open drawer is not blurred.
    case drawerNoBlur
    /// The scrim over the chat behind the drawer has no material, only its dim.
    case drawerNoScrim
    /// The drawer's panel casts no shadow.
    case drawerNoShadow
    /// The home light and the chat's glow stand still, as with Reduce Motion.
    case backdropStill
    /// The suggestion rows do not go by themselves; a finger still moves them.
    case pillsStill
    /// The suggestion pills have no glass at all.
    case pillsNoGlass
    /// The conversation does not fade out under the top bar.
    case chatNoFade
    /// Every app icon is the placeholder tile, with no lookup.
    case iconsPlaceholder

    // The earlier version of a change made to draw less, to compare the two on the same build.
    /// The suggestion rows ask for 120 frames a second again.
    case old120
    /// The home light and the suggestion rows keep moving under the open drawer.
    case oldUnderDrawer
    /// The moving light is drawn as SwiftUI draws any view, at the screen's full size.
    case oldMeshDirect
    /// The moving light is drawn on the graphics processor, at the screen's full size.
    case oldMeshFullSize
    /// The suggestion pills are live glass again.
    case oldPillGlass

    static func on(_ part: PerfSwitch) -> Bool { active.contains(part) }

    #if DEBUG
    private static let active: Set<PerfSwitch> = Set(
        (UserDefaults.standard.string(forKey: "pokiPerf") ?? "").split(separator: ",")
            .compactMap { PerfSwitch(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    #else
    private static let active: Set<PerfSwitch> = []
    #endif
}

extension View {
    /// `change` as it is, unless `part` is switched off: then the view goes without it.
    @ViewBuilder func unless<Changed: View>(_ part: PerfSwitch, _ change: (Self) -> Changed) -> some View {
        if PerfSwitch.on(part) { self } else { change(self) }
    }
}
