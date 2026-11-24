# Background accessibility prototype

Poki operates an app that stays in the background while the owner keeps using the phone. The target app is never brought to the front.

## How it works

- Poki's XCTest session keeps testmanagerd's background assertion on the target app, so it is not suspended.
- The target is read and driven through accessibility: element snapshots, `performAction`, attribute setters and scroll actions.

## What works on the phone (iPhone18,1, iOS 27.3)

- Background Calculator read and operated while Settings stayed in front: 28 of 28 presses landed and were read back.
- The same while the owner used other apps at the same time.
- Third-party apps can be read, text can be typed, lists scroll, and an app launched hidden can be attached.
- The navigation back button works in a background app (0.2 s, Settings in front): an escape action on the navigation bar, then one audit read through testmanagerd so the app lays out.

## Open

- Not yet delivered in the background: plain UIButton, switch, stepper, table and collection rows, tab bar, button menus, Return and web content. Action 2025 crashed apps, so the unknown-action sweep is simulator only.
- Some screen changes take about 60 s to show in the background tree.
- Tap-only controls lose their render context once the scene is suspended. See RUN.md for the gate and what was tried.

## Layout

- `DeviceProbeUITests`: the on-device probe. `SimProbeUITests` and `AXFixture`: the simulator fixture and coverage table.
- `device-run-*.txt`: raw logs from the phone runs. `RUN.md`: the full record, with build and run commands.

The earlier secondary display trials are not part of this prototype.
