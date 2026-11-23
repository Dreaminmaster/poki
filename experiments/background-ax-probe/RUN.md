# Background accessibility probe: how to run

Generate the project first. Signing uses your own team, passed on the command line.

```bash
cd experiments/background-ax-probe
xcodegen generate
```

Simulator, against the bundled fixture app (`SimProbe` scheme, iOS 27.3 runtime):

```bash
SIM=$(xcrun simctl create "AX probe" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro <iOS 27.3 runtime id>)
xcodebuild test -project BackgroundAXProbe.xcodeproj -scheme SimProbe -destination "id=$SIM" \
  -derivedDataPath .build/dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:SimProbeUITests/SimFixtureTests/testBACK_background
xcrun simctl delete "$SIM"; rm -rf .build
```

iPhone, against stock apps (`DeviceProbe` scheme). Developer Mode on, Settings in front during the run:

```bash
xcodebuild test -project BackgroundAXProbe.xcodeproj -scheme DeviceProbe -destination "id=<device UDID>" \
  -derivedDataPath .build/dd DEVELOPMENT_TEAM=<your team id> \
  -only-testing:DeviceProbeUITests/DeviceBackgroundAXTests/testF_concurrentUse
```

Assertions: `testF_concurrentUse` fails unless every background press is verified on the display, the assertion runs fail if a background snapshot or press fails while the background assertion is held, and `testJ1_backByEscape` fails if no action leaves the pushed screen. The other tests are measurement sweeps that log with `say` and do not assert.

Action 2025 crashes apps and is left out of every sweep. The first `Probe` scheme (`ProbeUITests/BackgroundAXActionTests.swift`) was the original simulator-only sketch and crashes with SIGSEGV. It is kept as a record only. Use `SimProbe` or `DeviceProbe`.

## On-device run (iPhone18,1, iOS 27.3 24C5037i), 2026-11-22 03:44-03:51 ET

Owner approved the phone run. Target: the original Calculator. Handset front app: Settings throughout.
Only addition to the phone: the probe's XCTest runner (`local.pokimcp.axprobe.uitests.xctrunner`),
uninstalled after the run. Raw lines: `device-run-results.txt`.

| Run | Mark | Assertion | Snapshot of background Calculator | AXPress "7" | Handset front |
| - | - | - | - | - | - |
| A (assertion) | grant | `_XCT_requestBackgroundAssertionForPID` -> granted (1) | | | Settings |
| A | +2 s, +15 s, +40 s, +120 s, +300 s | held | **timeout after 8 s** (every mark) | not reached | Settings |
| A | end | | Calculator state 3 (runningBackground, not suspended) | | Settings |
| B (control) | +2 s | none | timeout after 8 s | not reached | Settings |
| B | +15 s, +40 s | none | `Error Domain=com.apple.dt.xctest.automation-support.error Code=8 "Error getting main window kAXErrorServerNotFound"` | not reached | Settings |
| B | end | | Calculator state 2 (runningBackgroundSuspended) | | Settings |

Result: the background assertion works on the phone (Calculator stays running instead of being
suspended, and Settings keeps the foreground). But a running, non-frontmost app's accessibility
server does not answer snapshot requests (timeouts with the assertion; "server not found" once
suspended without it). Read and act by accessibility on a background app: **fail** on iOS 27.3.

## Second round on the phone, 2026-11-22 03:59-04:13 ET: it works

Questioning the first round: its helper never read Calculator in the foreground either. Run C showed the
helper's own snapshot (`XCAccessibilityElement elementWithProcessIdentifier:` + `requestSnapshotForElement:...`)
times out even with Calculator frontmost, so the 03:44 "fail" was a probe bug, not iOS. Raw lines:
`device-run-results-2.txt`.

- **D (04:04):** the helper's call took 65 s and failed with `XCTFuture Code=1000 "Timed out while fetching snapshot from testmanagerd.."`, foreground and background alike. XCTest's public `XCUIApplication(bundleIdentifier:).snapshot()` of the same Calculator returned **44 elements in 82-91 ms, also in the background** (Calculator state 3, Settings 4).
- **E (04:06):** the public snapshot is live in the background at +1/+5/+30/+120 s (44 elements, 55-154 ms). Keys are element type 20 (`.key`), not buttons.
- First press attempt crashed in `-[XCAXClient_iOS performAction:onElement:value:error:]` (`objc_retain` of 0x7da = 2010): the action argument is an object. Type encoding `B48@0:8@"XCUIAccessibilityAction"16@"XCAccessibilityElement"24@32^@40`. Fixed with `[[XCUIAccessibilityAction alloc] initWithAXAction:2010]`.
- **E (04:10-04:12), with Settings frontmost the whole time** (state 4 at every mark, the end screenshot shows Settings, the status bar shows "◀ Calculator"):

| Mark | Calculator state | Snapshot | Action (by element) | Display read in the background |
| - | - | - | - | - |
| +1 s | 3 running background | 44 elements, 55 ms | AXPress "7" ok=true | 1 -> **7** |
| +5 s | 3 | 44, 64 ms | AXPress "8" ok=true | 7 -> **78** |
| +30 s | 3 | 44, 85 ms | AXPress "9" ok=true | 78 -> **789** |
| +120 s | 3 | 44, 90 ms | AXPress "4" ok=true | 789 -> **7,894** |
| verification (foreground, one-off) | 4 | | | **7,894** |

