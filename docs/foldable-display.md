# Foldable display experiments (unfinished)

This is the local experimental snapshot requested in issue #20, based on commit
`7ee03e3`. It is shared for maintainer review, not as verified two-display support.
The installed MCP checkout was rolled back separately and remains unchanged by
this draft. The runtime changes in this draft are the archived experiment; only
these handoff notes were updated for publication.

## Observations and hypotheses

On a two-integrated-display physical iPhone, the cached AX subscription returned
one SleepLockScreen root with no children while the unlocked Settings app was
visible. Control Center could produce a populated SpringBoard tree. The reason
for the cached service's selection is not established.

With the inner panel active in portrait, the primary panel was inactive. The
DVT default screenshot could be black, whereas a CoreDevice screenshot explicitly
selecting the active panel produced a normal image. HID enumeration exposed a
separate touchscreen service for each panel.

## Experimental changes

- Discover the active integrated display through CoreDevice device information.
- Select its unique ID for secondary-panel screenshots and its numeric ID for
  input media. Select the corresponding touchscreen HID service by unique ID.
- Keep the existing drag and multitouch scheduling, release/error handling, and
  text-field confirmation, focus, clipboard, read-back, and submission guards.
- On devices with multiple integrated panels, prototype live AX hit tests,
  application-reference requests, and attribute traversal using the existing
  keyed-archive parser and field/role mapping.
- Require matching application PIDs at three sampled positions before and after
  traversal. Reject ambiguous applications, failed attribute reads, display
  changes, deadline expiry, and walks exceeding 256 visited elements.

## Validation status

- Earlier local observations: an explicitly selected inner-panel screenshot and
  a live Settings traversal agreed on a 669-by-951-point portrait viewport. The
  traversal returned 27 elements including a SearchField, with stable field
  object identities across reads.
- The earlier media-only adjustment left a search-field tap with no observed
  change, and its batch stopped before text input.
- The final unique-ID-to-HID-surface candidate built but was not accepted on
  hardware. The phone had changed to a landscape lock screen before that final
  attempt, so its precondition check stopped before any tap or text was sent.
- Native regression tests for the archived snapshot: 21 passed.
- JavaScript regression results and exact commands are recorded in the draft PR.
- Text entry, text read-back, clearing the test query, and USB-disconnected Wi-Fi
  operation have not passed hardware acceptance.

## Review limits

These limits describe the snapshot as it was handed over. The sections below
record what later commits changed: touch rotation, phones with one built-in
panel, and the hardware checks. Panel changes during an existing media session,
external displays, split applications, system paste prompts and older developer
images still need review and hardware checks. Three hit-test samples are not an exhaustive visible
application inventory, and live AX decoding remains an experimental protocol path.
The 256-element limit refuses larger trees rather than returning partial results.

The snapshot itself was not rebased and got no further runtime fixes or phone
experiments while the handoff was prepared; the rebases and fixes that followed
are described below. Only synthetic display identifiers and synthetic AX reference fixtures are
included. Raw logs, captures, pairing records, runtime settings, device UDIDs,
account labels, network names, credentials, and local filesystem paths are omitted.

## Rebase onto main and hardware acceptance

The three commits above are unchanged apart from conflict resolution. Three
later commits rebase them onto `8b780c2` and fix what that exposed:

- `display::active()` returns no display when the phone does not advertise
  CoreDevice device information. Callers then keep the single-display defaults:
  display 1, the main touchscreen HID service, the DVT screenshot and the
  cached AX subscription. The section on phones with one built-in panel below
  widens this to every phone without a second panel.
- Touch coordinates are rotated into the active panel's native axes, using the
  panel's `currentOrientation`.
- The AX read before text input gets 10 s instead of 4 s. This now applies only
  to a phone with a second built-in panel.

Hardware: iPhone19,4 running iOS 27.1, connected over RemotePairing on Wi-Fi,
with the inner panel unfolded in landscape (951 by 669 points, `rot90`).

- Taps landed on the intended controls in a third-party app's sidebar and
  switched its views. Before the rotation fix, a tap aimed at the Settings
  search field landed on a different control.
- In Settings, `type_text` into the search field confirmed the text by reading
  the field back, and the clipboard was restored. `tap_text` on the field's
  close button cleared it.
- An accessibility read of the Settings tree took 4.4 to 4.9 s warm and 22.6 s
  on the first read after the tunnel came up.

Still open:

- The first read after the tunnel comes up can take longer than the 10 s
  budget, so the first text input in a session can still fail before sending
  anything. A retry succeeds.
- `launch_app` on the inner panel reported that it could not confirm the
  launch, although the app opened.
- Rotations of 180 and 270 degrees and folding or unfolding during a session
  were tried later. The section on the hardware run after the one-panel change
  records that run.

## Second rebase onto main

`main` moved on to `ce504ac` and the branch was rebased again. The conflicts
were all in `native/bridge/src/ax.rs`:

