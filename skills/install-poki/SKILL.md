---
name: install-poki
description: Install or update the Poki app on the user's iPhone from a Mac, when they ask something like "install Poki on my iPhone" or "update Poki", or when Poki's own update on the iPhone fails, cannot download or stalls. Uses the checkout installer for first installs and checks the existing signing identity before a computer-assisted update.
license: AGPL-3.0-only
---

# Install or update Poki on an iPhone

This installs the standalone Poki app on the user's iPhone through Poki Setup's helper, without its window. It is not the Poki MCP install or update in the repository's `AGENTS.md`. Works from Claude Code, Codex or any agent that can run a shell command on the user's Mac.

For a first install, start the installer, relay its person stops, and verify its result. For an update, complete the preservation checks below before any installation command.

Pick one branch:

- **First install.** Poki is not on the iPhone. Follow "Before you start", "Run it", "Check the version" and "What to keep running".
- **Update.** Poki is on the iPhone and the user asks to update it, or Poki's own update failed, could not download or stopped moving. Follow "Update an installed Poki". Poki's own update downloads from R2 with a GitHub network-failure fallback on the iPhone, and that download sometimes cannot reach GitHub; this branch is the backup, where the Mac downloads the build and installs it over USB.
- **Stuck on "Finishing the update".** Follow "When Poki's own update stalls".

In Poki 0.4.0, open the conversations drawer and tap the Settings button at the bottom. Paths below such as Settings > General > Updates start there. Current builds group these pages under Settings > Connection: Settings > General > Updates is Settings > Connection > Signing & Updates, and Settings > Automation > Setup is Settings > Connection. Give the user the path their build shows.

## Before you start

**First-time installation requires Wi-Fi.** Ask the user to connect the iPhone to Wi-Fi and keep it connected until initial setup is complete. If it is on cellular data only, wait for the user to confirm Wi-Fi before starting. This applies to both the checkout installer and Poki Setup's bundled command line tool.

1. Find or make a Poki checkout. In a checkout, `bin/install-iphone.mjs` exists. Otherwise run `git clone https://github.com/JosssphZhou/poki.git` and work in that folder. An existing checkout on `main` with no local changes can take `git pull --ff-only` first, so the installer is current; leave any other checkout as it is and use a separate clone of `main`. Done when the checkout contains the current installer.
2. Check: a Mac with macOS 14 or later, Node.js 24 or later, an iPhone on iOS 18 or later, a USB data cable, and the user's Apple Account. A free account works with 7-day signing; see "No paid developer account" below. The iPhone also needs a VPN app that routes 10.7.0.1 back to the iPhone; see "No VPN app" below. On iOS 27 and later Poki controls the iPhone through its native services by default; on iOS 18 to 26 it uses the XCTest session, which needs UI Automation. That path was not tested on a physical iPhone below iOS 27 for this release: tell the user so before installing on an older iOS. Xcode is not required. With Xcode installed, the installer can see when Poki opens and give it the model key even with an older Poki Setup. Without Node.js 24, or on Windows, use "Without Node.js, or on Windows" below instead of the checkout. Done when the prerequisites are present and the user has confirmed the phone is ready.
3. Ask the user one question: "Should I also give Poki on the iPhone your model API key from this Mac's keychain?" Default is no. On yes, ask which provider (`openai`, `anthropic`, `deepseek`, `gemini` or `openrouter`) and add `--model-key <provider>` below. The installer reads the keychain item `<provider>-api-key` (for example `openai-api-key`; another name with `--model-key-item <item>`). Never read the key yourself and never ask for it in chat. Done when the user has chosen whether to transfer a key.

## Which Poki you get

The installer uses Beta. Historical stable, alpha and pre-alpha preferences also resolve to Beta. R2 is the primary source and GitHub is the network-failure fallback. Do not state a version from memory; read it from the run:

- The `channel` step prints `<channel>: Poki <version> (<build>)`, the release this run installs. For a Beta or Stable release the part in brackets is the release name (`beta.1`) or empty, not the build number.
- The `install` step prints `Poki <version> (<build>) installed`, with the build number from the app itself.

Resolve the selected channel again for each installation. If it offers an older version than requested, stop and report the release mismatch.

With Poki Setup installed, `"<tool>" release --all --json` lists current releases and `"<tool>" channel --json` reads its saved channel without changing it. The tool paths are under "Without Node.js, or on Windows". Release names such as `beta.1` are not numeric build numbers. Before an update, download the selected IPA and its SHA256SUMS from the same release, verify the checksum, and read `CFBundleShortVersionString` and `CFBundleVersion` from `Payload/*.app/Info.plist`. Do not install when the numeric build cannot be established. A dry run simulates the phone and is not version or data-preservation proof.

