import Foundation

// What a path may do on the way. A routine or a path stops at the first screen that differs, which
// is what keeps it from tapping the wrong thing. A path can say ahead what may be closed when it is
// in the way of a step (dismiss: ["Not Now", "Later"]): such a control, alone on a screen that holds
// still without the step's target, is tapped and the step is tried again. No model is asked, and the
// tap is held by the same approval rules as any other.

extension Computer {
    /// Types that take a tap.
    static let tappable: Set<String> = ["Button", "Cell", "Link", "Switch", "Toggle", "Tab", "MenuItem", "SegmentedControl", "Icon", "TextField", "SearchField", "TextView", "CheckBox", "RadioButton", "DisclosureTriangle", "PopUpButton", "MenuButton"]
    /// A step whose target is missing looks for something to close, and an optional step is left out,
    /// once the screen has held still this long.
    static let askAfterStill = 0.7
    /// Controls closed for one step, and in one run.
    static let maxClosesPerStep = 2
    static let maxClosesPerRun = 5
}