- `Tree::update_for` keeps main's handling of streamed dumps and this branch's
  decoding of single live responses. An initial or destroyed dump still discards
  the cached graph. It now keeps the display orientation as well as
  `include_offscreen`.
- The reply to the phone's `hostAPIVersion` call still carries 7, as on main.
  At that point the branch still sent it as a DTX object reply (payload type 3)
  and accepted `hostApiVersion` as a second spelling. Both were removed later;
  see the section on phones with one built-in panel.
- Main's `stream_tests` and this branch's live-query tests are both kept.

`main` now compiles `ax.rs` into the launcher too, so the launcher also compiles
`display.rs`. At that point its accessibility reads asked for the active display
in the same way as the bridge while its touch path still used the main
touchscreen. The section on phones with one built-in panel removes that
mismatch. `ax::Direct` does not ask for the active display.

The hardware acceptance above was done before this rebase. The section on the
hardware run after the one-panel change records a later run. The launcher has
only been compiled and unit-tested on a Mac.

## Phones with one built-in panel keep main's path

Review of the rebased branch found that a phone with one built-in panel no
longer behaved as on `main`: every request opened a device-information
connection, a failed display query stopped input, and the touch surface,
rotation, screenshot path and pre-input wait all depended on the answer.

`display::active()` now returns a display only for a phone that reported more
than one built-in panel. For every other phone it returns none, and
`display::route(None)` gives main's values in one place: display 1 for input
media, the main touchscreen (257), no rotation, the DVT screenshot, the cached
AX subscription and a 4 s read before text input.

- A phone that reports one built-in panel is remembered for the life of the
  process and not asked again. The cost is one query per helper process, not
  one per request.
- A query that fails, times out after 2 s or does not parse leaves such a phone
  on main's path. After three such failures in a row the phone is no longer
  asked.
- Only a phone that has already reported several panels gets an error from a
  failed query, because main's path would read and touch the wrong panel there.
- The query inside an AX read is bounded by that read's deadline.
- The single-display fallback to a touchscreen named `CoreDevice
  touchscreen(nil)` is gone. A phone with one panel never reaches the lookup by
  name.
- On USB, the JavaScript side asks the helper once per phone whether it has a
  second panel (`panels`). Only then does the screenshot go through the helper.
  Otherwise it runs the same `poki-native screenshot` command as `main`.

The reply to `hostAPIVersion` is main's again: payload type 0, and only that
spelling is answered. Nothing observed on hardware required the other form.
The third rebase changed this again; see that section.

The launcher keeps main's path on every phone. It compiles the shared files with
`ROUTES_BY_PANEL` off, so its AX reads use the cached subscription and its taps
go to the main touchscreen, as before this branch. It does not follow the
active panel of a two-panel phone. After the third rebase the branch no longer
changes the launcher at all.

The limit of 256 elements in a live read is unchanged. A longer screen on a
second panel still fails with `AX tree exceeded 256 elements`.

## Hardware run after the one-panel change

Run on commit d1c2167, the code commit before this section was added. The
daemon and a release build of the native helper both came from a checkout of
that commit, and `poki_mcp_status` reported it. Two things were not from the
branch:

- The pinned idevice dependency carried a one-line local change to the
  `remotepairing_serial_number` constant, because the phone is paired under
  that value.
- The stdio proxy that forwarded the MCP calls to the daemon came from another
  local checkout.

Same phone as above: iPhone19,4 on iOS 27.1 over RemotePairing on Wi-Fi. The
panel and its rotation were read before each step with `xcrun devicectl device
info displays`. Every step used Settings. "Agree" below means three things
held: the AX tree and the OCR of a screenshot had the same size and put the
same rows at the same heights, and a tap at the centre of an AX frame changed
the screen to the expected view.

| State | Reported size | Result |
| --- | --- | --- |
| Inner panel, `rot90` | 951 by 669 | Agree. A tap at a point taken from the screenshot also hit its button. |
| Inner panel, `rot180` | 669 by 951 | Agree. |
| Inner panel, `rot270` | 951 by 669 | Agree. |
| Outer panel after folding, `rot0` | 466 by 678 | Agree. |

- Rotating twice, folding and unfolding all happened while the same helper
  process stayed connected. The next read and the next tap used the new panel
  and rotation each time.
- `launch_app` as the first call after the tunnel came up returned an unknown
  outcome with `AX live query failed`, and Settings had opened. A second call
  with Settings already in front confirmed the foreground app. A cold launch
  that confirms has not been observed.
- The first `type_text` after the tunnel came up put the text in the Settings
  search field, as a screenshot showed, but returned `text_not_verified` and
  left the text on the clipboard. While the keyboard was on screen, two AX
  reads failed with `AX live query failed`. The following `type_text` with
  `clear` verified through accessibility and restored the clipboard. After the
  search was closed, AX reads worked again.