## Run it

From the checkout, start the installer in the background and read its output as it comes:

```sh
node bin/install-iphone.mjs run --json
```

Each line is one JSON event with an `at` time:

- `{"event":"step","step":"install",...}` starts a step. `done` or `skipped` (with a `reason`) ends it.
- `{"event":"wait","wait":"pair","who":"phone","say":"..."}` is a person stop. Tell the user `say` word for word. `who` is `phone` (tap on the iPhone) or `input` (type into a window on the Mac). The installer sees when it is done and continues.
- `{"event":"note","text":"..."}` is information. Pass it on when it asks something of the user.
- `{"event":"error","code":"...","reason":"...","agent_fix":"...","retrying":true}` is a failure. With `retrying` true, the installer is already trying again.
- `{"event":"result","ok":true,"check":{...}}` is the last line only when the checks passed without manual steps left unverified.
- A result with `ok:false` and `unverified` exits with code 3. Relay every entry's `say`, including instructions from skipped steps. Have the user finish them in Poki and confirm each result. Report what was manually confirmed and what remains unverified; do not call the phone ready just because the app was installed. Older Poki Setup without Xcode can require manual model-key entry and loopback setup.

Some helper prompts still name older pages. After relaying the prompt, give the 0.4.0 path: Setup > Connect to this iPhone means Settings > Connection > Local Connection (Settings > Automation > Setup > Local Connection in older 0.4.0 builds); Agents > Accounts and Models means Settings > Models > Add Account. Do not follow a helper instruction to delete an existing app.

Several iPhones plugged in: list them with `node bin/install-iphone.mjs phones` and add `--udid <udid>`.

## The steps

The installer runs these in order. Most need nobody. Each step is complete when its `done` event confirms the result described below. A `wait` remains incomplete until its condition is met. Inspect every `skipped` reason; a skipped installation does not prove an update, and a manual step remains unverified until the user confirms it.

1. **`setup_app`** Downloads Poki Setup and checks its SHA-256, Developer ID team (`Q64ZL36CJN`) and notarization. Nobody acts.
2. **`bridge`** Starts Poki Setup's helper without a window. Nobody acts.
3. **`channel`** Finds the newest Beta release for this installation. Nobody acts.
4. **`apple_account`** Signs in with the Apple Account, on the Mac only. Poki Setup keeps the sign-in for renewals. Stops `apple_dialog` and `apple_code_dialog` when this Mac was never signed in.
5. **`phone`** Waits for the iPhone. Stop `phone_plug`.
6. **`install`** Pairs, turns on Developer Mode, signs and installs Poki, gives it its pairing file and disk image. Stops `pair` and `devmode` on a phone that needs them, `pairing_file` rarely.
7. **`open_poki`** The user trusts the developer and opens Poki. Stop `open_poki`, and the installer sees Poki open by itself. Stop `open_poki_tell` only when this Mac cannot read Poki's files. Then the user tells you, and you run `node bin/install-iphone.mjs done open_poki`.
8. **`model_key`** Only with `--model-key`. Gives Poki the key, sealed to a key only that iPhone holds, and waits until Poki says it took it. The first time, macOS may ask on the Mac whether node can use the keychain item; tell the user to click Allow. Poki takes the key while it is in front.
9. **`loopback`** Checks that Poki's local connection (10.7.0.1) answers. Stop `loopback` when it does not, with Poki's own sentence for the VPN app on the phone. If the person has no VPN app, point them to Poki's instructions for the free LocalDevVPN.
10. **`relay`** Deploys the relay when `CLOUDFLARE_API_TOKEN` is set or Poki Setup keeps a token. Skipped otherwise. Poki and its own chat work without it; agents on other computers need it.
11. **`check`** Self-check: the install record, Developer Mode, pairing, disk image and relay.

Poki turns itself on after this install, and ticks Developer Mode and UI Automation in Settings > Automation > Setup once it runs. The iPhone's own switch for UI Automation (iOS Settings > Developer > Enable UI Automation) is still the user's to turn on; Poki's UI Automation row and Allow UI Automation page says so. When Poki first opens it asks for Automation Mode: tell the user to tap Continue and enter the iPhone passcode on iOS's screen. If they cancel, Poki does not ask again until they turn it on again.

## Download source and failures

