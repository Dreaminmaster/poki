# Poki MCP troubleshooting and issue drafting

Use this reference when a Poki MCP call fails, when the Poki iPhone app or Poki Setup reports an error, or when you need to draft a GitHub issue for the user.

## 1. Read state first

Run read-only checks for the active MCP server before retrying failed actions or modifying local state.

### How to call tools outside default `tools/list`

On the Mac `poki-mcp` server, `get_device_info`, `observe_device`, `list_crashes`, `get_crash`, `reconnect_device`, and `disconnect_device` are omitted from default `tools/list`:

- If your MCP client exposes only listed tools, ask the user to set `POKI_MCP_TOOLS=all` in the client's MCP server environment and reconnect.
- From a terminal on the Mac, `cd` to the Poki checkout directory first and run `node bin/call.mjs <tool_name> '<json_args>'` (pass the same `POKI_MCP_STATE_DIR` when non-default). Each `bin/call.mjs` run opens a separate session, so include `"device"` in `<json_args>` when multiple devices are connected.
- Clients that permit direct `tools/call` requests for unlisted tools can call them without `POKI_MCP_TOOLS=all`.

### Mac `poki-mcp` server

| Tool | In default `tools/list` | Arguments | Key return fields |
| --- | --- | --- | --- |
| `poki_mcp_status` | Yes | `{}` | `implementation` (version string), `commit`, `native_build`, `total_tools`, `devices` count, `selected` device ID, `approval_mode`, and optional `update` (`version`, `summary`, `url`, `command`). Runs even when the daemon reports outdated code. |
| `list_devices` | Yes | `{ include_all_simulators?: boolean }` | `devices[]` with `id`, `connection` (`"USB"`, `"RemotePairing"`, or `"Simulator"`), `kind`, `name`, `model`, `osVersion`, `readiness`, `occupied`, or `blocked` and `action` when a phone is locked, untrusted, or unreachable. Includes `notice` when `usbmuxd` sees no USB iPhone. |
| `get_device_info` | No | `{ device?: string, include_settings?: boolean }` | `id`, `name`, `kind`, `connection`, `model` (`ProductType` on USB, such as `iPhone17,1`), `osVersion` (`ProductVersion`), `engine`, `mirror_status`, `screen` (`width`, `height`, `scale`, `units`), and optional `settings` (`appearance`, `text_size`, accessibility flags, unavailable over `RemotePairing`). |
| `observe_device` | No | `{ device?: string, source?: "auto" \| "accessibility" \| "ax" \| "ocr", max_elements?: number, include_offscreen?: boolean, include_image?: boolean }` | Current PNG screenshot (unless `include_image: false`), `foreground` (`pid`, `bundle_id`, `name`), `elements[]` with `ref` and `frame`, `source`, `fallback_reason`, and `prompt` (`warning.kind: "passcode"` or alert buttons when a system prompt blocks the screen). |
| `list_crashes` | No | `{ device?: string, process?: string, kind?: "crash" \| "spin" \| "log" \| "diagnostic" \| "all", limit?: number }` | `source` (`"device systemCrashLogs"` on USB or `"host DiagnosticReports"` on Simulator) and `reports[]` (`path`, `name`, `modified`, `kind`). Unavailable over `RemotePairing`. |
| `get_crash` | No | `{ device?: string, path?: string, process?: string, full?: boolean }` | Copies the `.ips` or `.crash` file into `POKI_MCP_STATE_DIR/crashes/` and returns `process`, `bundle_id`, `exception`, `termination`, `faulting_thread`, and top `frames[]` (or raw text with `full: true`). Unavailable over `RemotePairing`. |
| `reconnect_device` | No | `{ device?: string }` | Attempts a fresh `RemotePairing` tunnel and re-resolves `.local` Bonjour names while keeping an existing working tunnel if replacement fails. Never replays prior input. |
| `disconnect_device` | No | `{ device?: string }` | Closes the detached `poki-native --remote-server` helper and its `RemotePairing` connection. |