- A control run of the same steps on an older local build of this work returned
  the same `launch_app` and `type_text` errors, and a system paste prompt was on
  screen there. So the last change did not introduce them. Their cause has not
  been found, and the earlier section's verified `type_text` was not reproduced.

Not run on hardware:

- The inner panel at `rot0`.
- A screen with more than 256 elements. The Settings root has 24.
- The launcher.

## Third rebase onto main

`main` moved on to `291a904`. The temporary rollback in #189 removed code that
the second rebase had merged with, so the branch was rebased onto current
`main` again. Where the two conflicted, `main`'s version was kept:

- `ax.rs` on `main` no longer treats an initial or destroyed dump as a reset of
  the cached graph, and its `stream_tests` are gone. The branch does not bring
  either back. The commit that kept the display orientation through that reset
  had nothing left to change and was dropped, together with its test.
- `acknowledge` is `main`'s text. On `main` it sends no value in any reply,
  `hostAPIVersion` included: #189 removed the answer of 7 that `main` had sent
  since 5efdcd1. The live reads on a phone with a second panel go through the
  same function, so they no longer answer `hostAPIVersion` either. Every
  earlier hardware run had that answer.
- The launcher on `main` no longer compiles `ax.rs` or any other bridge file,
  so the branch no longer changes `native/launcher`. The commit that added
  `display.rs` to the launcher was dropped, and so was `ROUTES_BY_PANEL = false`
  in its `lib.rs`. The constant remains in the bridge's `main.rs`, set to true.

The other changed files rebased without edits: for each of them, the diff
against `main` adds and removes the same lines as the diff against `ce504ac`
did. Every line that `main` added to `ax.rs` since `ce504ac` is in the rebased
file.

The hardware run in the previous section was on the code before this rebase.
The next section records the run on the rebased code.

## Hardware run after the third rebase

Run on 4642454. Its code is the same as at f4d6895, the last commit that changes
code; only this file differed. The daemon and a release build of the native
helper came from a checkout of 4642454, and `poki_mcp_status` reported it. As in
the previous run, two things were not from the branch: the pinned idevice
dependency carried the same one-line local change to
`remotepairing_serial_number`, and the stdio proxy that forwarded the MCP calls
to the daemon came from another local checkout.

Same phone and method as the previous run: the panel and its rotation were read
before each step with `xcrun devicectl device info displays`, every step used
Settings, and "Agree" means the same three things.

| State | Reported size | Result |
| --- | --- | --- |
| Inner panel, `rot90` | 951 by 669 | Agree. |
| Inner panel, `rot270` | 951 by 669 | Agree. |
| Inner panel, `rot180` | 669 by 951 | Agree. A tap at a point taken from the screenshot also hit its row. |
| Inner panel, `rot0` | 669 by 951 | Agree. |
| Outer panel after folding, `rot0` | 466 by 678 | Agree. `go_back` and `tap_text` also changed the screen as expected. |
| Inner panel after unfolding, `rot90` | 951 by 669 | Agree. |

- All six states ran on one helper process. The next read and the next tap
  used the new panel and rotation each time.
- None of these live reads answered `hostAPIVersion`, and all of them returned
  trees.
- The first `type_text` after the tunnel came up verified through
  accessibility and restored the clipboard. An AX read with the keyboard on
  screen returned 55 elements. The following `type_text` with `clear` verified
  too. The previous run returned `text_not_verified` at this step, and what
  made the difference is not known.
- `launch_app` as the first call after the tunnel came up again returned an
  unknown outcome with `AX live query failed`, and Settings had opened. A
  second call with Settings already in front confirmed the foreground app.

Not run on hardware:

- A screen with more than 256 elements. The Settings root has 24.
- The launcher, which this branch no longer changes.

## Fourth rebase onto main

`main` moved on to `84f4a6e`. #239 moved the read-only requests in
`execute_connected` into an `op` future that releases idle input media after
`INPUT_MEDIA_MAX_READ_HOLD`. That conflicted with the branch's screenshot change
in `main.rs`. The branch now makes its changes inside `op`:

- The screenshot routing (the capture service for the active panel of a
  two-panel phone, DVT otherwise) replaces `main`'s DVT screenshot inside `op`.
- `Panels` is answered inside `op`, before `DisplayInfo`, and
  `Request::uses_input_media()` lists it with the other reads. Without that line
  a `panels` request would open input media and then reach the `unreachable!()`
  arm. A new test, `read_only_requests_never_open_input_media`, checks the
  read-only requests against that list; with `Panels` removed from it, the test
  fails on `panels`.
- A test that #239 added names the touch service through
  `crate::Touch::rsd_service_name()`. `Touch` is a struct on this branch, so that
  test uses `crate::Hid`, as the branch's other tests do.

Every other line that `main` added to `main.rs`, `remote.rs` and
`src/device.mjs` since `291a904` is in the rebased files.

The hardware runs above were done before this rebase and were not repeated.