Configured builds read an Ed25519-signed R2 catalog. Every R2 resource, including the signing archive, must match the signed size and SHA-256. One operation keeps the selected metadata even if the catalog changes during download.

When R2 is unreachable, the updater reports that it is using GitHub. If an R2 resource was already selected, its GitHub copy must have the same release tag, filename, size and signed checksum. A catalog signature error, redirect, unsafe address or checksum mismatch stops the operation. Report that error and retry after the source is repaired. Do not bypass it with a manual download.

A build without R2 configuration explicitly reports that it uses GitHub. This does not prove the R2 migration is deployed. GitHub-only discovery retains the existing GitHub release checksum policy; older signing archives may lack a checksum. Keep that distinction in any validation report.

## Person stops

| `wait` | What you do |
|---|---|
| `apple_dialog` | Tell the user `say`. A Poki Setup window on the Mac asks for the Apple Account email, then the password (hidden). If they close it, the installer stops with `apple_credentials_missing`; run it again when they are ready. |
| `apple_code_dialog` | Tell the user `say`. Another window asks for the 6-digit code (hidden). Never ask for the code in chat. |
| `apple_password` | Only without windows (`POKI_INSTALL_DIALOGS=0`, or a session with no screen such as SSH). Give the user the command in `say`. They run it in their own Terminal, where macOS asks for the password without showing it. Never type it for them. |
| `apple_code` | Only without windows. Give the user the command in `say` exactly as printed (it has this checkout's absolute path). They type the code at its hidden prompt. The installer takes no code as an argument. |
| `phone_plug` | Tell the user `say`. |
| `pair` | Tell the user `say`. A phone already paired with this Mac gets only a `note`. |
| `devmode` | Tell the user `say`. The phone restarts; the installer waits for it. |
| `pairing_file` | Tell the user `say`. Rare: Poki Setup could not write the pairing file into Poki. |
| `open_poki` | Tell the user `say`. The installer sees Poki open. If the user says Poki is open and the installer has not moved on within a minute (an older Poki writes no hello), run `node bin/install-iphone.mjs done open_poki`. |
| `open_poki_tell` | Tell the user `say`. When they say Poki is open, run `node bin/install-iphone.mjs done open_poki`. |
| `loopback` | Tell the user `say`. It names their VPN app and the one thing to set. The installer sees when it answers. |

A person stop waits 15 minutes, then the installer exits with code 3 and `{"event":"result","ok":false,"waiting":"..."}`. Run the same command again when the user is ready; it rechecks the steps and reuses an unexpired install. For an already installed Poki, including an expired or revoked signature, use the preservation checks in "Update an installed Poki" before any forced reinstall. The installer can otherwise renew an expired record during setup without a separate update preflight.

## Check the version

An installation is complete only after the installer reports success and the phone matches the selected release. Compare these readings:

1. The `install` step's `Poki <version> (<build>) installed`.
2. The `open_poki` step's `Poki <version> (<build>) is open on the iPhone`. Poki writes this itself when it starts, so it is the iPhone's own answer. The result's `check.poki` is only this Mac's install record.
3. What the user reads in Poki at Settings > General > Updates > Poki Version.

When `open_poki` ended with "the person said Poki is open" or "a version that does not write its hello yet", the third is the only readback: ask the user for it. Tell the user the version, the build and the channel it came from.

**The version is wrong.**

- `install` was `skipped` with "already installed from this computer": nothing was installed. Follow "Update an installed Poki" before forcing another install.
- Poki Version still shows the old build: the old copy may still be running while iOS finishes replacing it. Ask the user to swipe Poki away in the app switcher, wait a moment, open it again and read Poki Version again.
- Poki Version matches the `install` line but not what the user expected: the channel chose it (see "Which Poki you get"). Tell the user the channel and build. Do not switch to preview releases to work around a missing Beta.

Done when Poki Version equals the selected release's actual version and numeric build, as well as the `install` line. Otherwise report the installation as incomplete and name the mismatch. On an existing installation, use the preservation checks below before any retry.

## No paid developer account

A paid developer membership is not required. A free Apple Account works. Poki Setup signs Poki for 7 days on a free account. Free-account limits are 10 App IDs a week, 3 apps at a time and one development certificate; `apple_account_limit` names the one Apple hit. A paid team gets the same external build. Poki Setup always leaves out Poki's built-in connection extension, because a team profile cannot carry its entitlement, so this installer path needs an external VPN app for paid accounts too. A separately signed built-in-connection build is a different path. Done when the `check` step passed and you told the user `check.days_left` and how renewal works ("What to keep running").

## No VPN app

Poki reaches the iPhone's developer services at 10.7.0.1, and a VPN app on the phone routes that address back to the phone. Poki offers instructions for the free LocalDevVPN from the App Store. In Poki it is listed at Settings > Automation > Setup > Local Connection (the Turn On Loopback page), under Use Your Proxy App, with its steps. At the `loopback` stop, tell the user `say`, and to install LocalDevVPN when they have no VPN app. Done when the `loopback` step ends `done`. If the user does not want a VPN app now, Poki stays installed but cannot operate other apps: after 15 minutes the installer exits with code 3; report the local connection as not set up.

## What to keep running

Tell the user these after the result:

- **Poki Setup on the Mac renews Poki.** The installer runs Poki Setup's helper only while it runs. Renewal on the Mac is done by the Poki Setup app while it is open (closing its window leaves it in the menu bar): every 6 hours it renews each iPhone this Mac set up that has 2 days of signing left or fewer, with the Apple Account password it kept. The Mac must be awake and the iPhone reachable and trusted. USB is the fallback when network discovery on the same Wi-Fi does not find it. Ask the user to open Poki Setup and keep it open, and not to sign out of it or delete it.
- **Or Poki renews itself.** The installer gives Poki this Mac's signing key, but not the Apple sign-in. When the user signs in at Settings > General > Updates > Signing Options > Apple Account, Poki prepares a refreshed build 3 days before signing ends and asks the user to tap Install Refresh or Install Update.
- **Keep the VPN app connected and Developer Mode on.** Poki needs 10.7.0.1 to operate the phone and to install its own updates and refreshes.

With neither renewal, Poki stops opening when signing ends. Poki warns on its home screen and with a daily notification in the last 2 days. For an existing installation, use the update branch below when installing a newer build. Renewal downloads the newest release on the Mac's channel and can also update the app; explain the selected version before proceeding. The update-only command refuses equal builds; an explicitly requested signature refresh needs its own preservation review. Done when the user knows which renewal method is configured, the signing expiry, and which apps must remain running. Automatic renewal while asleep, locked, or disconnected has not been verified here.

## Update an installed Poki

Use this branch when an existing Poki cannot download its update on the iPhone. Read the [preservation audit and compatibility requirements](../../docs/agent-install.md#update-only-compatibility) first. This command requires a Poki Setup build with update-only support and an installed Poki that can provide fresh public update information. An older helper or phone app stops before installation. Do not use full installation to get past that stop.

1. Ask the user to finish any Poki task, connect the iPhone to its original signing computer by USB, unlock it and keep Poki open. Keep the existing Poki Setup data directory and signing account. Done when the user confirms the phone is ready.
2. Run the following from the checkout. Add `--udid <device-id>` only when needed to select the intended phone. Do not add `--channel`, `--reinstall`, model-key options or configuration changes.

   ```sh
   node bin/install-iphone.mjs --update-only --json
   ```

3. Read the installed version, numeric build, channel and team verification status, followed by the target version and build. Team and device identifiers are deliberately withheld from output. The helper reads the live installation, requests fresh public metadata from the running app, checks the original record and public certificate, and inspects the downloaded IPA. It rejects equal or lower builds, non-Beta targets or identity mismatches, changed app groups, and missing extensions. Historical phone and computer channel preferences converge to Beta. It performs no pairing, model-key transfer, signing-identity import or relay deployment.
4. On exit **2**, quote the single `reason` sentence and stop. Say that installation did not start; the only phone-side preflight write is a non-secret freshness request. Do not fall back to `run --reinstall`, unguarded `renew`, uninstalling the app, replacing certificates or clearing its data. An unavailable public snapshot is a compatibility limitation, not permission to infer identity from the Mac's record.
5. On exit **3**, report installation as failed or unconfirmed and keep Poki installed. On exit **4**, report that installation finished but the target version was not verified. Resolve the named failure before another update-only attempt. Never describe either result as success.
6. Exit **0** means the live installed version and build matched the inspected target after guarded renewal. A result with `simulated: true` proves only the simulated path. For a real update, ask the user to open Poki and confirm conversations, model accounts, settings, signing options, release channel, connections and required extensions. Do not display secret values. Done only when the version matches and those retained items are confirmed.

In current builds the update page is Settings > Connection > Signing & Updates; older 0.4.0 builds use Settings > General > Updates. This path only installs a higher numeric build. An equal-build signature refresh is a separate operation and must not be substituted automatically. Physical-device preservation remains unverified until the checks above are performed on the intended phone.

## When Poki's own update stalls

After the user taps Install Update or Download and Install Update in Poki (Settings > General > Updates), Poki can stay on "Finishing the update: Poki will close to finish it", after the alert "Poki Will Close to Finish the Update". Poki shows this once iOS has begun installing the new copy, and iOS finishes only after the old Poki leaves the screen. For the reported 0.4.0 case where installation has succeeded, tell the user the new version is installed and to swipe Poki away in the app switcher and reopen it. This closes the process without deleting the app or its data. The status text alone is not proof that installation succeeded; always read back the version. Done when Settings > General > Updates > Poki Version shows the new build. If it still shows the old build a minute later, or Poki does not open, follow "Update an installed Poki".

## When a step fails

The installer exits with code 2. The last `error` event has `code`, `reason` and `agent_fix`. Follow `agent_fix` only within the preservation rules above. Never relay an instruction to delete Poki as routine recovery. Then retry the applicable branch. Ask the user only for what the `person` field names.

| Code | Meaning | What you do |
|---|---|---|
| `setup_download_failed` | Release metadata or an asset could not be read or trusted. | Read the source notice. Network failures can fall back to GitHub. Signature, redirect and address-validation failures stop the operation; report them without switching sources manually. For a GitHub refusal, report the status and retry later. |
| `setup_checksum_mismatch` | A downloaded file differs from its expected checksum or signed size. | Stop and report. Keep the installed app and its data. Never open the downloaded file. |
| `setup_signature_invalid` | Poki Setup is not signed by team `Q64ZL36CJN` or not notarized. | Stop. Do not run it. Report it. |
| `setup_app_missing` | `phones` or `diagnose` cannot find Poki Setup.app. | Run `run`, which installs it, or pass `--app-dir` or `--bridge`. |
| `bridge_start_failed` | Poki Setup's helper did not start. | Delete `~/Applications/Poki Setup.app` if the installer put it there, and run again. |
| `usbmuxd_unreachable` | macOS does not list the iPhone (issue #6). | Ask the user to plug it in again, unlocked. Then run `diagnose`. |
| `several_phones` | More than one iPhone is plugged in. | Run again with `--udid`. |
| `phone_locked` | The iPhone is locked. | Ask the user to unlock it. Retried by itself. |
| `trust_not_answered` | Nobody tapped Trust in time, or someone tapped Don't Trust. | Ask the user to tap Trust. Retried by itself. |
| `developer_mode_off` | Developer Mode is still off. | Ask the user to turn it on. Retried by itself. |
| `apple_credentials_missing` | Nothing to reuse, and the user closed the Poki Setup window. | Ask whether to sign in now, then run again. |
| `apple_sign_in_rejected` | Apple refused the email or password. | The window opens again by itself. |
| `apple_code_wrong` | Apple refused the code. | The window asks again; without windows, the user runs the `code` command again with the newest code. |
| `apple_server_busy` | Apple or the anisette server answered with an error. | Retried by itself on another server. |
| `apple_account_limit` | A free-account limit: 10 App IDs a week, 3 apps, or one certificate already held by AltStore, SideStore, Xcode or another computer. | Stop. Tell the user which limit Apple named. The way out is their decision. |
| `network` | A request failed, also while signing in. | Retried by itself with what the user already typed. When the reason says Poki's releases could not be read from GitHub with 403 or 429, it is usually the same hourly limit as `setup_download_failed`; the `channel` step does not retry it and the `install` step tries 3 more times: ask the user to switch network or proxy node and run again, or to wait an hour. Otherwise report. |
| `sign_failed` | Signing failed. | Stop and run `diagnose`. |
| `ddi_refused` | Apple rejected the developer disk image with STATUS=94 or a signing-server refusal. The image may be too old for the phone's iOS. | Relay the detected Xcode and iOS versions from the error. Update Xcode to support that iOS version (iOS 27 requires Xcode 27), open Xcode once, and wait for its components to finish installing. Rerun the same command. Poki does not need to be reinstalled. If `prepare-device` used `--image`, replace that image with the updated Xcode image. |
| `install_failed` | iOS refused the install. | Retried once. Then run `diagnose`. If the error says Poki is installed from another Apple ID, stop: deleting Poki deletes its data, so report the identity mismatch and stop. |
| `relay_failed` | The relay deploy or check failed. Poki still works on the phone. | Report it. The user can deploy from the Relay page of Poki Setup on the Mac. |
| `check_failed` | Installed, but the self-check found something not ready. | Read the `check` fields, fix what the matching code says, run again. |
| `model_key_missing` | `--model-key` was given, but the keychain item is missing or empty. | Tell the user the item name. They add it in their own Terminal (`security add-generic-password -U -s <item> -a "$USER" -w`) or type the key in Poki at Settings > Models > Add Account. |
| `model_key_not_taken` | Poki did not take the sealed key in time. | Ask the user to bring Poki to the front, then run again. |
| `node_too_old` | Node.js is older than 24. | Install Node.js 24 or later, or follow "Without Node.js, or on Windows" below. |
| `unknown` | Not recognised. | When the `reason` says the Apple Account already has its development certificate and offers Replace Certificate, stop and tell the user: replacing it stops every app that certificate signed until it is installed again, so it is their decision. Otherwise run `diagnose` and `issue`. |

## Download and upgrade recovery

When Poki Setup reports an HTTP error during installation, the installer retries the selected release through its download code and passes the verified IPA and matching signing archive to the helper. R2 downloads verify both against the signed catalog. GitHub-only discovery uses SHA256SUMS and checks a signing archive checksum when the release includes one. Local installation records use a `local:` tag.

If both sources fail, retain the installed app and report the error. A signature or checksum failure must not be bypassed through manual downloads or another release's signing archive. See "Download source and failures" for the allowed recovery boundary.

Before an upgrade, ask the user to save their work and leave Poki for the Home Screen. If installation stalls, retry with the phone unlocked and Poki swiped away. Do not delete Poki or revoke certificates without explaining the data/signing impact and getting permission. An unavailable old app is not proof that its data is lost.

## Without Node.js, or on Windows

Poki Setup 0.2.2 and later carry their own command line tool, which needs no checkout and no Node.js: `"/Applications/Poki Setup.app/Contents/MacOS/poki-setup"` on a Mac (or under `~/Applications`), `"$env:LOCALAPPDATA\Poki Setup\poki-setup.exe"` on Windows. When Node.js 24 is missing (`node_too_old`) or the computer runs Windows, ask the user to install Poki Setup from the newest Beta at https://github.com/JosssphZhou/poki/releases and open it once, then, for a first install, run `"<tool>" prompt` and follow what it prints. For an existing app, return to "Update an installed Poki" and apply its preservation gate before any command that installs or renews. If this tool lacks the documented read-only commands or `renew`, stop and report the unsupported build. In short: `"<tool>" next --json` lists what is done and what is next, with `who`, `command` and `say` for each step; exit code 2 means a person has to act and 3 that Apple's sign-in code is needed. The person signs in by running `"<tool>" login <email> --keep-password` in their own terminal.

## Read Poki's records on the Mac

`node bin/install-iphone.mjs records` reads Poki's chats, voice conversations and log off the iPhone over USB and writes them as one text file in time order, by default in `~/Library/Application Support/PokiInstall/records/`. It only copies from Poki's app container (`devicectl device copy from`) and changes nothing on the phone. It prints only the file's path, not the conversations. Keys, pairing records and relay addresses are removed. Use `--udid` when several iPhones are plugged in, `--out <file>` to choose the file, and `--bundle <id>` when iOS does not list Poki by name. The file holds the owner's own messages: show it only to them.

## When you cannot fix it

1. Run `node bin/install-iphone.mjs diagnose`. It prints a JSON bundle with versions, each step's result, what usbmuxd, USB, `devicectl` and Bonjour see, and Poki Setup's last log lines, with identifiers, names, keys, tokens and addresses removed. Show it to the user.
2. Run `node bin/install-iphone.mjs issue`. It writes an English issue draft and prints the `gh issue create` command. It never submits.
3. Show the user the whole draft. Run the printed command only after they say yes. Never submit without that yes.

## Secrets

- The Apple Account password and code go into Poki Setup windows the user types into, never into chat or a command line. `POKI_APPLE_ID` and `POKI_SETUP_PASSWORD` are for the user's own shell, not for you.
- The model key leaves the keychain only into the installer's memory, is sealed to the iPhone's key, and is never printed, logged or put on a command line.
- Do not print, log or paste the user's password, tokens, model keys or iPhone passcode.

`node bin/install-iphone.mjs run --dry-run` checks the real Poki Setup and simulates the iPhone and the Apple Account. `node bin/install-iphone.mjs --version` names the installer; say it when you report a problem. On Windows, see "Without Node.js, or on Windows" above.