### Poki iPhone app MCP connector

When the MCP client connects to the standalone Poki iPhone app through its relay connector (`poki` server exposing `status`, `look`, `do`, `routines`):

| Tool | Arguments | Key return fields |
| --- | --- | --- |
| `status` | `{}` | Plain-text lines that bypass the action queue: `runner: running`, `runner: starting (<detail>)`, or `runner: failed: <detail>. Fix on the phone: <fix>`, followed by `relay: ready \| connecting \| offline (<why>)`, optional `approval waiting on the phone`, optional `handoff`, and optional `running` call summary. |
| `look` | `{ full?: boolean }` | Foreground app, numbered elements, Vision OCR fallback text when accessibility is empty or slow, and a JPEG screenshot. Reports `screen: locked` when the phone is locked, or `poki: Poki is in front` when Poki itself is open on screen. |

Done when you have the server or app version, iPhone model and iOS version, connection or runner state, and exact error text.

## 2. Classify and fix what you can

| Failure class | Primary signals | Section |
| --- | --- | --- |
| Disk image blocked by network, missing, or outdated | `display_service_missing`, `"Disk Image Outdated"`, `"Update the Disk Image"`, `"Fetching Disk Image"`, `"No Internet"`, `STATUS=94`, or `developer_framework_unavailable` | 2.1 |
| Runner stopped or Automation turns back off | `"Disconnected"`, `"Runner stopped"`, `"Runner Stopped"`, `"The runner stopped"`, `"Poki is off"`, `"Automation did not start"`, `runner: failed`, or old-code daemon errors | 2.2 |
| Disconnected, loopback off, or pairing failed | `list_devices` `blocked` or `notice`, `Remote pairing is unreachable`, Relay HTTP `503`, `"Loopback Off"`, `"Tunnel On, No Answer"`, `"Pairing Refused"`, or `"Can’t Reach iPhone"` | 2.3 |
| Locked screen, Poki in front, or blocked input | `prompt.warning.kind: "passcode"`, `screen: locked`, `poki: Poki is in front`, `"paste_permission"`, `approval_required`, `handoff`, or `fill` field-confirmation refusal | 2.4 |
| Signing expiry, stalled update, or installer error | `"Poki’s signing ends soon"`, `"Finishing the update: Poki will close to finish it"`, `bridge_start_failed` (`-86`), or `apple_account_limit` | 2.5 |

### 2.1 Disk image blocked by network, missing, or outdated

**Observed error strings**

- **Mac `poki-mcp` (`src/device.mjs`, `native/bridge/src/stream.rs`).** Input tools return `outcome: "not_sent"`, `reason: "display_service_missing"`, and `error: "Cannot establish input media session: no display service: ServiceNotFound"`. Screenshots, `list_elements`, and `observe_device` work without `com.apple.coredevice.displayservice`, so working screen reads do not prove touch or text input is ready.
- **Mac `prepare-device.mjs` and `src/ddi-failure.mjs`.** Output contains `STATUS=94`, `"TSS server responded with non-success status"`, `"This device isn't eligible for the requested build"`, or `/System/Developer [17: File exists]`.
- **Poki iPhone app, launcher, and Live Activity (`AppModel.swift`, `ddi.rs`, `device.rs`, `LiveActivity.xcstrings`, `Localizable.xcstrings`).** Status or task output shows `"Disk Image Outdated"` (`ddi_refused`), `"Update the Disk Image"`, `"This iOS version needs a newer developer disk image. Open Poki's setup to download the latest image, or update Poki."`, `"Fetching Disk Image"` (`ddi_bad`), `"No Internet"` (`ddi_timeout` or `network`), `"the developer disk image was installed but its services did not appear"`, or `developer_framework_unavailable` (`dlopen` could not load `XCTest.framework`, `XCTestSupport.framework`, or `XCTAutomationSupport.framework`). Users may also transcribe lowercase `Disk image outdated`.

**Why Setup Wizard shows `"Ready"` and why proxy or VPN filters trigger `"Disk Image Outdated"`**