**Result: an unchanged, original Calculator, kept running in the background by testmanagerd's background
assertion, was read and operated by accessibility element (no touch, no coordinates, no screen) while
Settings stayed in front.** Mechanism: `_XCT_requestBackgroundAssertionForPID:reply:` +
`XCUIApplication(bundleIdentifier:).snapshot()` + `-[XCAXClient_iOS performAction:(XCUIAccessibilityAction)onElement:value:error:]`.
Still to test: concurrency with the owner using the handset, text entry, apps other than Calculator,
and how long the assertion lasts.

## Concurrency with the owner using the phone, 2026-11-22 04:20-04:26 ET

Raw lines: `device-run-concurrency.txt`. The owner used the handset for about 5 minutes (another app at
+11-65 s, Notes around +65-110 s, then Settings from +247 s) while the probe pressed one digit every
~10 s in the background Calculator by accessibility element and read the display back.

- **28 of 28 presses landed and were verified on the background display** (2 -> 23 -> ... -> 2,345,678,912,
  cleared by element, then 3 ... and 4 ... -> 45,678,912). Each press plus read-back: 660-880 ms.
- Calculator stayed `runningBackground` (3) throughout and never came forward. The owner reported
  nothing odd on the handset: no flicker, no Calculator appearing, no misdirected touches.

## Generality, background Settings with Notes in front, 04:26-04:27 ET

Raw lines: `device-run-generality.txt`.

| Test | Result |
| - | - |
| a) navigation | AXPress on the "General" cell in the background Settings **opened General** (the next read lists About, Software Update, iPhone Storage, ...). The "About" press returned ok, but the next read 2 s later still showed General: unresolved (wrong element matched, or the push had not finished). |
| b) text entry | `setAttribute:value:element:` with attribute `XC_kAXXCAttributeValue` **set the Settings search field to "wifi"**, read back in the background. `AXValue`, `2006` and `AXValueAttribute` gave `kAXErrorIllegalArgument`. |
| c) scrolling | My guessed action numbers did not scroll: 2018 returned ok with no change; 2019, 2020, 2021 and 2008 returned `kAXErrorFailure`. The correct scroll action ids still need finding. |

Notes stayed `runningForeground` (4) and Settings `runningBackground` (3) throughout.

## Round 3 on the phone, 2026-11-22 04:30-04:33 ET

Raw lines (third-party labels redacted): `device-run-round3.txt`. Action ids taken from XCUIAutomation 27.3,
not guessed: `+[XCUIAccessibilityAction scrollToVisibleAction]` = 2003, `incrementActionForPlatform:` = 2004,
`decrementActionForPlatform:` = 2005. 2006/2007 as page down/up were a hypothesis.

| Test | Result |
| - | - |
| H1 scroll, background Settings | 2006, 2007 and 2003 all returned ok=true, but the tree's first and last labels did not change. **No scrolling observed.** The tree may already hold the whole list (Settings' first list), so this does not separate "scroll ignored" from "nothing to scroll". Open. |
| H2 two-level navigation | General opened (nav bar "General", back button and About cell present at +2, +10, +30 s, so the first push completed). The About cell (type button) from a **fresh** read after 30 s returned ok=true, but the tree still showed General at +2 and +10 s. Hypothesis (a), a stale element, is ruled out. Open between (b) the second push not completing and (c) the cell needing another action. |
| H3 attach to a background-launched app | Calculator killed, then launched from the Mac with `devicectl device process launch --no-activate`. It never came to the front (state 2, then 3 once the assertion took). The test attached by bundle id without launching it: assertion granted, read 39-40 elements, **press 5 -> 5, press 5 -> 55**. **Poki does not need to flash the target forward.** |
| H4a LookUp (third-party) | Background read with Settings in front: 72 elements (word list, tab bar). The tab-switch press was not attempted: my filter found no button children in the tab bar. |
| H4b Notion (third-party, web-view heavy) | Background read with Settings in front: **354 elements, including the owner's page titles**. No tab bar found. No press. |

The probe runner was uninstalled after the run.

## Round 4 on the phone, 2026-11-22 04:35-04:37 ET

| Test | Result |
| - | - |
| Scrolling, background Settings root | **Works.** Action 2006 on the collection view (type 32): visible cells 11 -> 16, first cell frame y 168 -> -25, so the list moved down a page. 2007 moved it back up (first y 542). Scroll-to-visible (2003) on the last cell moved it again (first y -389). Round 3's "no change" was my probe comparing labels, which are empty on these cells. |
| Navigation, two levels | General opened (nav bar "General"). Pressing the "Settings" back button failed with `kAXErrorFailure`. **After waiting 60 s, the About row opened About** (nav bar "About"). In round 3 the same press after 30 s did not. Pressing About's non-actionable children failed with `kAXErrorFailure`. Working hypothesis: the first push's transition takes 30-60 s to finish in the background, and a second push waits for it. Not confirmed (no app-side logs). |
| Notes, two levels | Not tested: Notes was open on a note, with no cells to press. |
| LookUp tab switch | Tab items found under the tab bar (buttons with image children). AXPress failed with `kAXErrorFailure` on both an image and a tab button. Open. |

The probe runner was uninstalled after the run.

## Round 5 on the phone, 2026-11-22 04:41-04:47 ET: back and tab actions

- XCTest's `XCUIAccessibilityAction` descriptions on 27.3 carry no names (`AXAction:2000` ... `AXAction:2069`), and the phone's AXRuntime exports none of the likely `kAX...Action` symbols by name (dlsym found none). So no action name could be read from the binaries on this phone.
- A measured sweep of actions 2011-2040 on the background Settings General page (app element, navigation bar, "Settings" back button): ok=true for 2013-2016, 2018, 2022 and 2024, but **none popped back to the root** (nav bar stayed "General"). **Action 2025 on the app element crashed Settings** (crash log Preferences-2026-11-22-044517.ips).
- The same sweep on LookUp's "Collect" tab button and its tab bar: 2010 (press) failed, and nothing changed the selected tab. **Action 2025 crashed LookUp** (LookUp-2026-11-22-044659.ips). Increment/decrement on the tab bar: no change.
- Both apps relaunch normally. No data was created or changed. The probe runner was uninstalled.
- Conclusion: back buttons and tab bar buttons in a background app are not operable by AX action on 27.3 with the actions found. **Do not sweep unknown action numbers again: 2025 crashes apps.**

