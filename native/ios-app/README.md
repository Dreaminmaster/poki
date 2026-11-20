# Poki for iPhone

One app for everything a user does on the phone: setup (Developer Mode, on-device pairing, UI
Automation, the loopback, the first-session passcode), starting and stopping a session, the Live
Activity with Approve/Deny for sensitive actions, the MCP address for each client (text, QR, copy),
and a Debug tab (the former Poki Probe). Native SwiftUI with Liquid Glass.

Poki automates the phone in its own process: it opens the XCTest automation session itself
(`Poki/Native/InProcess.m`, answered to PokiCore by `Poki/Runtime/InProcessWDA.swift`), so Poki is
the only app to install. The older Runner path (WebDriverAgent as a second bundle, built by
`.github/workflows/ios-runner.yml`; `docs/single-bundle.md` is the earlier study) stays in the code
and is chosen per launch with `-automationPath runner`, or in General › Testing Options, which also
has the in-process probes and the Background Hold experiment (752 had them in Diagnostics).

A third path, **Native services**, is the default from iOS 27; earlier iOS versions default to the
XCTest session above, and Testing Options (Settings › Advanced) switches between the two. It uses the
paired accessibility, screenshot and HID services shared with the Mac/Linux bridge, without opening an
XCTest session or showing its automation banner. Those services stream the screen and take touches
only from iOS 27 (#1 on iOS 18.6.2 and #18 on iOS 26.6 could not tap). The normal PokiCore control
and approval logic is unchanged. Its state, screenshot and input lanes remain connected independently
while active; the Diagnostics path comparison records tap, type, swipe and parallel tree/screenshot timings against
the in-process path. Changing paths takes effect on the next app launch.

## iPhone Duo Split View

On an unfolded Duo in landscape, ask Poki in chat to work across two apps, such as dragging an
image from Safari into Notes. Poki checks whether the request benefits from Split View, opens the
two apps, and works with both visible while it runs in the background.

For a pair of apps that's already open, you can also use the **Send Task to Poki** action in
Shortcuts with **Use Split View** turned on. Both ways use Poki's usual approvals and leave the two
apps open when the task finishes.

## Layout

| Path | What |
|---|---|
| `Poki/App` | App entry (Chat and Voice pages), status words and issues, all steps, the app model (on/off, runner sleep and wake, events, approvals, pairing, setup steps) |
| `Poki/Setup` | Setup, one guided page with live checks |
| `Poki/Loopback` | Local VPN configuration and status, live developer-service checks, external VPN choices |
| `Poki/Activity` | Live Activity controller (state, steps, thumbnail in the App Group) |
| `Poki/Connect` | Relay identity (Ed25519 key, label, connector secrets in the keychain), MCP address with QR |
| `Poki/Runtime` | PokiCore and PokiLauncher glue, background keep-alive (location, then silent audio) |
| `Poki/Voice` | Talk to Poki: an OpenAI Realtime session over WebRTC, the calls it asks for, test runs |
| `Poki/Debug` | 10.7.0.1 checks, the background hold test, the Live Activity preview |
| `Shared` | Live Activity attributes and views, the Approve/Deny/Stop App Intents (app and widget) |
| `PokiWidgets` | The Live Activity widget |
| `PokiTunnel` | Local-only IPv4 TCP packet tunnel; no server, DNS or internet default route |

PokiCore (Swift, `native/ios/PokiCore`) and PokiLauncher (Rust with a C ABI, `native/launcher`) are described in `docs/ios-core.md`. Poki has no default relay: the person deploys their own (`deploy/cf-relay/DEPLOY.md`) and enters its address in the Connect tab.

## Build

GitHub Actions (`.github/workflows/ios-app.yml`) builds and tests the app on demand or as a reusable
workflow, runs it on the iOS Simulator, and uploads screenshots in light and dark mode
(artifact `simulator-smoke`, folder `shots`). [Release workflows](../../docs/release-channels.md)
publish Pre-alpha automatically. Alpha, Beta, Stable, and installer uploads require the repository
owner's approval. Locally on a Mac with Xcode 26 or later:

```sh
native/ios-app/scripts/make-assets.sh
xcodegen generate --spec native/ios-app/project.yml
open native/ios-app/Poki.xcodeproj
```

Use Xcode 27.1 or later to build and test on iPhone Duo. The iOS 27.1 SDK lets the app extend to the
edges of the unfolded display. In Split View, Poki sizes its chat and conversations drawer to the
space assigned by the system. The iOS deployment target remains unchanged.

A build made with an earlier SDK is letterboxed on both of the Duo's displays. Poki's own screen is
then the letterbox while the picture it takes is the whole panel, so every screen read is refused
(`duo_needs_ios_27_1_sdk_build`, before that `screenshot_does_not_match_active_display`, #419). The
release IPA is therefore built on GitHub's `xcode-27` runner, and `.github/actions/build-ipa` stops
when the iOS SDK is older than 27.1.

`native/ios-app/scripts/app-tests.sh SIMULATOR_UDID` builds `PokiTests` and runs it inside Poki on a booted simulator (the in-process transport's clipboard and session answers).

### Notification permission before UI and Live Activity tests

A new simulator has no notification decision for Poki. Tests that start a session can request
permission asynchronously, leaving the system alert above later tests, even after the test app
exits. While that alert is present, Poki is inactive: a foreground-only Live Activity must not
start, and accessibility reads describe the alert instead of the preview or browser header.
An absent activity or missing localized text in this state is not a completed product check.

Use this preparation whenever the simulator is new or its notification permission was reset:

1. Record the simulator UUID and use that explicit UUID for every command; do not select a physical
   iPhone or rely on a default device. Build and install the test host, then run the session-starting
   tests with the normal runner above.
2. If a notification alert interrupts the run, preserve its screenshot and the failed log. Stop the
   test command and terminate its host with `xcrun simctl terminate SIMULATOR_UDID APP_BUNDLE_ID`.
   Read the actual bundle ID from the built app's `Info.plist`; do not guess it. The notification
   alert can remain above the simulator's Home Screen after termination.
3. On that simulator, answer the notification alert with **Don't Allow**. Denial is sufficient for
   the layout and activity-lifecycle checks; those checks do not require permission to post
   notifications. With Poki MCP, use `handle_alert` with the simulator's explicit `device` UUID and
   the observed button label. Do not answer unrelated alerts or change a real phone's permissions.
4. Confirm the alert is gone, then restart the affected tests in a fresh Poki process on the same
   simulator. Preserve the new result separately from the interrupted run. For screen-reading
   tests, check that the captured application is Poki and the expected preview or browser header
   is visible; for activity tests, Poki must be active before an activity can be created.
5. Delete only the temporary simulator after collecting logs, screenshots and XML. Repeat this
   preparation when creating another simulator; a decision on one simulator does not apply to
   another. `simctl privacy grant all` does not grant notification permission.

This procedure was checked on iOS 27.0: with the alert present the Split View stop test failed
while Poki was inactive, and the language test captured the permission alert; after denying
notifications, the unchanged 20 chat tests and the language-preview test passed. The navigation
font test is separate: English uses Geist scaled by `UIFontMetrics`, while Chinese uses the system
font. Its expected sizes must follow the chosen font rather than assume both scaling curves match.

`-pokiScreen home|setup|connect|debug|activity|steps|status|connector|details|model|voice|session|hands|rules|health|memory|appearance|voiceSettings|conversations|updates|language` opens that screen at launch (the app opens on the chat; home is the chat with the conversations drawer open, details Settings, hands and setup its Connection page, rules and health the Approvals and Advanced pages, connect the Agents page, memory, appearance, voiceSettings (Dictation & Mute), conversations (Archived Conversations) updates (Signing & Updates) and language (Language) their pages, debug Diagnostics under Advanced, steps the Activity Log, session an outside agent's session); `-pokiChat empty|working|approval|handoff|approved|failed` shows the sample chat scenes (the greeting, a task under way, a step waiting for approval, a hand-over, a finished task, a failed one) and `-pokiVoice ready|listening|working` the voice faces; `-pokiSetupStep N` opens setup at step N, `-pokiSettingsEnd YES` opens Settings scrolled to its end, and `-pokiSample B|C` fills the status, history and Live Activity with sample steps and an approval, and `-pokiSample PIN` shows a sample pairing code, for screenshots only; on a simulator `-pokiLoopback cellular` forces the cellular-only loopback hint, `-pokiLoopback working` a loopback that answers, and `-pokiSigningDays 1` a signing that ends in a day, and `-pokiAppleID name@example.com` signs in that Apple Account on Signing & Updates without contacting Apple (`-pokiAppleName`, `-pokiAppleTeams 0|1|2` and `-pokiAppleState code|reauth|expired|error` shape it).

Poki ships English, Simplified Chinese and Traditional Chinese. Settings › Language lets the owner follow the effective iOS app language or choose a Poki UI language. See [iOS UI language](../../docs/ios-localization.md) for scope and verification. The app's screens use the String Catalog `Shared/Localizable.xcstrings`, the Live Activity its own table `Shared/LiveActivity.xcstrings` (see `Shared/ActivityWords.swift`), and the permission prompts `Poki/InfoPlist.xcstrings`. Poki's own status words stay in English inside the app (the code compares them and the agent reads them) and are looked up where they reach the screen; the launcher's fix sentences have entries too. Steps an agent reports, logs and diagnostics output stay as they come. Add `-AppleLanguages '(zh-Hans)'` to a launch to see Chinese without changing the simulator's language.

## How it runs

- Poki stays on once turned on, and turns on again at launch. With the default in-process path,
  opening Poki, focusing the message field, starting dictation, choosing a shortcut, sending a
  message, and an agent connecting only prepare dependencies. They do not open an automation
  session. Pure chat and sandbox-browser tasks leave Automation Mode off; the read-only `status`
  tool also leaves it off. The first phone step opens the session and waits for it before reading
  or acting. Poki shows Preparing during this wait, then continues the same step without a model
  retry. Session timing events record submission, the open request, readiness and successful reads.
- Once opened, the session stays open while a task works, including pauses between its phone steps.
  Poki stands by when the task ends, when Poki comes to the front, or when a step hands the screen
  to the owner. An outside agent's task ends when its MCP session ends and no other agent is at work.
  The idle timeout, 60 s by default, also puts Poki on standby when an outside agent goes quiet.
  `AppModel.idleSessionPolicy` selects the standby behavior by iOS version. On iOS 18 to 26, Poki
  turns Automation Mode off and keeps the session for the next phone step. If the pause fails,
  Poki closes the session instead. On iOS 27 and later, standby closes the session as before.
  Stop, Turn Off, and an update close the session on every version, even if a pause is still in
  progress. An update waits for that close before it continues. A later phone step opens a new
  session after a close, or resumes a kept session and checks that it can still read. If a resume
  fails, Poki closes the session and tries a new one, except when opening was refused or iOS's
  passcode prompt timed out. Nothing is tapped or typed while Poki itself is in front.
  There is no Hide Banner When Idle setting.
- A new session is ready only once it has answered with an element tree. One that cannot read is
  closed, the step fails with the reason (`session_unreadable`), nothing is sent to it, and the next
  phone step opens a new session. An app that is slow to answer is not a session failure.
  Same-process close/reopen and the actual system banner must be checked on the physical release
  candidate; simulator tests do not establish either device behavior.
- If the first phone step needs the boot's first automation, Poki asks the owner before opening
  iOS's passcode screen. Only an open that iOS has held in its own allow-automation call for 3 s is treated as waiting for the passcode (a session that is slow to open or to read is not):
  the Live Activity shows Passcode for automation, Poki asks the owner, and the agent reads that only
  the owner can enter it. If opening fails, the call reports the reason and a later phone request
  may retry. A cancelled or missed passcode prompt is not opened again until the owner turns Poki
  on again. Opens go through one gate: one at a time, with no first automation from the background.
- Nothing listens on a port: PokiCore's requests are answered inside Poki.
- The built-in local connection dials itself again when it fails or drops while Poki is on: 1, 2, 4, 8,
  16, 30, 30, 30 s, then it stops until the owner taps Enable Local Connection in Setup. Opening Poki
  dials nothing. It does not dial when the owner ended it (Turn off, Disconnect, Settings > VPN), when
  another VPN took the packet tunnel, or when another VPN is detected at the time of a try: Poki says so and
  stops. Detection is best effort: a VPN that sets no proxy, such as Tailscale, may not be detected. The automation then comes back by the loopback's own recovery. An external
  connection is never touched.
- Runner path only (`-automationPath runner`): the runner, and with it the banner, starts only when
  an agent asks, and stops after the idle time (default 60 s), from Stop on the Live Activity or in
  Poki, or when Poki is closed. Only Poki starts the runner; opened by hand, Poki Runner starts no
  test (PokiRunnerHost, `native/ios-runner/host`) and sends the person to Poki. While it runs, its
  HTTP and MJPEG listeners bind to `127.0.0.1`, so only software on the phone can reach it; PokiCore
  remains the approval boundary (`native/ios-runner/README.md`).
- The Live Activity starts from the foreground, because iOS does not allow it from the background:
  when Poki turns on, when pairing starts, and when a setup step opens Settings.

## Voice

Voice (the waveform button beside the gear on Home, a sheet) talks to OpenAI's Realtime API (`gpt-realtime-2.1`) over WebRTC: the microphone is the
audio track, Poki's voice plays on the speaker, and events travel on the `oai-events` data channel.
The phone never holds an OpenAI key. The voice bridge on the person's Mac (`bin/voice-bridge.mjs`)
keeps the key and gives the phone a client secret that expires after 60 seconds:

1. Create an API key at platform.openai.com (API keys). Realtime audio is billed to that account per
   token; each test turn reports the tokens it used.
2. Keep it in the keychain, and read it from there, so it never lands in your shell history:

   ```sh
   security add-generic-password -a "$USER" -s openai-api-key -w    # asks for the key
   export OPENAI_API_KEY="$(security find-generic-password -s openai-api-key -w)"
   ```

3. Start Poki MCP first (`npm start`, see [docs/install.md](../../docs/install.md)); the bridge stops at
   once with "Local Poki MCP is not running" without it. Then, with the same state directory:

   ```sh
   POKI_MCP_STATE_DIR=... node bin/voice-bridge.mjs --device <iPhone id>
   ```

The bridge listens on every network interface (`--host 0.0.0.0`), because the phone reaches it over
the local network, in plain HTTP. Anyone who learns its address, which carries the secret, can open
sessions on your OpenAI key and move the phone through your Mac. Run it only on a network you trust,
and pass `--host <this Mac's LAN address>` to keep it off other interfaces (for example a VPN).

Enter `http://<Mac>:47830/voice/<secret>` in Voice (the secret is in `voice-bridge.json` in the
state directory). `get_ios_version` is answered on the phone;
the bridge runs the tools that move the phone (`open_settings`, `read_screen`, `open_app`, `tap_text`,
`go_home`) through the Mac's Poki MCP.

- Each function call runs once, keyed by its `call_id`, in the app and again in the bridge.
- `tap_text` is held by Poki's approvals, like an agent's `do`: the bridge first says what it would tap
  and in which app, without tapping; the phone checks that with PokiCore's rules (payments, deleting,
  sending messages, calls) and, when they ask for it, waits up to two minutes for Allow (in the Dynamic Island, on the Live
  Activity or from the notification). Only then does the bridge tap that element, matched exactly, in that app.
- A dropped connection sends nothing again. A call outlives the session that asked for it; the next
  session is told how it ended instead of asking for it again.
- Stop talking (or speaking over Poki) cancels the reply, never the step running on the phone.
- Once an answer has played and no step it asked for is running, the conversation waits 8 s for the
  person to go on in the same session. After 8 s of silence it ends and lets go of the microphone, so
  iOS's orange dot goes off; a conversation opened with nothing said ends the same way. A
  conversation opened within 5 minutes of the last end is told up to 6 lines said in that last
  conversation with something said in it (a conversation nobody spoke in changes nothing), from
  memory (the chat keeps its own copy as before). In the background Poki stops listening at once, also
  while connecting, unless a step is running or its answer is still to be said (the step brings another
  app to the front); that conversation ends as soon as that is said.
  A conversation never waits for the server for ever: when it owes something (the end of the person's
  speech, an answer, the end of the audio) and the server says nothing for 60 s, or 30 s after Poki went
  to the background, it ends. A step that is running is not counted; its result starts a new wait.
- A `poki://voice` link, from a web page or another app, only opens Voice: a link never
  changes the bridge and never turns on the microphone. The person enters the address and taps Talk
  to Poki.
- Development builds only: the launch argument `-pokiVoiceLink "poki://voice?bridge=<address>&test=1-20"`
  runs recorded utterances from a bridge started with `--test-dir`, silently: the speech goes over
  the data channel instead of the microphone, and Poki's voice is muted. Release builds have no test
  runs.

## Signing and entitlements

| Entitlement | Needed for | Notes |
|---|---|---|
| App Groups `group.nz.zheha.poki` | Live Activity thumbnail, approvals between widget and app | Signing tools rewrite group ids per Apple ID; that works as long as both targets get the same rewritten group. |
| Network Extensions `packet-tunnel-provider` | Built-in local connection | Required in both Poki and PokiTunnel, with a matching provisioning profile for each bundle. A wildcard profile is insufficient. |

Which build to sign depends on the Apple account:

| Apple account | Build | Local connection | Signing |
|---|---|---|---|
| Paid Apple Developer Program team | `Poki-unsigned.ipa` (`project.yml`) | Built-in, or an external VPN app | App IDs for Poki, `.widgets` and `.tunnel`; the App Group on Poki and `.widgets`; Network Extensions (packet tunnel) on Poki and `.tunnel`; a development or ad-hoc profile for each of the three. |
| Free Apple ID (Personal Team) | `Poki-external-unsigned.ipa` (`project-external.yml`) | An external VPN app or LocalDevVPN only | The App Group on Poki and `.widgets` (signing tools rewrite it per Apple ID). Apps signed this way expire after 7 days, and only 3 can be installed at a time; Poki uses one (two with Poki Runner on the Runner path). |

On the Runner path, sign Poki Runner with the same account as Poki in both cases.

The default `project.yml` builds Poki with its local VPN. Use signing that supports Network
Extensions (including properly provisioned paid-team development/ad-hoc distribution). Free Personal
Team signing cannot provision this capability. Re-signing must preserve the entitlement in both the
app and its extension. CI includes the generated entitlements in `Poki-signing.zip`.

For a team that does not own the default identifiers, set `POKI_BUNDLE_ID`, `POKI_APP_GROUP` and
optionally `POKI_DISPLAY_NAME` in Xcode or the `xcodebuild` invocation. Register the App Group and
associate it with both the app and widget identifiers in the developer portal before provisioning.
The app and widget read that same group from their built Info.plist; approval notifications are
namespaced to it. Do not reuse another app's group just to make signing pass.

`project-external.yml` builds the same app without the tunnel or its Network Extension entitlement:

```sh
xcodegen generate --spec native/ios-app/project-external.yml
open native/ios-app/PokiExternal.xcodeproj
```

CI produces `Poki-unsigned.ipa` and `Poki-external-unsigned.ipa`. Choose one; on the Runner path,
also install Poki Runner with the same signing. The external build retains the App Group requirement for approvals and
thumbnails; it does not solve other free-account signing restrictions.

## Loopback choices

Setup initially offers an installed supported VPN before the built-in option. The user selects the
connection explicitly; an existing service response alone does not finish the setup step.

- **Karing**: keep its VPN connected, set TUN > Loopback address to `10.7.0.1`, and use **External
  app** in Poki. Poki's VPN stays off, so Karing continues to own the single packet tunnel. See the
  [maintainer's iOS support record](https://github.com/KaringX/karing/issues/899); verify the installed
  version and the developer-service check before continuing.
- **Built-in (default)**: Setup > Connect to this iPhone > Enable local connection. Approve iOS's
  VPN configuration prompt. Poki reflects only IPv4 TCP to `10.7.0.1/32`; normal internet routes and
  DNS are unchanged. The connection may displace another packet-tunnel VPN. Poki does not silently
  change an external VPN configuration or start its local VPN merely because the app opened. While
  Poki is on, its own tunnel is dialled again after a failure (see above), and stops when it detects another VPN (best effort, as above).
- **Proxy app**: Surge (module, `surge:///install-module?url=`), Loon (plugin,
  `loon://import?plugin=`), Shadowrocket (its "Include route 10.7.0.1/32" toggle), sing-box (one
  line in the tun inbound), and, as users report rather than as their makers document, Stash and
  Clash Mi (`loopback-address` in the tun section) and Quantumult X (`reflected_routes` in
  `[general]`); those entries say so on the page. Files and sources in `deploy/proxy-modules/`,
  served from the fork's raw GitHub URL for now (`ProxyApps.modulesBase`). Each row's tag is live:
  the chosen app reads Working while 10.7.0.1 answers and Not Answering while it does not.
- **External build without a proxy app**: LocalDevVPN (App Store). This is an additional app and
  must be tested with the installed iOS version. It may displace another packet-tunnel VPN.

The setup step completes only when a TCP connection to the phone's RemotePairing or lockdown
service succeeds. Selecting an app, saving a profile or a VPN's Connected label alone never completes
it. Built-in VPN transport cannot be validated in the Simulator. See [the design and acceptance
checks](../../docs/ios-loopback.md).

## iPad, iPhone Duo: Poki beside the app it drives

Poki builds for iPhone and iPad (every orientation on iPad; the iPhone Duo's inner display is
regular width, laid out like an iPad). The point of the larger screens is Poki, or any agent chat,
beside the app being driven: on the Duo's inner display in landscape iOS 27.1 puts two apps side by
side (a fixed 50/50 Split View, with app pairs); on iPadOS 26 apps are resizable windows, with
Stage Manager. The in-process path keys on the driven app's frame, not on either layout: with
several apps on screen Poki's own process is never the front app, and when the front app's frame
is smaller than the screen (its half of the Duo, its window on the iPad) that frame is the viewport
(`PKInProcess.viewport`): the element tree's frames and the screenshot are relative to it,
`/wda/screen` reports its size, and touches are moved back onto the screen. An app that fills the
screen has no viewport. Not yet checked in the gym on an iPad simulator with two windows.

### Two apps beside each other with Poki in the background

On a Duo running the in-process automation path, open two different apps using iOS Split View, or
restore an existing app pair. Start Poki's automation before moving it to the background. An agent
can read one of the visible apps with `look {"pane":"left"}` or `look {"pane":"right"}`. Actions use
the most recent pane read, including its screenshot, element numbers and keyboard focus. Read the
other pane before targeting it. `look {"pane":"auto"}` returns to normal control, and finishing a
task leaves both windows in place. A layout change needs a fresh pane read.

Some Duo windows report local frames on both sides. In that case Poki checks visible labels against
the full display on the device before using either crop. If the keyboard obscures the text, Poki
can use the still-visible parts of the previously verified windows to recheck their positions.
It refuses input when it cannot establish which app is on each side. Two windows from the same
app are currently unsupported.

## Pairing by iOS version, and the pairing file's life

Pairing on the phone itself (Settings > Privacy & Security > Developer Mode > Pair with Poki) exists
from iOS 27 (`SetupStep.onDevicePairing`). On earlier versions the pairing page shows the other way
only: pair from a computer with Poki Setup (or pymobiledevice3, jitterbugpair, StikPair), then send
the file to the phone. Poki takes a pairing file three ways besides Import Pairing File:

- A file opened with Poki from AirDrop or Files (`CFBundleDocumentTypes`: property lists and
  `.mobiledevicepairing`).
- `poki://pairing?url=http://<computer on the LAN>:<port>/<file>&sha256=<hex>`: Poki fetches the
  file over the local network and checks the digest; Poki Setup shows this link as a code for the
  Camera. `poki://pairing?data=<base64url>` carries a small file in the link itself.
- `poki://setup?relay=<origin>` sets the relay address Poki Setup configured.

The pairing file and the setup state are mirrored into the Keychain (`SetupVault`,
`ThisDeviceOnly`). An update keeps the container anyway; a delete-and-reinstall, or a sideloading
tool that could not keep the container, gets both back on the first launch as long as the same team
signs the app, so the owner is not sent through setup again.

## Device test checklist

Install and launch
- [ ] Install `Poki-unsigned.ipa`. Runner path only: also install the runner IPA with the same signing, and open Poki Runner by hand: no passcode prompt, no automation banner; it opens Poki (or shows Open Poki).
- [ ] Launch Poki: the Setup tab shows a badge with the steps left, and no Install Poki Runner step.

Setup
- [ ] Each step opens in turn; Open Settings starts a Live Activity with the step number and what to tap.
- [ ] Loopback: the status changes within 3 s when the proxy app's module is turned on or off.
- [ ] Pairing: the code shows in the Live Activity and in Poki; the step ticks.
- [ ] Let Poki stay on: Allow location shows iOS's prompt; Live Activities show as on.

Turned on
- [ ] Turn on or bring Poki to the foreground: no automation banner. Focus the field, start dictation, choose a shortcut, and complete a pure-chat or sandbox-browser task: still no banner.
- [ ] Connect an agent and call `status`: no banner or automation passcode prompt. Its first phone step shows Preparing, opens the session, and reads the screen successfully; steps show on the Lock Screen and in the chat.
- [ ] After a phone task ends, and separately after an outside agent reaches the idle timeout, the banner disappears. On iOS 18 to 26, the next phone task in the same app launch resumes the kept session and reads successfully without another passcode prompt. On iOS 27 and later, the next task opens a new session and reads successfully. Check both behaviors on physical phones; simulator tests do not establish them. If a pause fails, the log reports a close instead, and the banner must still disappear.
- [ ] No banner flicker during a run; a slow swipe or drag does not reopen the session.
- [ ] Runner path only: no banner until an agent's first call starts the runner; opening Poki Runner while in use shows "Poki is using this iPhone"; Stop on the Live Activity or in Poki takes the banner away within seconds and the next call starts it again; after the idle time with no calls, the banner goes away by itself.
- [ ] Ten minutes in the background: the location pill shows and agents still reach the phone.
- [ ] Close Poki from the app switcher: the banner goes away within seconds.
- [ ] A sensitive action shows Approve/Deny in the Live Activity; Approve asks for Face ID.

Connect
- [ ] Add a connector: the sheet shows the URL, a QR that scans to the same URL, and Copy works.
- [ ] Revoke by swiping: the connector disappears and the relay answers 404 for it.