1. Poki's 5 Setup Wizard steps (`Developer Mode`, `Local Connection`, `Pair This iPhone`, `UI Automation`, `Stay On in Background`) check saved flags, TCP reachability on `10.7.0.1:62078`, pairing file presence, and downloaded disk image files (`"Ready"`). Personalizing the image with Apple's signing server (`gs.apple.com`), mounting `/System/Developer`, and `dlopen` of developer frameworks happen only when Automation starts.
2. Both `native/launcher/src/ddi.rs` and `src/ddi-failure.mjs` classify any error containing `"TSS server responded"` as `ddi_refused` (`"Disk Image Outdated"`). When a proxy, VPN, rule in Surge, Loon, Shadowrocket, or sing-box, HTTPS inspection filter, or workplace or school gateway intercepts `gs.apple.com` and returns an error page or redirect, Poki reports `"Disk Image Outdated"` even when the downloaded disk image matches iOS.

**Step 1: Rule out network, proxy, or VPN interception first**

Treat a personalization failure as a true Apple version refusal **only** when the output includes `STATUS=94` together with an iOS-versus-image mismatch (such as `"This device isn't eligible for the requested build"` or an Xcode version older than the phone's iOS).

In every other `"Disk Image Outdated"` (`ddi_refused`), `"TSS server responded with non-success status"`, or `"No Internet"` (`network`, `ddi_timeout`) case, check whether traffic to `gs.apple.com` was blocked before replacing disk images or drafting an issue:

- Ask the user to retry one task on an unfiltered network, such as cellular data or a personal hotspot instead of workplace, school, or filtered Wi-Fi. First mount after each phone restart needs internet access over Wi-Fi or cellular so Poki can reach `gs.apple.com`, after which Poki retries on its own.
- Ask the user to turn off any VPN or proxy other than LocalDevVPN. If they use Surge, Loon, Shadowrocket, or sing-box for the `10.7.0.1` loopback (see section 2.3), ask them to route `gs.apple.com` as `DIRECT` with HTTPS decryption disabled, or switch loopback to LocalDevVPN, and retry once.

**Step 2: Recover after ruling out network interception**

- **Automatic redownload (`ddi_bad`).** When `status` or the app shows `"Fetching Disk Image"`, Poki redownloads the image on its own. Wait a few seconds and call `status` again.
- **Mount from the computer (with user confirmation).** When Mac `poki-mcp` reports `display_service_missing` or the phone needs computer-assisted mounting over USB, ask the user for confirmation first (or give them the command to run themselves). On a Mac checkout with the unlocked, trusted iPhone connected over USB, `cd` to the Poki checkout directory and run `node bin/prepare-device.mjs <UDID>`. When Poki Setup is installed (`"/Applications/Poki Setup.app/Contents/MacOS/poki-setup"` on macOS, `~/Applications/Poki Setup.app/Contents/MacOS/poki-setup`, or `"%LOCALAPPDATA%\Poki Setup\poki-setup.exe"` on Windows), run `poki-setup ddi --udid <UDID>` without Xcode.
- **Confirmed `STATUS=94` version mismatch.** The Mac's Xcode is older than the phone's iOS (for example iOS 27 requires Xcode 27). Ask the user to update Xcode, open it once until component installation finishes, and confirm before rerunning `node bin/prepare-device.mjs <UDID>` from the Poki checkout.
- **Mount conflict (`/System/Developer [17: File exists]`).** Ask the user to quit Xcode, restart the iPhone, reconnect it over USB unlocked, and confirm before rerunning `node bin/prepare-device.mjs <UDID>` with Xcode closed.

**When you cannot fix it**

Draft a GitHub issue (`ios_app_bug.yml` or `bug_report.yml`) only after retrying on an unfiltered network with proxy and VPN interception ruled out, confirming Poki is on the newest build for its channel, and verifying that `"Disk Image Outdated"` or `developer_framework_unavailable` still reproduces.

### 2.2 Runner stopped or Automation turns back off

**Observed error strings**

- **Poki iPhone app, `AppModel.swift`, `LiveActivity.xcstrings`, `Localizable.xcstrings`, and `Status.xcstrings`.** The screen shows `"Disconnected"`, `"Runner stopped"`, `"Runner Stopped"`, `"The runner stopped"`, `"Poki is off"`, `"Poki is off. Agents can’t reach this iPhone."`, `"Agents can’t reach this iPhone"`, `"Automation did not start"`, `"Needs attention"`, `"Poki Runner Missing"` (`runner`), or `"Poki Runner Didn’t Start"` (`runner_blocked`).
- **Poki iPhone app MCP `status` or `do`.** Output shows `runner: starting (<detail>)`, `runner: failed: <detail>. Fix on the phone: <fix>`, `open_poki_first`, `passcodeMissed`, or `the runner is not running (connection refused at http://127.0.0.1:8100)`.
- **Mac `poki-mcp` (`src/build-info.mjs`, `src/stdio.mjs`).** Tool calls return `"The service is running old code. Stop the running service and restart it with npm start."` or an error starting with `"The running Poki MCP rejected the token in "` and ending with `"Restart it with npm start."`.

**Why the Automation switch snaps back to off with no error text**

Before the first automation session after an iPhone restart, and again 8 hours after the previous passcode check, iOS requires the owner to enter the iPhone passcode on screen. Poki logs `no automation since this iPhone restarted: telling the owner iOS will ask for the passcode` and presents the `"Enter Your Passcode Next"` alert before starting the session. On builds where full-screen **Settings** covers that alert on the main view, tapping **Settings > Connection > Automation** flips the switch straight back to off with no red text under the switch.

**What you fix yourself (and when to ask before restarting)**

- **Idle wake-up.** If `status` reports `starting again after being idle`, `opening the in-process session`, or `it is being restarted`, wait 3 to 10 seconds and call `status` or `look` again. Do not report an idle wake-up as a failure.
- **Outdated Mac daemon or token mismatch.** Ask the user to stop their running `poki-mcp` service and restart it from the Poki checkout (`cd` to the Poki checkout directory, then run `npm start` with the same `POKI_MCP_STATE_DIR`), or get their confirmation before restarting it for them, then verify with `poki_mcp_status`.
- **Crash check.** On USB or Simulator, call `list_crashes` and `get_crash` to inspect whether `Poki`, `WebDriverAgentRunner`, or the target app quit unexpectedly.

**When user action is required**

- **Passcode gate (`waiting for the owner to enter the iPhone passcode`, `passcodeMissed`, `open_poki_first`, or Automation snapping off).** Ask the user to close **Settings** and check Poki's main chat screen for the `"Enter Your Passcode Next"` (**Continue**) prompt, or toggle **Automation** off and on and enter the iPhone passcode themselves when iOS asks. Never enter the passcode for them.
- **System switches.** Ask the user to confirm on the iPhone that **Settings > Privacy & Security > Developer Mode** is on and **Settings > Developer > Enable UI Automation** is on. Poki's Setup steps 1 and 4 record earlier checks and do not detect if a system switch was turned off later.

**When you cannot fix it**

Draft an issue (`ios_app_bug.yml`) when **Automation** still snaps back to off with no `"Enter Your Passcode Next"` or iOS passcode prompt even from the main chat screen after force-quitting and reopening Poki, or when `runner: failed` persists after Developer Mode, UI Automation, loopback, and passcode checks pass.

### 2.3 Disconnected, loopback off, or pairing failed

**Observed error strings**

- **Mac `poki-mcp` (`src/device.mjs`, `src/config.mjs`, `native/bridge/src/remote.rs`).** Output returns `"No device is connected. Connect and trust an iPhone, or start a simulator."`, `"Device is not connected or the selected device disconnected. Use list_devices and select_device."`, `list_devices` `notice` `"usbmuxd answered, but no iPhone is attached over USB. Check whether the iPhone appears in the Finder sidebar. If Finder does not show it either, macOS has not attached it: connect it directly with a data cable, unlock it, and accept Trust This Computer. Poki cannot use an iPhone that devicectl reaches only over the network."`, errors starting with `"Remote pairing is unreachable ("` or `"The remote pairing control connection closed: "`, or `"The iPhone refused a new tunnel. Reconnect it to Wi-Fi, then reconnect the device."`.
- **Relay HTTP `503` (`deploy/cf-relay/worker.js`, JSON-RPC `-32001`).** Response returns `"The phone is offline: open Poki on the phone, or check its network."`. Turning Poki off on the iPhone closes its relay WebSocket and produces the same `503` response.
- **Poki iPhone app (`AppModel.swift`, `SetupView.swift`, `LoopbackTunnel.swift`, `LiveActivity.xcstrings`, `Localizable.xcstrings`).** Status shows `"Loopback Off"` (`loopback`), `"Tunnel On, No Answer"`, `"10.7.0.1 takes the connection, but the phone's remote pairing service does not answer through it, so this page can show Working while Poki cannot connect. Reconnect your proxy app or LocalDevVPN, then pair again in Setup › Pairing."` (`servicesSilent`), `"Another VPN appears to be on, so Poki did not turn its local connection back on. Turn that VPN off and tap Enable Local Connection, or choose an external connection in Setup."`, `"Finding Pairing Port"` (`pairing_port`), `"Pairing Refused"` (`pairing`), `"Loopback or Pairing"` (`handshake`), or `"Can’t Reach iPhone"` (`unreachable`).

**What you fix yourself (and when to ask before changing service state)**

- **Reconnect wireless tunnel.** On Mac `poki-mcp` with `RemotePairing`, call `reconnect_device`. It resolves `.local` Bonjour names again while keeping an existing working tunnel if replacement fails. If a detached `poki-native --remote-server` helper is wedged across daemon restarts (`Remote operation timed out`), call `disconnect_device` before reconnecting.
- **Return a `remote-devices.json` phone to USB (with user confirmation).** When an iPhone is listed in `POKI_MCP_STATE_DIR/remote-devices.json`, Mac `poki-mcp` keeps using `RemotePairing` and ignores a newly attached USB cable. Call `disconnect_device`, then ask the user for confirmation (or tell them how to do it themselves) before removing only that device's entry from `remote-devices.json` (keep `remote/<UDID>/pairing.plist` private and intact) and restarting `npm start` from the Poki checkout (`cd` to the Poki checkout directory first).

**When user action is required**

- **Missing USB attachment.** Ask the user to connect the iPhone directly with a USB data cable, unlock it, tap **Trust This Computer**, and check whether Finder lists the iPhone.
- **Relay `503` (`"The phone is offline: open Poki on the phone, or check its network."`).** Ask the user to open Poki on the iPhone, check internet access, and confirm **Settings > Connection > Automation** is on.
- **Loopback down (`"Loopback Off"`, `"Tunnel On, No Answer"`, or the conflicting-VPN message above).** Ask the user to connect Wi-Fi and enable the `10.7.0.1` loopback route in LocalDevVPN, or in Surge, Loon, Shadowrocket (`Include route 10.7.0.1/32`), or sing-box, or turn off a conflicting VPN and tap **Enable Local Connection** in Poki. Because Surge, Loon, Shadowrocket, and sing-box also filter outbound HTTPS traffic and frequently intercept `gs.apple.com` (causing the false `"Disk Image Outdated"` error in section 2.1), ask the user to keep `gs.apple.com` on `DIRECT` without HTTPS decryption in those tools, or use LocalDevVPN instead.
- **Local Network permission (`"Finding Pairing Port"` on iOS or `No route to host` on macOS 15+).** On the iPhone, ask the user to allow **Settings > Privacy & Security > Local Network** for Poki on Wi-Fi. On macOS 15+, ask them to grant **System Settings > Privacy & Security > Local Network** to the desktop client or terminal that spawned `poki-mcp`.
- **Pairing rejected (`"Pairing Refused"` or a computer lockdown pairing file on iOS 27).** Ask the user to connect Wi-Fi, confirm loopback is on, and pair directly on the phone in **Setup > Pair This iPhone**.

**When you cannot fix it**

Draft an issue when Finder sees a trusted, unlocked USB iPhone that `usbmuxd` still omits, or when on-device pairing keeps failing on Wi-Fi with `10.7.0.1` loopback verified.

### 2.4 Locked screen, Poki in front, or blocked input

**Observed error strings**

- **Locked or dark display.** `observe_device` or `take_screenshot` returns `prompt.warning.kind: "passcode"`. `look` or `do` returns `screen: locked` or `screen: dark`.
- **Self-touch guard.** `look` returns `poki: Poki is in front` (with guidance to open another app). `do` returns `not_sent: only the phone's owner can approve, by tapping it on the phone themselves; Poki takes no taps or typing inside the Poki app`.
- **Paste or field errors.** Tools return `reason: "paste_permission"`, `the clipboard could not be read`, `the field's menu showed no Paste item`, or a `fill` field-confirmation error.
- **Owner gates.** Tools return `approval_required` or `not_sent: a step is handed to the owner` (`handoff`).

**What you fix yourself**

- **Poki in front.** Launch the target app with `launch_app` (or `do {"launch": "<bundle_id>"}`) or leave Poki with `press_button` (`button: "home"`).
- **Paste blocked.** Call `handle_alert` to accept `Allow Paste` and inspect `screen` to confirm whether text landed, or type with `type_text` (or `do {"type": "<text>"}`) instead of pasting.
- **Field confirmation refused.** Nothing was typed or submitted. Read `screen` from the error response, adjust your selector or coordinates, and run only `remaining_steps`.

**When user action is required**

- **Locked phone.** Ask the user to unlock the iPhone manually (unless Poki Agent's host `unlock_device` was already configured by the user for a verified `iPhone17,1` portrait 6-digit passcode setup). Never ask for or enter the passcode yourself.
- **Pending approval or handoff.** Wait for the user to tap **Allow** or **Done** on the iPhone before resending the gated step.

### 2.5 Signing expiry, stalled update, or installer error

**Observed error strings**

- **Signing expiry (`SigningViews.swift`, `Localizable.xcstrings`).** Poki shows `"Poki’s signing ends soon"` in the last 2 days of a 7-day free Apple Account profile, or iOS refuses to open Poki once expired.
- **Stalled in-app update (`SelfSigner.swift`, `Localizable.xcstrings`).** Poki stays on `"Finishing the update: Poki will close to finish it"` (or `"Finishing the update, Poki will close to finish it"`) or `"Installing the update. Features are unavailable until you reopen Poki."`.
- **Installer error codes (`node bin/install-iphone.mjs`).** Output reports `bridge_start_failed` or `unknown` with `spawn Unknown system error -86` (`EBADARCH`, such as an arm64-only Poki Setup binary on an `x86_64` Intel Mac), `setup_download_failed` or `network` (GitHub HTTP 403 or 429 rate limits), `apple_account_limit` (free account limit of 10 App IDs per week, 3 active apps, or an existing development certificate), `ddi_refused`, `sign_failed`, or `install_failed`.

**What you fix yourself (and when to ask first)**

- **Stalled on `"Finishing the update: Poki will close to finish it"`.** Ask the user to swipe Poki away in the app switcher, reopen it, and read **Settings > Signing & Updates > Version** (Settings > Connection > Signing & Updates > Poki Version in older builds, `Settings > General > Updates` in 0.4.0). Never tell the user to delete Poki, because deleting Poki erases all saved conversations and settings.
- **Computer-assisted update or renewal.** From the original signing Mac, read [install-poki](../../install-poki/SKILL.md) in the repository (or `skills/install-poki/SKILL.md` in the Poki checkout if `poki-mcp` was copied alone). First `cd` to the Poki checkout directory before running `node bin/install-iphone.mjs --update-only --json` (or `poki-setup status --json` and `poki-setup renew` for an expired profile on the same signing identity), and confirm with the user before renewing or installing. Never enter Apple Account passwords or verification codes for the user.
- **Installer failure on a Mac checkout.** First `cd` to the Poki checkout directory, then run `node bin/install-iphone.mjs diagnose` to generate `diagnostics.json` (`poki.install-diagnostics/1`), which checks `system.arch`, USB versus `usbmuxd` versus `devicectl` versus Bonjour, and the last 40 log lines with identifiers removed.

**When user action or an issue is required**

- **GitHub 403 or 429 during release lookup.** Ask the user to switch network or proxy node, or retry after the hourly unauthenticated rate limit resets.
- **Account or certificate limit (`apple_account_limit`).** Stop and explain the exact limit Apple returned. Replacing a development certificate invalidates other apps signed with it, so only the user may decide.
- **Unrecoverable install failure.** Draft an issue (`install-failure.yml`, which `node bin/install-iphone.mjs issue` writes when run from the Poki checkout) when `diagnose` reveals an unsupported binary architecture, a signing or installation failure that persists past preflight checks, or a contradiction between `usbmuxd` and USB hardware discovery.

Done when the task succeeds on a fresh screen read, or when you have confirmed the failure requires user action or a GitHub issue.

## 3. Collecting logs and stripping personal data

Collect only the minimum technical evidence needed to explain the failure, and strip every secret and personal identifier before showing or saving an issue draft.

### Safe diagnostic sources

- **Mac `poki-mcp`.** Use `poki_mcp_status`, `list_devices`, `get_device_info`, `get_crash` frame summaries, and relevant error lines from the daemon log or `POKI_MCP_CALL_LOG`.
- **Mac checkout installer (`cd` to the Poki checkout first).** `node bin/install-iphone.mjs diagnose` writes a pre-redacted `poki.install-diagnostics/1` JSON bundle. Over wired USB with Xcode installed, `node bin/install-iphone.mjs records` copies Poki's app container, including saved chat transcripts, into `~/Library/Application Support/PokiInstall/records/`. Ask the user for permission before running `records` or reading copied files (or let the user run it themselves), inspect only technical `[app]`, `[session]`, `[runner]`, `[loopback]`, and `[pairing]` lines in `poki-log.txt` around the failure, and never read or copy the user's chat messages.
- **Poki iPhone app UI.** Ask the user to open the conversations drawer, tap **Settings > Advanced > Log > More (...) > Copy Log** (or **Settings > Diagnostics > Copy Log**), or run **Settings > Advanced > Diagnostics > Run Checks**, and share only the lines around the failure with private text removed.

### Secrets and personal identifiers you must never print or attach

Never print environment variables, and never paste or upload raw contents from:

- `POKI_MCP_STATE_DIR/mcp.json` (contains the local daemon bearer `token`)
- `POKI_MCP_STATE_DIR/remote/<UDID>/pairing.plist` and Poki Setup `pairings/*.plist` or `*.rppairing.plist`
- Poki Setup `state/connectors.json` or `poki-setup mcp list --json` output (contains unredacted relay capability URLs `https://<relay>/v1/<label>/<secret>/mcp`, whereas `poki-setup mcp list` without `--json` redacts the secret)
- Poki Setup `keys/*.p8`, `state/account.json`, and `state/*.secret`
- `~/.pi/agent/auth.json` or any model API key, Apple Account email, password, two-factor verification code, Team ID, bundle ID, or iPhone passcode
- Device UDIDs, serial numbers, phone and computer names, usernames in local file paths (such as `/Users/<username>/...` or `C:\Users\<username>\...`), Wi-Fi network names (SSIDs), IP addresses, phone numbers, and private screen or chat contents
- `poki-setup support` zip archives without first removing device UDIDs, phone and computer names, file-path usernames, Wi-Fi network names, Team IDs, IP addresses, and relay URLs

## 4. GitHub issue forms and required headings

GitHub Actions checks every new issue in `JosssphZhou/poki` against `.github/ISSUE_TEMPLATE`. If an issue created with `gh issue create` omits a required `### <label>` heading or leaves a required heading as `_No response_`, the workflow adds `needs-template` and asks for an edit.

### Workflow

1. Search existing issues first:
   ```sh
   gh issue list --repo JosssphZhou/poki --state all --search "<keywords>"
   ```
   If an existing issue covers the same root problem, draft a concise comment with your new version, device, and log evidence instead of opening a duplicate.
2. Pick the matching form from the table below. Put every required field as an exact English `### <label>` heading in the listed order, with a real answer underneath. Use `_No response_` only under optional headings. For dropdown fields, copy one allowed option verbatim. For installer failures on a Mac checkout, `cd` to the Poki checkout and run `node bin/install-iphone.mjs issue` to write a redacted `install-failure.yml` draft file without submitting it.
3. Keep observations separate from inferences. Quote exact error strings, including punctuation. Never promise fix dates or release timelines.
4. Show the complete title and Markdown body draft to the user and wait for confirmation before running `gh issue create --repo JosssphZhou/poki --title "<title>" --body-file <file>` (or `gh issue comment`). Never submit on your own. If a filed issue receives `needs-template`, show the updated Markdown body to the user and get confirmation before running `gh issue edit <number> --body-file <file>` (or give the user that command to run themselves).

### Form reference

| Form | When to use | Required `### <label>` headings (in order) | Optional headings | Verbatim dropdown options |
| --- | --- | --- | --- | --- |
| `bug_report.yml` | Poki MCP, Poki Agent, iMessage or Telegram channel, `bin/setup`, `poki-native`, or relay on a computer | `What happened`, `Steps to reproduce`, `Component`, `Connection`, `Versions` | `Logs`, `Suspected cause or fix` | **Component:** `Poki MCP`, `Poki Agent`, `iMessage or Telegram channel`, `Setup or update (bin/setup, poki update)`, `Native helper (poki-native)`, `Relay or remote MCP (deploy/)`<br>**Connection:** `Physical iPhone over USB`, `Physical iPhone over LAN (RemotePairing)`, `Physical iPhone over Tailscale or VPN`, `iOS Simulator`, `Not device-related` |
| `ios_app_bug.yml` | Standalone Poki iPhone app or Poki Setup desktop app runtime bug | `What happened`, `Steps to reproduce`, `Area`, `App version`, `Installed with`, `iPhone and iOS` | `Debug log` | **Area:** `Install or signing (Poki Setup, iLoader, refresh)`, `Pairing or Developer Mode`, `Automation on the phone (reads, taps, typing)`, `Chat, voice, or sessions`, `Live Activity or background`, `Remote MCP, relay, or connectors`, `Updates or release channel`, `Other` |
| `install-failure.yml` | Installing Poki stopped at a step (`node bin/install-iphone.mjs issue` writes this form) | `What happened`, `Step it stopped at`, `Install path`, `Diagnostics`, `Versions` | `Error code`, `What you or the agent tried` | **Step it stopped at:** `Get Poki Setup`, `Start Poki Setup`, `Sign in with the Apple Account`, `Find the iPhone`, `Pair (Trust This Computer)`, `Developer Mode`, `Sign and install Poki`, `Trust the developer and open Poki`, `Relay`, `Self-check`, `Don't know`<br>**Install path:** `Agent installer (node bin/install-iphone.mjs)`, `Poki Setup for Mac (window)`, `Poki Setup for Windows (window)`, `poki-setup command line` |
| `task_failure.yml` | Tools work, yet a real task inside a specific app could not finish | `Task`, `Where it stopped`, `Driven by`, `Versions` | `Trace` | **Driven by:** `Poki Agent (terminal)`, `Poki Agent over iMessage or Telegram`, `Another MCP client (Claude Code, Codex, ...)`, `Poki iPhone app` |