## Simulator fixture (ours), 2026-11-22 05:00-06:00 ET

Fixture `AXFixture/App.swift` (UIKit controls, a 500-row table, tabs, nav, alert, sheet, SwiftUI) logs every
handler. Tests `SimProbeUITests/SimFixtureTests.swift`. Simulator iPhone 17 Pro, iOS 27.3.

**Action numbers** (from the fixture's overrides; background, with the assertion):

| Id | UIKit entry point |
| - | - |
| 2001 / 2002 | accessibilityZoomIn / ZoomOut |
| 2003 | scroll-to-visible (kAXErrorFailure on a non-scrollable element) |
| 2004 / 2005 | accessibilityIncrement / Decrement |
| 2006 / 2007 / 2008 / 2009 | accessibilityScroll down (4) / up (3) / right (1) / left (2) |
| 2010 | accessibilityActivate |
| 2011 | accessibilityPerformMagicTap |
| 2013 | accessibilityPerformEscape |
| 2019 / 2020 | accessibilityScroll next (5) / previous (6) page |
| 2025 | **crashes the app**: `-[NSObject(AXPrivCategory) _iosAccessibilityPerformAction:withValue:fencePort:]` -> `_accessibilityAnnouncementComplete:` -> `+[NSDictionary dictionaryWithObjects:forKeys:count:]` with a nil value -> SIGABRT. Never send it. |
| 2012, 2017, 2021, 2023, 2032-2036, 2040 | kAXErrorFailure on this element. Others: ok with no entry point fired. |

**Controls** (action 2010 unless noted):

| Control | Background (Settings in front) | Foreground |
| - | - | - |
| UIButton | fail kAXErrorFailure, no handler | **fail kAXErrorFailure** |
| UISwitch | fail | **fail** |
| UITableViewCell | fail | **fail** |
| UITabBarController tab | fail | **fail** |
| Buttons that show an alert / sheet (UIButton) | fail | fail |
| UIBarButtonItem | ok, handler fired | ok |
| UISegmentedControl segment | ok, handler fired | ok |
| UISlider (2004) | ok, handler fired | ok |
| UITextField (set XC_kAXXCAttributeValue) | ok, handler fired, value read back | ok |
| Table page down (2006) | ok | ok, table scrolled |
| Element with its own accessibilityActivate | ok, handler fired | ok |
| Escape 2013 on the navigation bar | kAXErrorFailure (no pushed screen: see below) | **ok, popped Level 3 -> Level 2** |
| Push (bar button handler calls pushViewController) | handler fired, **the pushed screen never appeared within 90 s** (no willShow) | appeared in 0.1-9 s |

So the four failing controls fail **in the foreground as well**: their 2010 failure is not caused by the
background or by having no display. It is the accessibility activate path for those UIKit classes when the
request comes from XCTest's AX client. On the phone, Calculator keys and Settings rows worked because
those classes handle activation themselves. Separately, a UIKit push inside a backgrounded fixture waits
(Settings on the phone pushed one level).

lldb attach to the fixture worked, but breakpoints in the simulator's shared cache did not resolve within
the time limit, so the exact failing check is not yet traced.

## Tap-only controls: why they cannot be operated in the background (simulator, our fixture), 11:00-12:10 ET

Correction to the earlier reading: plain UIButton, UISwitch, UITableViewCell and tab bar buttons fail the
accessibility press (2010) **in the foreground as well** (kAXErrorFailure, no handler). UIKit does not
implement activation for these classes. Assistive clients (VoiceOver, Switch Control) operate them with a
real touch.

| Route (fixture's plain button, switch, tab) | Foreground | Background (Settings in front) |
| - | - | - |
| XCTest AX press 2010 | fail, no handler | fail, no handler |
| Value / selected / focused setters, focus then press, ids 2001-2040 except 2025 | no handler | no handler |
| `-[AXElement press]` (AccessibilityUtilities, VoiceOver's layer) | **handler fired** (button, switch, tab) | returned YES, **no handler, and the tap landed on Settings** (root list -> Apple Account sign-in sheet) |
| `-[AXElement simulateTapWithFingerIndex:]` | handler fired | no handler |
| `AXEventRepresentation` touch (hand types from the system describer: 1 Touched, 2 Moved, 6 Lifted) with the fixture's foreground context id set, posted via `-[AXBackBoardServer postEvent:systemEvent:]` | | **no handler, Settings unchanged** (event dropped) |

Why, from the fixture's own log of its window:
- in front: `contextId=3593599260 layer.context=<CAContext ...> activation=0`
- after `sceneDidEnterBackground`: next tick `contextId=0 layer.context=nil activation=2`

**The backgrounded app's window has no render context at all.** There is nothing a touch could be addressed
to. A touch either falls back to the screen position (and hits the front app) or is dropped.

**Hard rule for Poki: never use `AXElement press` or `simulateTap` on a background target. They become screen
touches on whatever app is in front.**

Tap-only UIKit controls in a background app are therefore not operable by any route found. Background
operation covers elements that implement accessibility activation themselves, value-type controls (slider,
segmented control, text field set-value), scrolling, and escape (in the foreground).

## In-app accessibility inventory (simulator, our fixture), 12:10-13:00 ET

- **lldb, both presses on the plain button (foreground):** XCTest's AX press and `-[AXElement press]` both enter the app at the same place: `_XPerformActionWithValue` -> `_AXXMIGPerformActionWithValue` -> `-[NSObject(UIStorage) _iosAccessibilityPerformAction:withValue:fencePort:]` with action 2010, which fails for UIButton. AXElement's success is a second step on the client side: the button's action then arrives through `-[UIApplicationAccessibility sendEvent:]` -> `-[UIWindow _sendTouchesForEvent:]` -> `-[UIControl touchesEnded:withEvent:]` -> `_sendActionsForEvents:`. That is a real HID touch from outside, not an in-process path.
- **App-side dispatcher** `_iosAccessibilityPerformAction:withValue:fencePort:` dumped from a live breakpoint (1,403 instructions). It reaches 83 `_accessibility...` selectors, listed in `dispatch-selectors-27.3-sim.txt`, among them `_accessibilitySetNativeFocus`, `_accessibilitySetFocusOnElement:`, `_accessibilityDispatchKeyboardAction:`, `_accessibilityPerformUserTestingAction:`, `_accessibilitySecondaryActivate`, `_accessibilityPerformCustomActionWithIdentifier:`, `_accessibilityShowContextMenuWithTargetPointValue:`, `_accessibilityAnnouncementComplete:`. It compares action ids 4019-4023 directly (0xfb3-0xfb7).
- **Ids mapped by overriding those selectors in the fixture's own element:** 2036 = `_accessibilitySecondaryActivate`, 2044 = `_accessibilitySetNativeFocus`, 2042 = XCTest's `kAXBeginMonitoringIdleRunLoopAction` (killed the fixture). 2045-2120, 4000-4060, 5000-5040 with no value: no entry point on our element.
- **Focus route on the bare controls:** 2044 (set native focus), 2010 and 2036 on the plain button, switch and tab: kAXErrorFailure in foreground and background. 4021 and 4023 with a string value: kAXErrorCannotComplete, then the fixture died. A Full Keyboard Access default was set in the simulator for one repeat (key name unverified, removed afterwards): no change.
- Not yet found: the action id and value type for `_accessibilityDispatchKeyboardAction:` and `_accessibilityPerformUserTestingAction:`. The dispatcher's jump table has not been decoded.

## Round: key events and the focus system (simulator 27.3, our fixture only), 2026-11-22 ET

- **Key delivery works in the background.** Action 2034 with an NSData `AXEventRepresentation` key event
  (type 4500/4501, `keyInfo` input and HID usage) on the application element goes to
  `-[UIApplicationAccessibility _accessibilityDispatchKeyboardAction:]`, which builds a `UIPhysicalKeyboardEvent`
  in-process and hands it to `UIKeyboardImpl handleKeyCommand:` / `handleKeyUIEvent:`. The fixture's
  `UIKeyCommand("k")` fired in foreground and background, via the XCTest daemon and via a direct AXElement.
- **Focus system gate on iPhone** (read from UIKitCore): `_UIFocusBaseBehaviorForTraitCollection` picks the FKA
  behavior when `_AXSFullKeyboardAccessEnabled()`. The FKA behavior requires a hardware keyboard unless the app's own
  preference `FullKeyboardAccessUsesSimulatedKeyboardForAutomation` is YES (`CFPreferencesGetAppBooleanValue`, so a
  launch argument `-FullKeyboardAccessUsesSimulatedKeyboardForAutomation YES` sets it).
  With FKA on and the argument: live focus system, and 2044 moves native focus onto the switch, the table cell and
  the tab button (foreground). FKA off + argument: no focus system. Background: no focus system either way
  (`_UIFocusSystemSceneComponent _updateFocusSystemState` disables it when the scene is not active).
- **Activation of the focused item:** Space/Return via 2034 (with HID codes) select nothing; 2034 bypasses the focus
  engine. A real hardware Space (XCTest `typeKey`, foreground) reaches the fixture only as `pressesBegan`.
  The FKA daemon's Space command ("PerformDefaultAction", `-[FKAActionManager performDefaultAction]`, read
  statically from `FullKeyboardAccess.app`) is `[[self currentElement] press]`, the AXElement press: AX activate,
  otherwise a synthesized touch at the element's screen point. 2010, 2036 and 2011 on the application element with
  focus set: kAXErrorFailure.
- FKA's own in-app ops found in the dispatcher: 5305 `_accessibilitySetFocusEnabledInApplication:` (bool),
  5307 `_accessibilityDidFocusOnApplication`, 5308 `_accessibilitySetFocusOnElement:` (bool),
  5312 `_accessibilityClearLastFocusedChild`; `_accessibilityHandleFullKeyboardAccessAction:value:` handles
  5310/5311/5313 (scene key-window, reset native focus, update native focus). None activates.
- **Switch via its own key commands:** `UISwitchAccessibility accessibilityActivate` returns NO by design, but
  `_accessibilityKeyCommands` publishes arrow-key commands whose actions `_fkaSwitchOn/_fkaSwitchOff` call
  `_keyboardActivate` (in-process toggle). Foreground, launch argument + FKA: 2044 native focus on the switch, then
  Right arrow via 2034 → handler "switch true", no touch. Left arrow did not toggle it back. Without native focus
  (none, or 5308 AX focus) nothing fires. Background: 2044 fails (no focus system), so nothing fires.
- **Attribute setters** (`_iosAccessibilitySetValue:forAttribute:`): 2006 `_accessibilitySetValue:` (implemented
  only by slider and text classes), 2005 selected text range, 3002 becomeFirstResponder, 2018 "focused" dict,
  2208 `_accessibilitySetSelectedChildren:` (empty base stub, no override). Nothing for switch, cell, tab, button.
- **Key commands without focus:** a real hardware Cmd-2 does not switch tabs on iPhone (reaches the app as
  pressesBegan). Arrows/Return/Space via 2034 select no row. The 2034 path drops modifier flags (Cmd-K command
  did not fire for any modifierState/gsModifierState encoding; a hardware Cmd-K did).
- **Focus plus keys, foreground:** with native focus on the cell, a tab button or a plain button, arrows, Return and
  Space via 2034 neither move focus nor select. 2034 runs key commands found from the responder chain of the
  focused item; the switch's own arrow commands are the only stock control commands among our four.
- **Background focus is possible:** with the launch argument and FKA on, in the background, 5305 (`_accessibilitySetFocusEnabledInApplication:` YES)
  re-enables the focus system, 5310 with the scene identifier (`sceneID:<bundle>-<uuid>`) makes the window key, and
  2044 puts native focus on the switch. Settings stayed in front and unchanged.
- **The switch's command runs in the background, but its effect is a touch:** hooks inside the fixture show the arrow
  key reaches `-[UISwitchAccessibility _accessibilityKeyCommands]` via `UIApplication _handleKeyUIEvent:` →
  responder chain, and `_fkaSwitchOn` → `_keyboardActivate` is called in the background. `-[NSObject(AccessibilityActivation)
  _keyboardActivate]` builds an IOHID digitizer finger event at `accessibilityActivationPoint`, tags it with
  `_accessibilityGetContextID`, and enqueues it into the app itself (`[UIApp _enqueueHIDEvent:]`), in-process.
  In the foreground this toggles the switch (Right → on, Left → off). In the background the window's `layer.context` is nil
  (fixture log, activation state 2), so the touch has no window context and nothing happens.
- **Common gate:** every activation path found for the four stock controls ends in a touch, either from the
  system (AXElement press, FKA) or in-process (`_keyboardActivate`). All of them need the window's render context,
  and iOS removes that context when the scene leaves the foreground.

### Background focus: the three FKA commands (simulator 27.3, fixture)

Prerequisites: Full Keyboard Access on (`_AXSFullKeyboardAccessEnabled`), app launched with
`-FullKeyboardAccessUsesSimulatedKeyboardForAutomation YES`. Sent with `performAction:onElement:value:` through the
XCTest daemon, in the background with Settings in front:

| id | element | value | in-app call | effect |
|---|---|---|---|---|
| 5305 | application | NSNumber YES | `_accessibilitySetFocusEnabledInApplication:` → preferred window's focus system `_setEnabled:` | focus system enabled again in background |
| 5310 | application | NSString scene id `sceneID:<bundle>-<uuid>` | `_accessibilityHandleFullKeyboardAccessAction:value:` → matching scene's window `makeKeyWindow` | window key (returns failure without the id) |
| 2044 | control | nil | `_accessibilitySetNativeFocus` | native focus on the control (switch, cell, tab button) |

### The in-process touch and where it stops in the background

- Helper: `-[NSObject(AccessibilityActivation) _keyboardActivate]` (UIKitCore), generic for every NSObject. It uses
  `_keyboardActivateEventDown:` (an IOHID digitizer finger event at `accessibilityActivationPoint`,
  `BKSHIDEventSetDigitizerInfo` with `_accessibilityGetContextID`), then `[UIApp _enqueueHIDEvent:]` → `UIEventFetcher _receiveHIDEvent:`.
  Down now, up after a `dispatch_after`. It's reached from the switch's FKA key commands (`_fkaSwitchOn/_fkaSwitchOff`).
- Trace in the fixture (fixture key command "j" calls `_keyboardActivate` on the plain button):
  - FG: contextID 3906509242 → `UIApplication sendEvent:` ×2 → `UIControl touchesBegan/Ended` → button action.
  - BG (window not hidden, key, activation 2, `layer.context` nil): contextID 0 → no `sendEvent:` at all.
    Substituting the last FG context id: still no `sendEvent:`.
- Exact gate: `_UIEventHIDUIWindowForHIDEvent` reads the contextID from `BKSHIDEventGetBaseAttributes`; 0 → nil.
  Otherwise `+[UIWindow _windowWithContextId:]` = `[CAContext contextWithId:].layer` → `_UIWindowFromRootLayer`.
  With no live CAContext in the process there's no window, so the event is dropped before `sendEvent:`.
- What removes the CAContext: `-[UIWindowScene _prepareForSuspend]` → `-[_UIContextBinder purgeContextsWithPurgeAction:afterPurgeAction:]`,
  called from `UIScene scene:didUpdateWithDiff:transitionContext:completion:` when FrontBoard updates the scene settings.
  `-[UIWindowScene _prepareForResume]` → `createContextsWithTest:creationAction:` → `+createContextForBindable:withSubstrate:` recreates it on return.
  The testmanagerd background assertion keeps the process running, but doesn't stop the purge.

### testmanagerd (iOS 27.3 DDI, static strings only) and SpringBoard test automation

- Runner→daemon launch calls: `_XCT_launchApplicationWithBundleID:arguments:environment:completion:`,
  `_XCT_launchApplicationWithBundleID:path:arguments:environment:completion:`, `_XCT_launchProcessWithPath:bundleID:arguments:environmentVariables:`,
  `_XCT_openURL:usingApplication:completion:`, `_XCT_openURL:processPath:bundleID:arguments:environmentVariables:`. None takes an
  options dictionary or a display. Internally it uses an `XCTDFBSOpenApplicationService`.
- Display awareness: `XCTDDisplayManager`, `_resolvedDisplayForID:`, `_keyboardSenderForDisplayIdOrMain:`, `_buttonSenderForDisplayId:`,
  `_typeKey:modifiers:displayID:completion:`, plus "Failed to resolve displays. Defaulting to generic keyboard sender" and
  "Using touch screen digitizer sender for button event on the main display". This picks HID senders per display for synthesized
  events (system path, so they land on whatever is on that display). No string creates or attaches a virtual display, though the
  daemon holds `backboardd.virtualDisplay`/`virtualframebuffer`.
- `SBSTestAutomationService` (SpringBoardServices) has 54 methods, including `setChamoisWindowingUIEnabled:`,
  `countScenesForBundleIdentifier:withCompletion:`, `getActiveDisplayWindowSceneDisplayIdentifierWithCompletion:`, `suspendAllDisplays`,
  and `togglePictureInPictureProminence`. Of these, testmanagerd references only `setDeviceOrientation:` and `setOrientationLockEnabled:`.
- Other daemon calls of note: `_XCTD_setFrontProcess:`, `_XCT_playBackHIDEventRecordingFromData:reply:`, VoiceOver enable/move,
  `_XCTD_performHandGesture:`, `_XCTD_performDeviceEvent:`. None changes a scene's foreground state.

### The last gate, isolated (fixture diagnostics)

- With the fixture's own window kept alive in the background, the in-process touch from `_keyboardActivate` fires the plain button
  in the background (state 2, Settings in front): `sendEvent:` → window → `UIControl touchesBegan/Ended` → handler "button".
  This holds with any one of these, set by the fixture itself:
  `+[UIWindow _setAllWindowsKeepContextInBackground:YES]` before the scene exists,
  `-[UIWindowScene _setKeepContextAssociationInBackground:YES]` (binder `contextManagementPolicy` ≠ 0, so purge returns early), or
  `-[UIWindow setKeepContextInBackground:YES]` (read in `_bindingDescription`; `__UIContextBinderDisposeContextForBindable` skips the window).
- So the four controls need two things in the background: an in-process activation (we have it for the switch via its FKA key
  commands), and a live window context.
- Who can set these switches: in a normal app nothing calls `setKeepContextInBackground:` (breakpoint over launch, background, foreground).
  No loaded framework references `+_setAllWindowsKeepContextInBackground:`. The scene policy comes only from the global at scene init.
  `_alwaysGetsContexts` is YES only for UIKit's own internal window classes (remote keyboard, snapshot, drag, client renderer).
  No UIKit defaults key, launch argument, accessibility id or attribute found for any of them.
- A background snapshot refresh (`-[UIApplication _updateSnapshotForBackgroundApplication:]`) doesn't recreate the context.

### Who can set keep-context, and outside levers (reading, simulator 27.3)

- Callers, from a bl-decode of UIKitCore `__text`: `setKeepContextInBackground:` only in `-[_UIHostedWindow initWithFrame:]`;
  `_setKeepContextAssociationInBackground:` only in `+[UIWindow _setAllWindowsKeepContextInBackground:]`,
  `-[UIWindowScene initWithSession:connectionOptions:]` and `-[_UIHostedWindowScene initWithSession:connectionOptions:]`.
  With 33 feature frameworks loaded (AVKit/PiP, AirPlay, CarPlay, ReplayKit, ScreenCaptureKit, screen sharing, Sidecar, Live Activities,
  scene hosting, widgets), no other image has a stub for these. In all 3,410 runtime executables the selector strings appear only in
  SpringBoard, OverlayUI, druid and pointeruid.
- AX side storage: the only outside write is in the set-attribute dispatcher, with the fixed key `AXShowOnscreenKeyboardWithBraille`.
  Action and attribute blocks (`AccessibilityActionBlockStorageKey`, `AccessibilityAttributeBlockStorageKey`) are filled by in-app code.
  The base `_accessibilityUserTestingActions` is empty. `_accessibilityKeyCommands` is fixed per class (NSObject base: adjustable and
  directional-focus arrows).

## Coverage table (simulator 27.3, fixture `-coverage` mode, 2026-11-22 ET)

Every control logs its handler. "BG" = fixture in background with testmanagerd's assertion, Settings in front; Settings stayed
unchanged after every group (front check). Actions: 2010 activate, 2036 secondary activate, 2004 increment, 2054 Return key
(after setting the value with `XC_kAXXCAttributeValue`), "key Return" = 2034 key event, "FKA" = 5305 + 5310 + 2044 focus, then an arrow key via 2034.
Launched with `-FullKeyboardAccessUsesSimulatedKeyboardForAutomation YES`, FKA on in the simulator.

| control | read | FG | BG |
|---|---|---|---|
| UIButton, Configuration + primaryAction | ok | no (2010/2036/FKA Space) | no |
| UIButton, addAction(UIAction) | ok | no | no |
| UIButton, target-action | ok | no | no |
| UISwitch | ok | FKA Right arrow | no (in-process touch, no context) |
| UIStepper | ok | FKA Right arrow (2004 accepted, no change) | no |
| UIPageControl | ok | 2004 | **2004** |
| UIDatePicker (compact) | ok | no | no |
| UIPickerView | ok | 2004 | **2004** |
| UISearchBar Return | ok | set value + 2054 | no (2054 fails in BG) |
| UITextField Return (primaryAction) | ok | set value + 2054 | no |
| UIButton with menu (open) | ok | no | no |
| UIMenu item (menu opened by tap) | ok | no | no |
| Context menu via 2059 | ok | crashes the fixture | crashes the fixture |
| UIBarButtonItem (primaryAction) | ok | 2010 | **2010** |
| Bar button item on pushed VC (target-action) | ok | 2010 | **2010** |
| Navigation back button | ok | no (2010/2036/2013) | no |
| Push button (plain UIButton) | ok | no | no |
| UITab bar button (iOS 18 UITab) | ok | no | no |
| UIAlertController alert button | ok | 2010 | **2010** |
| UIAlertController action-sheet row | ok | 2010 | **2010** |
| UICollectionViewListCell select | ok | no | no |
| UICollectionViewListCell detail accessory | not found | - | - |
| UITableViewCell (content configuration) | ok | no | no |
| SwiftUI Button | ok | 2010 | **2010** |
| SwiftUI Toggle | ok | 2010 | **2010** |
| SwiftUI Stepper | ok | 2004 | **2004** |
| SwiftUI Slider | ok | 2004 | **2004** |
| SwiftUI segmented Picker | ok | 2010 | **2010** |
| SwiftUI menu Picker / Menu (open) | ok | 2010 opens a menu; label then unreadable | same |
| SwiftUI Menu item | not found after open | - | - |
| SwiftUI TextField onSubmit | ok | no (2054 and key Return) | no |
| SwiftUI NavigationLink row | ok | 2010 | **2010** |
| SwiftUI TabView tab (inside UIKit) | ok | not run in FG (hidden by menu) | no |
| SwiftUI sheet button | ok | 2010 | **2010** |
| SwiftUI alert button | ok | 2010 | **2010** |
| WKWebView link | ok | 2010 | no |
| WKWebView button / checkbox / submit | ok | 2010 | not found in BG (web content AX tree gone) |
| WKWebView text input | ok | no (2054 fails, key Return no submit) | not found |

Background summary: SwiftUI controls (Button, Toggle, Stepper, Slider, segmented Picker, NavigationLink, sheet and alert
buttons), UIKit alerts and action sheets, bar button items (primaryAction or target-action), page control and picker wheels
work in the background through 2010/2004, with nothing reaching the front app. Not in the background: plain UIButtons in every
form, UISwitch/UIStepper, list and table cells, tab bar buttons, back button, menus, Return-key submission, date picker, and
WKWebView content.

### Hosted scenes and the suspend decision (reading, simulator 27.3)

- `_UIHostedWindow` is UIKit's window for view-service and extension processes whose UI is drawn in another process's host view
  (`hostingHandle`, `_setHostBundleIdentifier:`, `_remoteContentParent`). `PGHostedWindow` (PegasusKit) is PiP's version
  (`ForceHostedWindowBackedPIP`, "RoutingVideoToHostedWindow"). `_UIHostedWindowScene` belongs to scene hosting (`UISceneSessionRoleSceneHosting`,
  `LACUIHostedWindowScene` for LocalAuthentication). An app's own main scene is a plain `UIWindowScene`, and no route found
  makes a third-party app's main UI a hosted scene.
- Suspend: `-[_UIWindowSceneFBSSceneLifecycleMonitor transitionToTargetState:fromState:withTransitionContext:preparations:]` computes the
  target activation from FrontBoard settings with `+[UIScene _activationStateFromSceneSettings:]`, which reads `isForeground`, `underLock`
  (with `_UISceneLifecycleStateIsSEO`) and `deactivationReasons`. Leaving the foreground runs `_prepareForSuspend` (context purge);
  returning runs `_prepareForResume`. So the context lives while FrontBoard reports the scene as foreground, active or inactive
  (inactive = foreground with deactivation reasons). It goes away when the scene is background.
- Short-lived resumes: `-[UIApplication _performSnapshotsWithAction:forScene:completion:]` (SpringBoard snapshot actions via
  `_UISceneSnapshotBSActionsHandler`), `-[UIApplication _performRefreshForUIScene:disposeAfter:completion:]` (from the app's own
  `requestSceneSessionRefresh:`) and background-event state restoration (`_handleNonLaunchSpecificActions:`) each call `_prepareForResume`, then
  `_prepareForSuspend`, synchronously on the main thread. An externally queued event runs after that. Matches the diagnostic:
  `_updateSnapshotForBackgroundApplication:` left the context nil.

### Alternative paths, round 2 (simulator 27.3, fixture), 2026-11-22 ET

Background, Settings in front (unchanged afterwards); all no effect on the handler:
- Back: 2013 (escape) on the app element (fails), on the pushed screen's navigation bar and on its bar item (accepted, no pop).
- Tabs: 2004/2005 on the tab bar (accepted, no change); 2006–2009, 2019, 2020 fail.
- Cells: FKA focus (5305 + 5310 + 2044) on a list cell works, then Return, Space or Down via 2034 selects nothing. Focus on the table cell fails.
- Text and search fields: first responder via attribute (`XC_kAXXCAttributeFocused` / 3002) fails; set value + Return key event, no submit; 2054 fails.

**Foreground but covered (new measurement):**

| overlay | fixture activation / context | in-process tap (`_keyboardActivate` via fixture "j") | switch via FKA focus + Right | context-addressed AX touch (AXBackBoardServer, ctx + pid) | 2010 on plain button |
|---|---|---|---|---|---|
| Control Center | 1 (foreground inactive), context live | **fires button** | **toggles** | no | fail |
| App switcher | 1, context live | **fires button** | **toggles** | no | fail |
| Notification Center | 2 (background), context nil | no | no | - | fail |

So with a scene that's foreground but inactive (covered), the switch works from outside today. Plain buttons, cells and tabs still need
an outside way into `_keyboardActivate`, which only the switch's FKA key commands give.

### Launch options (reading)

- FrontBoard `FBSOpenApplicationOptionKey…`: Actions, ActivateAsClassic, ActivateForEvent, ActivateSuspended, AppLink, DebuggingOptions,
  DocumentOpen, LaunchAppArguments, LaunchIntent, LaunchOrigin, PayloadURL/Options/Annotation, PromptUnlockDevice, UnlockDevice, UserActivity, Persona, ….
- SpringBoard `SBSOpenApplicationOptionKey…`: AdditionalApplications, DisplayDeviceName, DisplayUniqueIdentifier, InsertIntoCenterStage,
  LaunchPreferCenterZoom, LaunchSceneless, LaunchWithoutAnimation, LayoutRole, MigrateContentToScene, PreventDismissalOfTransientOverlays,
  SceneIdentifier, WindowingArrangement, WindowingFormat, DoNotDismissSiri, ….
- What we can reach: `devicectl device process launch` exposes only `--activate/--no-activate`, `--display` (refused earlier at the
  display-lookup gate), `--payload-url`, `--background-content-fetching-enabled`, `--start-stopped`, environment and arguments. testmanagerd's
  launch takes bundle id, path, arguments and environment only. LayoutRole, WindowingFormat/Arrangement and InsertIntoCenterStage aren't reachable.
- `devicectl device appResize start` ("Moves the frontmost apps to a resizable display …" whose name contains "Resizable") is the
  supported route for moving an app to another display. Earlier in this project the phone answered `device info appResize` with
  "does not offer the on-device service … Resizable App Management" (`com.apple.coredevice.feature.resizableappmanagement`, error 1001).

### Covered states, the covered-state touch, `_keyboardActivate` callers, round trip (simulator 27.3)

- Deactivation reasons (`UIApplicationSceneDeactivationReasonDescription`): 0 systemGesture, 1 notificationCenter, 2 controlCenter,
  3 appSwitcher, 4 siri, 5 systemAnimation, 6 interactiveBanner, 7 systemOverlay, 8 keyboardSuppression, 9 airPlay,
  10 fullscreenTransientOverlay, 11 occluded, 12 pip, 13 systemModalAlert, 18 libraryOverlay, 19 sceneOverlap, 30 underLock.
  Each is a system presentation over the app (or windowed-multitasking overlap). None stands for an ordinary app shown on top on iPhone.
  Measured: Control Center and the app switcher leave the fixture foreground-inactive with its context. Notification Center backgrounds it.
- Covered-state context-addressed AX touch (AXBackBoardServer, ctx + pid): the fixture logs no `UIApplication sendEvent:` for it, while the
  in-process tap and the switch's key path in the same run log `sendEvent:` → window → control. The touch is dropped or routed outside
  the app (backboardd), not by a UIKit check.
- `_keyboardActivate` callers (bl-decode of UIKitCore, UIKit.axbundle, UIAccessibility, SwiftUI, SwiftUICore): only
  `UISwitchAccessibility _fkaSwitchOn/_fkaSwitchOff` and `UIStepperAccessibility` key-command plus/minus. `_enqueueHIDEvent:` is called only by
  `_keyboardActivate` and `_UIRemoteViewControllerLegacyImpl __trampolineButtonPressData:`. So there's no outside path to an in-process tap
  for buttons, cells or tabs.

## Background back button (Nov 22 2026, 2 pm to 5:50 pm ET)

Our fixture (`local.pokimcp.axfixture`) on the UIKit tab with Detail pushed, kept running in the background by the testmanagerd background assertion, with Settings in front throughout.

- Escape (action 2013) on the fixture's navigation bar is accepted in the background, but the pop is held as a deferred transition until the navigation controller's view lays out. Without a layout pass the fixture stays on Detail.
- Reading parameterized attribute 95005 on the application element with `{"AXAuditClippingTest": {"AXAuditShouldRunTestOption": true}}` runs the system accessibility audit's layout pass (`_axAuditCheckDynamicTextSupport:andClippingIssues:spinRunloop:` lays out the frontmost view controller's view), and that releases the held pop.
- In the simulator the direct `AXUIElementCopyParameterizedAttributeValue` call from the test runner works. On the phone it is refused: the runner gets permission denied for the `com.apple.iphone.axserver` port (error -25215).
- The route that works on both is the testmanagerd request `_XCT_fetchParameterizedAttributeForElement:attributes:parameter:reply:` with an NSNumber attribute. On the phone (iPhone 17 Pro, iOS 27.3) it answered in 0.2 s with error 13 `kAXErrorNoValue` (no clipping issues found), the pop completed within a second, Settings stayed in front, and the test session kept answering.
- The string-named request `_XCT_fetchParameterizedAttribute:forElement:parameter:reply:` cannot carry 95005: testmanagerd maps the string through the named `kAXXC...` table, which has no audit entry, so it becomes "(null)". An NSNumber sent to that request is dropped by XPC decoding.
- The DynamicText option (`AXAuditDynamicTextSupportTest`) also pops, but its reply never reaches the runner (30 s timeout while testmanagerd logs the value in about 0.6 s).
- No persistent side effect found: frames unchanged after the audit, no crash reports, testmanagerd pid unchanged.
- Action 2010 (press) on a UIButton, switch, stepper, tab bar button and menu button still fails in the background (`kAXErrorFailure`), and the audit pass changes nothing there, since nothing is queued.
- Closed routes this session: in-process UIPress via actions 4000 to 4007 (no event without a window context; works only in the foreground); XCTest `performAccessibilityAudit` (error -902 "Invalid target app": `-[AXAuditAutomationSupport _runAudit]` in testmanagerd only accepts apps in the focused applications list, attribute 1102).

The phone runs installed only the fixture and its test runner; both were uninstalled after each run.
